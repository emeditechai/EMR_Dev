-- ============================================================================
-- Migration: 2202_lab_critical_value_communication.sql
-- Description: Critical value communication record (NABL): for every Critical / Panic result, who was informed, how,
--   when, by whom, and whether the value was read back. Closes the "Critical value communication" data gap of the
--   LAB Reports Roadmap.
--   * dbo.LabCriticalCommunication: one row per attempt (Informed / Attempted - not reachable) with a snapshot of the
--     value, severity and threshold. Rows are never deleted: a correction adds a row and switches the old one off.
--   * dbo.ufn_LabCriticalEval: the one rule for "is this result critical" (saved flag Critical / Panic, or a numeric
--     value beyond the patient's matching Critical / Panic reference-range threshold), shared by sign-off and LR-16.
--   * dbo.ufn_LabCriticalOrderResults: the critical results of one bill held by a branch.
--   * dbo.usp_LabCritical_GetPending: critical results of a bill with their communication state and whether each
--     one blocks sign-off (final-level sign-off / Report Entry approval with no Informed or Attempted record).
--   * dbo.usp_LabCritical_Record: validates and saves communication records. A WhatsApp / email communication can
--     also be sent from the application (existing WhatsApp / SMTP configuration of the branch): the record is saved
--     with MessageStatus QUEUED, EMR.Web sends it in the background (as the report notifications do) and sets SENT, or
--     FAILED - a failed message turns the record into "Attempted" with the error, so it never counts as informed.
--   * LR-16 dbo.usp_Api_LabReport_CriticalValues: communication columns, % informed, % within the target time.
--   * HospitalSettings.CriticalValueCommunicationRequired (per branch, default No): the whole feature is optional.
--     Off = approval exactly as before (no form, no sign-off check), recording refused, LR-16 without the
--     communication columns. On = everything below.
--   * HospitalSettings.CriticalValueInformMinutes: target minutes from result entry to informing (empty = 30).
--   * Control CRITICAL_COMM ("Record critical value communication") on the Pathologist Dashboard, Report Entry,
--     Microbiology Report Entry and LR-16 pages. No grant is seeded: an unset control follows its page.
--   The approval procedures are not changed; the sign-off check runs before them (EMR.Api / EMR.Web).
--   Run after 2201.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── setting: target minutes per branch ───────────────────────────────────────
IF COL_LENGTH('dbo.HospitalSettings', 'CriticalValueCommunicationRequired') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD CriticalValueCommunicationRequired BIT NOT NULL
        CONSTRAINT DF_HospitalSettings_CriticalValueCommunicationRequired DEFAULT (0);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'CriticalValueInformMinutes') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD CriticalValueInformMinutes INT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_HospitalSettings_CriticalValueInformMinutes')
    ALTER TABLE dbo.HospitalSettings ADD CONSTRAINT CK_HospitalSettings_CriticalValueInformMinutes
        CHECK (CriticalValueInformMinutes IS NULL OR CriticalValueInformMinutes BETWEEN 1 AND 1440);
GO

-- ── the communication record ────────────────────────────────────────────────
IF OBJECT_ID('dbo.LabCriticalCommunication', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LabCriticalCommunication (
        CommunicationId     BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_LabCriticalCommunication PRIMARY KEY,
        SamplecollectionID  BIGINT          NOT NULL,
        LabEntryDetailId    INT             NULL,
        LabOrderId          INT             NOT NULL,
        InvestigationID     INT             NOT NULL,
        BranchId            INT             NOT NULL,
        -- snapshot of the result when it was communicated
        Severity            VARCHAR(10)     NOT NULL,
        ResultValue         NVARCHAR(100)   NOT NULL,
        Unit                NVARCHAR(50)    NULL,
        Threshold           NVARCHAR(200)   NULL,
        -- the communication
        Outcome             VARCHAR(10)     NOT NULL,
        InformedName        NVARCHAR(150)   NOT NULL,
        InformedRole        VARCHAR(20)     NOT NULL,
        ContactNo           NVARCHAR(150)   NULL,
        Mode                VARCHAR(15)     NOT NULL,
        InformedOn          DATETIME        NOT NULL,
        ReadBack            BIT             NOT NULL CONSTRAINT DF_LabCriticalCommunication_ReadBack DEFAULT (0),
        Remarks             NVARCHAR(500)   NULL,
        Source              VARCHAR(15)     NOT NULL,
        RecordedBy          INT             NOT NULL,
        RecordedOn          DATETIME        NOT NULL CONSTRAINT DF_LabCriticalCommunication_RecordedOn DEFAULT (GETDATE()),
        IsActive            BIT             NOT NULL CONSTRAINT DF_LabCriticalCommunication_IsActive DEFAULT (1),
        CorrectsId          BIGINT          NULL,
        CorrectedBy         INT             NULL,
        CorrectedOn         DATETIME        NULL,
        MessageStatus       VARCHAR(10)     NULL,       -- QUEUED / SENT / FAILED when sent from the application
        MessageRef          NVARCHAR(100)   NULL,
        MessageError        NVARCHAR(500)   NULL,
        MessageOn           DATETIME        NULL,
        CONSTRAINT CK_LabCriticalCommunication_Severity CHECK (Severity IN ('CRITICAL', 'PANIC')),
        CONSTRAINT CK_LabCriticalCommunication_Outcome CHECK (Outcome IN ('INFORMED', 'ATTEMPTED')),
        CONSTRAINT CK_LabCriticalCommunication_Role CHECK (InformedRole IN ('REFDOCTOR', 'TREATDOCTOR', 'PATIENT', 'ATTENDANT', 'WARD', 'PARTNER', 'OTHER')),
        CONSTRAINT CK_LabCriticalCommunication_Mode CHECK (Mode IN ('PHONE', 'INPERSON', 'WHATSAPP', 'SMS', 'EMAIL')),
        CONSTRAINT CK_LabCriticalCommunication_Source CHECK (Source IN ('SIGNOFF', 'ENTRY', 'REGISTER')),
        CONSTRAINT CK_LabCriticalCommunication_Message CHECK (MessageStatus IS NULL OR MessageStatus IN ('QUEUED', 'SENT', 'FAILED'))
    );
    CREATE INDEX IX_LabCriticalCommunication_Sample ON dbo.LabCriticalCommunication (SamplecollectionID, IsActive) INCLUDE (Outcome, InformedOn);
    CREATE INDEX IX_LabCriticalCommunication_Branch ON dbo.LabCriticalCommunication (BranchId, InformedOn);
END
GO

-- ── the rule: is a result critical? (as Report Entry flags it, script 2116) ──
CREATE OR ALTER FUNCTION dbo.ufn_LabCriticalEval
(
    @InvestigationID INT,
    @CompanyId       INT,
    @AgeYears        INT,
    @Gender          NVARCHAR(20),
    @AsOf            DATE,
    @TestValue       NVARCHAR(4000),
    @Flag            VARCHAR(20),
    @Unit            NVARCHAR(50)
)
RETURNS TABLE
AS
RETURN
(
    SELECT CAST(CASE WHEN f.Flag IN ('Critical', 'Panic') OR d.Dir IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsCritical,
           CASE WHEN f.Flag IN ('Critical', 'Panic') THEN UPPER(f.Flag) WHEN rng.Tier = 'Panic Value' THEN 'PANIC' ELSE 'CRITICAL' END AS Severity,
           d.Dir AS ThresholdDir, rng.Tier AS RangeTier, rng.Low_Threshold AS LowThreshold, rng.High_Threshold AS HighThreshold,
           f.Flag AS SavedFlag,
           CASE WHEN rng.Low_Threshold IS NULL AND rng.High_Threshold IS NULL THEN NULL
                ELSE CONCAT(CASE WHEN rng.Low_Threshold IS NOT NULL THEN N'< ' + CAST(CAST(rng.Low_Threshold AS FLOAT) AS NVARCHAR(30)) END,
                            CASE WHEN rng.Low_Threshold IS NOT NULL AND rng.High_Threshold IS NOT NULL THEN N' or ' END,
                            CASE WHEN rng.High_Threshold IS NOT NULL THEN N'> ' + CAST(CAST(rng.High_Threshold AS FLOAT) AS NVARCHAR(30)) END,
                            CASE WHEN ISNULL(@Unit, N'') <> N'' THEN N' ' + @Unit END) END AS Threshold
    FROM (SELECT NULLIF(LTRIM(RTRIM(@Flag)), '') AS Flag, TRY_CAST(LTRIM(RTRIM(@TestValue)) AS DECIMAL(18, 4)) AS NumValue) f
    OUTER APPLY (
        -- the patient's matching Critical / Panic range (age, gender; same order of preference as Report Entry)
        SELECT TOP 1 x.Tier, x.Low_Threshold, x.High_Threshold
        FROM dbo.LabReferenceRangeMaster x
        WHERE x.Test_ID = @InvestigationID AND x.IsDeleted = 0 AND x.Status = 1
          AND x.Tier IN ('Critical Value', 'Panic Value')
          AND (x.CompanyId = @CompanyId OR x.CompanyId = 1)
          AND x.Effective_From <= @AsOf AND (x.Effective_To IS NULL OR x.Effective_To >= @AsOf)
          AND (@AgeYears IS NULL OR x.Is_Common_For_All = 1
               OR (x.Age_Unit = 'Years' AND @AgeYears >= x.Age_From AND @AgeYears <= x.Age_To)
               OR (x.Age_Unit = 'Months' AND @AgeYears * 12.0 >= x.Age_From AND @AgeYears * 12.0 <= x.Age_To)
               OR (x.Age_Unit = 'Days' AND @AgeYears * 365.25 >= x.Age_From AND @AgeYears * 365.25 <= x.Age_To))
          AND (x.Is_Common_For_All = 1 OR x.Gender = 'All' OR LOWER(x.Gender) = LOWER(ISNULL(@Gender, '')))
        ORDER BY CASE WHEN LOWER(x.Gender) = LOWER(ISNULL(@Gender, '')) THEN 1 ELSE 2 END,
                 CASE WHEN x.Is_Common_For_All = 0 THEN 1 ELSE 2 END, x.RefRange_ID DESC) rng
    OUTER APPLY (SELECT CASE WHEN f.NumValue IS NOT NULL AND rng.Low_Threshold IS NOT NULL AND f.NumValue < rng.Low_Threshold THEN 'L'
                             WHEN f.NumValue IS NOT NULL AND rng.High_Threshold IS NOT NULL AND f.NumValue > rng.High_Threshold THEN 'H' END AS Dir) d
);
GO

-- ── the critical results of one bill held by a branch (one row per parameter) ──
CREATE OR ALTER FUNCTION dbo.ufn_LabCriticalOrderResults (@BranchId INT, @LabOrderId INT)
RETURNS TABLE
AS
RETURN
(
    SELECT led.LabEntryDetailId, sc.samplecollectionID AS SampleId, sc.Laborderid AS LabOrderId, sc.InvestigationID,
           lim.Test_Code AS TestCode, lim.Test_Name AS TestName, NULLIF(sc.ProfileName, '') AS ProfileName,
           LTRIM(RTRIM(led.TestValue)) AS TestValue, COALESCE(NULLIF(u.Unit_Symbol, ''), u.Unit_Name, '') AS Unit,
           ISNULL(led.ReportStatusId, 0) AS ReportStatusId,
           COALESCE(led.Submitted_Date, led.Drafted_Date, led.CreatedDate) AS EnteredOn, led.Approved_Date AS ApprovedOn,
           ev.IsCritical, ev.Severity, ev.ThresholdDir, ev.RangeTier, ev.Threshold, ev.SavedFlag
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    INNER JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    LEFT  JOIN dbo.Branchmaster bm ON bm.BranchID = lo.BranchId
    LEFT  JOIN dbo.LabUnitMaster u ON u.Unit_ID = lim.Unit_ID
    CROSS APPLY dbo.ufn_LabCriticalEval(sc.InvestigationID, ISNULL(bm.CompanyId, 1),
                    CASE WHEN p.DateOfBirth IS NULL THEN NULL
                         ELSE DATEDIFF(YEAR, p.DateOfBirth, lo.OrderDate)
                              - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, lo.OrderDate), p.DateOfBirth) > lo.OrderDate THEN 1 ELSE 0 END END,
                    p.Gender, CAST(COALESCE(led.Submitted_Date, led.Drafted_Date, led.CreatedDate, GETDATE()) AS DATE),
                    led.TestValue, led.AbnormalFlag, COALESCE(NULLIF(u.Unit_Symbol, ''), u.Unit_Name, '')) ev
    WHERE sc.Laborderid = @LabOrderId
      AND sc.Is_Active = 1 AND ISNULL(sc.Iscancelled, 0) = 0
      AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> ''
      AND ((ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @BranchId)
           OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @BranchId))
);
GO

-- ============================================================================
-- Critical results of a bill, their communication state, and whether each blocks sign-off.
-- @Context: SIGNOFF (Pathologist Dashboard; blocks only at the final level of the approval flow), ENTRY (Report Entry
-- approval, always final), REGISTER (LR-16, never blocks). A result blocks while it has no active Informed or
-- Attempted record. @SampleIds: comma list, NULL = every critical result of the bill.
-- RS1 results · RS2 contacts to prefill (patient, referring doctor, partner) · RS3 history of the records.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_LabCritical_GetPending
    @BranchId     INT,
    @LabOrderId   INT,
    @SampleIds    NVARCHAR(MAX) = NULL,
    @Context      VARCHAR(10)   = 'REGISTER',
    @UserId       INT           = NULL,
    @IsSuperAdmin BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    SET @Context = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(@Context)), ''), 'REGISTER'));
    -- Hospital Settings > LAB > Critical Value Communication Required: off = nothing ever blocks a sign-off
    DECLARE @Enabled BIT = ISNULL((SELECT TOP 1 CriticalValueCommunicationRequired FROM dbo.HospitalSettings WHERE BranchID = @BranchId), 0);

    DECLARE @Ids TABLE (Id BIGINT PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@SampleIds)), '') IS NOT NULL
        INSERT INTO @Ids SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS BIGINT) FROM STRING_SPLIT(@SampleIds, ',')
        WHERE TRY_CAST(LTRIM(RTRIM(value)) AS BIGINT) IS NOT NULL;
    DECLARE @All BIT = CASE WHEN EXISTS (SELECT 1 FROM @Ids) THEN 0 ELSE 1 END;

    SELECT r.* INTO #R
    FROM dbo.ufn_LabCriticalOrderResults(@BranchId, @LabOrderId) r
    WHERE r.IsCritical = 1 AND (@All = 1 OR r.SampleId IN (SELECT Id FROM @Ids));

    -- final level? (sign-off: the pathologist's next level is the flow's last; Report Entry approval is always final)
    SELECT s.SamplecollectionID, CAST(CASE WHEN s.NextLevelNo IS NOT NULL AND s.NextLevelNo >= s.TotalLevels THEN 1 ELSE 0 END AS BIT) AS IsFinal,
           s.NextLevelNo, s.TotalLevels
    INTO #L
    FROM dbo.ufn_LabPathologistScope(@UserId, @BranchId) s
    WHERE @Context = 'SIGNOFF' AND s.LabOrderId = @LabOrderId;

    SELECT r.SampleId, r.LabEntryDetailId, r.InvestigationID, r.TestCode, r.TestName, r.ProfileName, r.TestValue, r.Unit,
           r.Severity, r.ThresholdDir, r.Threshold, r.SavedFlag, r.ReportStatusId, r.EnteredOn, r.ApprovedOn,
           CAST(CASE WHEN @Context = 'ENTRY' THEN 1 WHEN @Context = 'SIGNOFF' THEN ISNULL(l.IsFinal, 0) ELSE 0 END AS BIT) AS IsFinal,
           l.NextLevelNo, l.TotalLevels,
           CASE WHEN inf.CommunicationId IS NOT NULL THEN 'INFORMED' WHEN lst.CommunicationId IS NOT NULL THEN 'ATTEMPTED' ELSE 'NOTRECORDED' END AS CommunicationStatus,
           inf.CommunicationId AS InformedId, inf.InformedName, inf.InformedRole, inf.Mode AS InformedMode, inf.InformedOn, inf.ReadBack,
           CAST(CASE WHEN inf.CommunicationId IS NOT NULL AND inf.ResultValue <> r.TestValue THEN 1 ELSE 0 END AS BIT) AS ValueChangedSinceInformed,
           lst.Outcome AS LastOutcome, lst.InformedName AS LastName, lst.Mode AS LastMode, lst.InformedOn AS LastOn, lst.Remarks AS LastRemarks,
           lst.MessageStatus AS LastMessageStatus,
           (SELECT COUNT(1) FROM dbo.LabCriticalCommunication c WHERE c.SamplecollectionID = r.SampleId AND c.IsActive = 1) AS Attempts
    INTO #O
    FROM #R r
    LEFT JOIN #L l ON l.SamplecollectionID = r.SampleId
    OUTER APPLY (SELECT TOP 1 * FROM dbo.LabCriticalCommunication c
                  WHERE c.SamplecollectionID = r.SampleId AND c.IsActive = 1 AND c.Outcome = 'INFORMED' ORDER BY c.InformedOn, c.CommunicationId) inf
    OUTER APPLY (SELECT TOP 1 * FROM dbo.LabCriticalCommunication c
                  WHERE c.SamplecollectionID = r.SampleId AND c.IsActive = 1 ORDER BY c.InformedOn DESC, c.CommunicationId DESC) lst;

    -- RS1
    SELECT o.*, CAST(CASE WHEN @Enabled = 1 AND o.IsFinal = 1 AND o.CommunicationStatus = 'NOTRECORDED' AND o.ReportStatusId <> 5 THEN 1 ELSE 0 END AS BIT) AS BlocksSignoff
    FROM #O o ORDER BY CASE o.Severity WHEN 'PANIC' THEN 0 ELSE 1 END, o.TestName;

    -- RS2 contacts to prefill the form
    SELECT lo.LabOrderId, lo.BillNo, lo.TokenNo, CAST(ISNULL(lo.IsB2B, 0) AS BIT) AS IsB2B,
           LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           p.PatientCode, NULLIF(LTRIM(RTRIM(p.PhoneNumber)), '') AS PatientPhone, NULLIF(LTRIM(RTRIM(p.EmailId)), '') AS PatientEmail,
           COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)), ''),
                    NULLIF(LTRIM(RTRIM(ISNULL(rd.Salutation, '') + ' ' + ISNULL(rd.DoctorName, ''))), '')) AS RefDoctorName,
           COALESCE(NULLIF(LTRIM(RTRIM(d.PhoneNumber)), ''), NULLIF(LTRIM(RTRIM(rd.PhoneNumber)), '')) AS RefDoctorPhone,
           COALESCE(NULLIF(LTRIM(RTRIM(d.EmailId)), ''), NULLIF(LTRIM(RTRIM(rd.EmailId)), '')) AS RefDoctorEmail,
           CASE lo.AgentType WHEN 'F' THEN f.Franchise_Name WHEN 'C' THEN c.Corporate_Name END AS PartnerName,
           CASE lo.AgentType WHEN 'F' THEN NULLIF(LTRIM(RTRIM(f.Mobile_No)), '') WHEN 'C' THEN NULLIF(LTRIM(RTRIM(c.Contact_No)), '') END AS PartnerPhone,
           CASE lo.AgentType WHEN 'F' THEN NULLIF(LTRIM(RTRIM(f.Email)), '') WHEN 'C' THEN NULLIF(LTRIM(RTRIM(c.Email)), '') END AS PartnerEmail,
           ISNULL((SELECT TOP 1 hs.CriticalValueInformMinutes FROM dbo.HospitalSettings hs WHERE hs.BranchID = @BranchId), 30) AS TargetMinutes,
           @Enabled AS CommunicationEnabled
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = lo.RefDoctorId
    LEFT JOIN dbo.ReferralDoctorMaster rd ON rd.ReferralDoctorId = lo.ReferralDoctorId
    LEFT JOIN dbo.LabFranchiseMaster f ON lo.AgentType = 'F' AND f.Franchise_ID = lo.B2BAgentID
    LEFT JOIN dbo.CorporateMaster c ON lo.AgentType = 'C' AND c.Corporate_ID = lo.B2BAgentID
    WHERE lo.LabOrderId = @LabOrderId;

    -- RS3 history of the records of these results (corrected ones included)
    SELECT c.CommunicationId, c.SamplecollectionID AS SampleId, c.Outcome, c.InformedName, c.InformedRole, c.ContactNo, c.Mode,
           c.InformedOn, c.ReadBack, c.Remarks, c.ResultValue, c.Source, c.IsActive, c.CorrectsId, c.MessageStatus, c.MessageError,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS RecordedBy, c.RecordedOn
    FROM dbo.LabCriticalCommunication c
    LEFT JOIN dbo.Users u ON u.Id = c.RecordedBy
    WHERE c.SamplecollectionID IN (SELECT SampleId FROM #O)
    ORDER BY c.SamplecollectionID, c.InformedOn, c.CommunicationId;

    DROP TABLE #O; DROP TABLE #L; DROP TABLE #R;
END;
GO

-- ============================================================================
-- Records critical value communication for results of one bill. @Items (JSON array):
--   [{ "sampleId", "outcome": INFORMED / ATTEMPTED, "informedName", "informedRole", "contactNo", "mode",
--      "informedOn" (local date & time), "readBack", "remarks", "correctsId" }]
-- Every item must be a critical result of the bill held by the branch. Informed at: not in the future and not before
-- the result was entered. A phone / WhatsApp / SMS needs the number; an attempt needs the reason. A correction
-- switches the corrected record off (it stays in the history). Returns the rows written.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_LabCritical_Record
    @BranchId     INT,
    @LabOrderId   INT,
    @Items        NVARCHAR(MAX),
    @Source       VARCHAR(15)   = 'REGISTER',
    @UserId       INT,
    @IsSuperAdmin BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    SET @Source = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(@Source)), ''), 'REGISTER'));
    IF @Source NOT IN ('SIGNOFF', 'ENTRY', 'REGISTER') SET @Source = 'REGISTER';
    IF ISNULL((SELECT TOP 1 CriticalValueCommunicationRequired FROM dbo.HospitalSettings WHERE BranchID = @BranchId), 0) = 0
    BEGIN RAISERROR('Critical value communication is switched off for this branch (Hospital Settings > LAB).', 16, 1); RETURN; END
    IF ISJSON(@Items) <> 1 BEGIN RAISERROR('Nothing to record.', 16, 1); RETURN; END

    SELECT j.SampleId, UPPER(LTRIM(RTRIM(j.Outcome))) AS Outcome, NULLIF(LTRIM(RTRIM(j.InformedName)), '') AS InformedName,
           UPPER(LTRIM(RTRIM(j.InformedRole))) AS InformedRole, NULLIF(LTRIM(RTRIM(j.ContactNo)), '') AS ContactNo,
           UPPER(LTRIM(RTRIM(j.Mode))) AS Mode, TRY_CAST(j.InformedOn AS DATETIME) AS InformedOn, ISNULL(j.ReadBack, 0) AS ReadBack,
           NULLIF(LTRIM(RTRIM(j.Remarks)), '') AS Remarks, j.CorrectsId, ISNULL(j.SendMessage, 0) AS SendMessage
    INTO #I
    FROM OPENJSON(@Items) WITH (
        SampleId BIGINT '$.sampleId', Outcome VARCHAR(20) '$.outcome', InformedName NVARCHAR(200) '$.informedName',
        InformedRole VARCHAR(30) '$.informedRole', ContactNo NVARCHAR(60) '$.contactNo', Mode VARCHAR(30) '$.mode',
        InformedOn NVARCHAR(40) '$.informedOn', ReadBack BIT '$.readBack', Remarks NVARCHAR(1000) '$.remarks', CorrectsId BIGINT '$.correctsId',
        SendMessage BIT '$.sendMessage') j;

    IF NOT EXISTS (SELECT 1 FROM #I) BEGIN RAISERROR('Nothing to record.', 16, 1); RETURN; END
    IF EXISTS (SELECT SampleId FROM #I GROUP BY SampleId HAVING COUNT(1) > 1)
    BEGIN RAISERROR('Each result can be recorded once per save.', 16, 1); RETURN; END

    SELECT r.* INTO #R FROM dbo.ufn_LabCriticalOrderResults(@BranchId, @LabOrderId) r WHERE r.IsCritical = 1;

    DECLARE @msg NVARCHAR(400), @Now DATETIME = GETDATE();
    SELECT TOP 1 @msg = N'This is not a critical / panic result of this branch (sample ' + CAST(i.SampleId AS NVARCHAR(20)) + N').'
    FROM #I i WHERE NOT EXISTS (SELECT 1 FROM #R r WHERE r.SampleId = i.SampleId);
    IF @msg IS NOT NULL BEGIN RAISERROR(@msg, 16, 1); RETURN; END

    SELECT TOP 1 @msg = r.TestName + N': ' +
           CASE WHEN i.Outcome NOT IN ('INFORMED', 'ATTEMPTED') THEN N'choose Informed or Attempted.'
                WHEN i.InformedName IS NULL THEN N'enter the name of the person ' + CASE WHEN i.Outcome = 'INFORMED' THEN N'informed.' ELSE N'you tried to reach.' END
                WHEN LEN(i.InformedName) > 150 THEN N'the name is too long (150 characters at most).'
                WHEN i.InformedRole NOT IN ('REFDOCTOR', 'TREATDOCTOR', 'PATIENT', 'ATTENDANT', 'WARD', 'PARTNER', 'OTHER') THEN N'choose who the person is.'
                WHEN i.Mode NOT IN ('PHONE', 'INPERSON', 'WHATSAPP', 'SMS', 'EMAIL') THEN N'choose how they were contacted.'
                WHEN i.Mode IN ('PHONE', 'WHATSAPP', 'SMS') AND i.ContactNo IS NULL THEN N'enter the number that was called / messaged.'
                WHEN i.Mode = 'EMAIL' AND (i.ContactNo IS NULL OR i.ContactNo NOT LIKE '%_@_%._%') THEN N'enter the email address that was written to.'
                WHEN i.Mode IN ('PHONE', 'WHATSAPP', 'SMS') AND LEN(i.ContactNo) > 30 THEN N'the contact number is too long.'
                WHEN LEN(ISNULL(i.ContactNo, '')) > 150 THEN N'the email address is too long.'
                WHEN i.SendMessage = 1 AND i.Mode NOT IN ('WHATSAPP', 'EMAIL') THEN N'only a WhatsApp message or an email can be sent from here.'
                WHEN i.InformedOn IS NULL THEN N'enter the date and time.'
                WHEN i.InformedOn > DATEADD(MINUTE, 5, @Now) THEN N'the date and time cannot be in the future.'
                WHEN r.EnteredOn IS NOT NULL AND i.InformedOn < DATEADD(MINUTE, -1, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, r.EnteredOn), 0))
                    THEN N'the date and time cannot be before the result was entered (' + FORMAT(r.EnteredOn, 'dd MMM yyyy, hh:mm tt') + N').'
                WHEN i.Outcome = 'ATTEMPTED' AND i.Remarks IS NULL THEN N'enter why the person could not be reached.'
                WHEN LEN(ISNULL(i.Remarks, '')) > 500 THEN N'remarks are too long (500 characters at most).'
                WHEN i.CorrectsId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.LabCriticalCommunication c
                                                              WHERE c.CommunicationId = i.CorrectsId AND c.SamplecollectionID = i.SampleId AND c.IsActive = 1)
                    THEN N'the record being corrected was not found or was already corrected.'
           END
    FROM #I i INNER JOIN #R r ON r.SampleId = i.SampleId
    WHERE i.Outcome NOT IN ('INFORMED', 'ATTEMPTED') OR i.InformedName IS NULL OR LEN(i.InformedName) > 150
       OR i.InformedRole NOT IN ('REFDOCTOR', 'TREATDOCTOR', 'PATIENT', 'ATTENDANT', 'WARD', 'PARTNER', 'OTHER')
       OR i.Mode NOT IN ('PHONE', 'INPERSON', 'WHATSAPP', 'SMS', 'EMAIL')
       OR (i.Mode IN ('PHONE', 'WHATSAPP', 'SMS') AND i.ContactNo IS NULL)
       OR (i.Mode = 'EMAIL' AND (i.ContactNo IS NULL OR i.ContactNo NOT LIKE '%_@_%._%'))
       OR (i.Mode IN ('PHONE', 'WHATSAPP', 'SMS') AND LEN(i.ContactNo) > 30) OR LEN(ISNULL(i.ContactNo, '')) > 150
       OR (i.SendMessage = 1 AND i.Mode NOT IN ('WHATSAPP', 'EMAIL'))
       OR i.InformedOn IS NULL OR i.InformedOn > DATEADD(MINUTE, 5, @Now)
       OR (r.EnteredOn IS NOT NULL AND i.InformedOn < DATEADD(MINUTE, -1, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, r.EnteredOn), 0)))
       OR (i.Outcome = 'ATTEMPTED' AND i.Remarks IS NULL) OR LEN(ISNULL(i.Remarks, '')) > 500
       OR (i.CorrectsId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.LabCriticalCommunication c
                                                    WHERE c.CommunicationId = i.CorrectsId AND c.SamplecollectionID = i.SampleId AND c.IsActive = 1));
    IF @msg IS NOT NULL BEGIN RAISERROR(@msg, 16, 1); RETURN; END

    DECLARE @Out TABLE (CommunicationId BIGINT, SampleId BIGINT);
    BEGIN TRAN;
        UPDATE c SET IsActive = 0, CorrectedBy = @UserId, CorrectedOn = @Now
        FROM dbo.LabCriticalCommunication c INNER JOIN #I i ON i.CorrectsId = c.CommunicationId;

        INSERT INTO dbo.LabCriticalCommunication
            (SamplecollectionID, LabEntryDetailId, LabOrderId, InvestigationID, BranchId, Severity, ResultValue, Unit, Threshold,
             Outcome, InformedName, InformedRole, ContactNo, Mode, InformedOn, ReadBack, Remarks, Source, RecordedBy, RecordedOn, CorrectsId, MessageStatus)
        OUTPUT inserted.CommunicationId, inserted.SamplecollectionID INTO @Out
        SELECT i.SampleId, r.LabEntryDetailId, r.LabOrderId, r.InvestigationID, @BranchId, r.Severity, LEFT(r.TestValue, 100), NULLIF(r.Unit, ''), r.Threshold,
               i.Outcome, i.InformedName, i.InformedRole, i.ContactNo, i.Mode, i.InformedOn,
               CASE WHEN i.Outcome = 'INFORMED' THEN i.ReadBack ELSE 0 END, i.Remarks, @Source, @UserId, @Now, i.CorrectsId,
               CASE WHEN i.SendMessage = 1 THEN 'QUEUED' END
        FROM #I i INNER JOIN #R r ON r.SampleId = i.SampleId;
    COMMIT;

    SELECT c.CommunicationId, c.SamplecollectionID AS SampleId, r.TestName, c.ResultValue, c.Unit, c.Severity, c.Outcome,
           c.InformedName, c.InformedRole, c.ContactNo, c.Mode, c.InformedOn, c.ReadBack, c.Remarks, c.CorrectsId, c.MessageStatus
    FROM @Out o
    INNER JOIN dbo.LabCriticalCommunication c ON c.CommunicationId = o.CommunicationId
    INNER JOIN #R r ON r.SampleId = o.SampleId;

    DROP TABLE #R; DROP TABLE #I;
END;
GO

-- ============================================================================
-- Messages sent from the application (EMR.Web LabCriticalNotificationService)
-- GetMessageData: the queued records with what the message needs (lab name & phone, patient, bill, results).
-- SetMessageStatus: SENT, or FAILED - a failed message is not a communication: the record becomes "Attempted" with
-- the error as its reason, so LR-16 and the sign-off check never count it as informed.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_LabCritical_GetMessageData
    @CommunicationIds NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT c.CommunicationId, c.LabOrderId, c.BranchId, c.Mode, c.ContactNo, c.InformedName, c.InformedRole, c.Severity,
           c.ResultValue, c.Unit, c.Threshold, c.InformedOn, lim.Test_Name AS TestName, NULLIF(sc.ProfileName, '') AS ProfileName,
           lo.BillNo, LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           p.PatientCode,
           COALESCE(NULLIF(LTRIM(RTRIM(hs.HotelName)), ''), bm.BranchName) AS LabName,
           COALESCE(NULLIF(LTRIM(RTRIM(hs.EmergencyNumber)), ''), NULLIF(LTRIM(RTRIM(hs.ContactNumber1)), '')) AS LabPhone,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS RecordedBy
    FROM dbo.LabCriticalCommunication c
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = c.LabOrderId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = c.SamplecollectionID
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = c.InvestigationID
    LEFT  JOIN dbo.Branchmaster bm ON bm.BranchID = c.BranchId
    OUTER APPLY (SELECT TOP 1 h.HotelName, h.EmergencyNumber, h.ContactNumber1 FROM dbo.HospitalSettings h WHERE h.BranchID = c.BranchId) hs
    LEFT  JOIN dbo.Users u ON u.Id = c.RecordedBy
    WHERE c.MessageStatus = 'QUEUED' AND c.IsActive = 1
      AND c.CommunicationId IN (SELECT TRY_CAST(value AS BIGINT) FROM STRING_SPLIT(@CommunicationIds, ','));
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LabCritical_SetMessageStatus
    @CommunicationIds NVARCHAR(MAX),
    @Status           VARCHAR(10),
    @MessageRef       NVARCHAR(100) = NULL,
    @MessageError     NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE c SET MessageStatus = @Status, MessageRef = LEFT(@MessageRef, 100), MessageError = LEFT(@MessageError, 500), MessageOn = GETDATE(),
                 Outcome = CASE WHEN @Status = 'FAILED' THEN 'ATTEMPTED' ELSE c.Outcome END,
                 ReadBack = CASE WHEN @Status = 'FAILED' THEN 0 ELSE c.ReadBack END,
                 Remarks = CASE WHEN @Status = 'FAILED'
                                THEN LEFT(CONCAT(c.Remarks, CASE WHEN c.Remarks IS NOT NULL THEN N' · ' END,
                                                 CASE c.Mode WHEN 'EMAIL' THEN N'Email' ELSE N'WhatsApp' END, N' not sent: ', ISNULL(@MessageError, N'unknown error')), 500)
                                ELSE c.Remarks END
    FROM dbo.LabCriticalCommunication c
    WHERE c.MessageStatus = 'QUEUED'
      AND c.CommunicationId IN (SELECT TRY_CAST(value AS BIGINT) FROM STRING_SPLIT(@CommunicationIds, ','));
    SELECT @@ROWCOUNT AS Updated;
END;
GO

-- ============================================================================
-- LR-16 Critical & Panic Value Register (2201) + communication: who was informed, how, when, by whom, read-back,
-- minutes from result entry to informing against the branch's target (HospitalSettings.CriticalValueInformMinutes,
-- empty = 30). Critical detection now comes from dbo.ufn_LabCriticalEval (the rule sign-off uses).
-- Own data: results they entered, updated or signed, or whose communication they recorded.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_CriticalValues
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @Severity      VARCHAR(10)   = NULL,   -- CRITICAL / PANIC
    @ResultStatus  VARCHAR(10)   = NULL,   -- APPROVED / PENDING
    @Communication VARCHAR(12)   = NULL,   -- INFORMED / ATTEMPTED / NOTRECORDED / LATE
    @DepartmentId  INT           = NULL,
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @OwnOnly BIT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN 1 ELSE 0 END;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @Severity = NULLIF(UPPER(LTRIM(RTRIM(@Severity))), '');
    SET @ResultStatus = NULLIF(UPPER(LTRIM(RTRIM(@ResultStatus))), '');
    SET @Communication = NULLIF(UPPER(LTRIM(RTRIM(@Communication))), '');
    DECLARE @Target INT = ISNULL((SELECT TOP 1 CriticalValueInformMinutes FROM dbo.HospitalSettings WHERE BranchID = @BranchId), 30);
    DECLARE @Enabled BIT = ISNULL((SELECT TOP 1 CriticalValueCommunicationRequired FROM dbo.HospitalSettings WHERE BranchID = @BranchId), 0);

    SELECT r.*, ev.IsCritical, ev.Severity, ev.ThresholdDir, ev.RangeTier, ev.Threshold
    INTO #C
    FROM dbo.ufn_LabReport_Results(@BranchId, @From, @To) r
    CROSS APPLY dbo.ufn_LabCriticalEval(r.InvestigationID, r.CompanyId, r.AgeYears, r.Gender, CAST(r.EnteredOn AS DATE),
                                        r.TestValue, r.AbnormalFlag, r.Unit) ev
    WHERE ev.IsCritical = 1;

    SELECT c.LabEntryDetailId, c.SampleId, c.LabOrderId, c.BillNo, c.TokenNo, c.PatientCode, c.PatientName, c.PhoneNumber, c.Gender, c.AgeYears,
           c.TestCode, c.TestName, c.ProfileName, c.DepartmentId, ISNULL(dm.DeptName, 'Not set') AS Department,
           c.TestValue, c.Unit, c.ThresholdDir, c.Severity, c.Threshold, c.RangeTier, c.AbnormalFlag AS SavedFlag,
           c.EnteredOn, CONVERT(VARCHAR(10), CAST(c.EnteredOn AS DATE), 23) AS EnteredDay,
           c.EnteredById, NULLIF(LTRIM(RTRIM(eu.FullName)), '') AS EnteredBy,
           CASE WHEN c.ReportStatusId = 5 THEN 'APPROVED' ELSE 'PENDING' END AS ResultStatus,
           c.ApprovedOn, ISNULL(NULLIF(LTRIM(RTRIM(au.FullName)), ''), au.Username) AS ApprovedBy,
           CAST(CASE WHEN c.ApprovedOn >= c.EnteredOn THEN DATEDIFF(MINUTE, c.EnteredOn, c.ApprovedOn) / 60.0 END AS DECIMAL(10, 1)) AS HoursToApproval,
           -- communication
           CASE WHEN inf.CommunicationId IS NOT NULL THEN 'INFORMED' WHEN lst.CommunicationId IS NOT NULL THEN 'ATTEMPTED' ELSE 'NOTRECORDED' END AS CommunicationStatus,
           inf.CommunicationId AS InformedId, inf.InformedName, inf.InformedRole, inf.ContactNo AS InformedContact, inf.Mode AS InformedMode,
           inf.InformedOn, inf.ReadBack, NULLIF(LTRIM(RTRIM(iu.FullName)), '') AS InformedBy,
           CASE WHEN inf.InformedOn >= c.EnteredOn THEN DATEDIFF(MINUTE, c.EnteredOn, inf.InformedOn)
                WHEN inf.InformedOn IS NOT NULL THEN 0 END AS MinutesToInform,
           CAST(CASE WHEN inf.CommunicationId IS NOT NULL AND inf.ResultValue <> c.TestValue THEN 1 ELSE 0 END AS BIT) AS ValueChangedSinceInformed,
           lst.Outcome AS LastOutcome, lst.InformedName AS LastName, lst.Mode AS LastMode, lst.InformedOn AS LastOn, lst.Remarks AS LastRemarks,
           inf.MessageStatus AS InformedMessageStatus, lst.MessageStatus AS LastMessageStatus,
           (SELECT COUNT(1) FROM dbo.LabCriticalCommunication x WHERE x.SamplecollectionID = c.SampleId AND x.IsActive = 1) AS Attempts,
           @Target AS TargetMinutes
    INTO #R
    FROM #C c
    LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = c.DepartmentId
    LEFT JOIN dbo.Users eu ON eu.Id = c.EnteredById
    OUTER APPLY (SELECT TOP 1 a.ApprovedBy FROM dbo.LabReportApproval a WHERE a.SamplecollectionID = c.SampleId ORDER BY a.Level_No DESC, a.ApprovalId DESC) fa
    LEFT JOIN dbo.Users au ON au.Id = fa.ApprovedBy
    OUTER APPLY (SELECT TOP 1 * FROM dbo.LabCriticalCommunication x
                  WHERE x.SamplecollectionID = c.SampleId AND x.IsActive = 1 AND x.Outcome = 'INFORMED' ORDER BY x.InformedOn, x.CommunicationId) inf
    LEFT JOIN dbo.Users iu ON iu.Id = inf.RecordedBy
    OUTER APPLY (SELECT TOP 1 * FROM dbo.LabCriticalCommunication x
                  WHERE x.SamplecollectionID = c.SampleId AND x.IsActive = 1 ORDER BY x.InformedOn DESC, x.CommunicationId DESC) lst
    WHERE (@OwnOnly = 0 OR c.EnteredById = @UserId OR c.UpdatedById = @UserId
           OR EXISTS (SELECT 1 FROM dbo.LabReportApproval a2 WHERE a2.SamplecollectionID = c.SampleId AND a2.ApprovedBy = @UserId)
           OR EXISTS (SELECT 1 FROM dbo.LabCriticalCommunication x2 WHERE x2.SamplecollectionID = c.SampleId AND x2.RecordedBy = @UserId))
      AND (@DepartmentId IS NULL OR c.DepartmentId = @DepartmentId)
      AND (@Search IS NULL OR c.BillNo LIKE '%' + @Search + '%' OR c.TokenNo LIKE '%' + @Search + '%' OR c.PatientCode LIKE '%' + @Search + '%'
           OR c.PatientName LIKE '%' + @Search + '%' OR c.PhoneNumber LIKE '%' + @Search + '%' OR c.TestName LIKE '%' + @Search + '%');

    ALTER TABLE #R ADD WithinTarget BIT, CommunicationGroup VARCHAR(30);
    UPDATE #R SET WithinTarget = CASE WHEN MinutesToInform IS NULL THEN NULL WHEN MinutesToInform <= TargetMinutes THEN 1 ELSE 0 END;
    UPDATE #R SET CommunicationGroup = CASE WHEN CommunicationStatus = 'INFORMED' AND WithinTarget = 1 THEN 'Informed within target'
                                            WHEN CommunicationStatus = 'INFORMED' THEN 'Informed late'
                                            WHEN CommunicationStatus = 'ATTEMPTED' THEN 'Attempted, not reached'
                                            ELSE 'Not recorded' END;

    IF @Severity IS NOT NULL DELETE FROM #R WHERE Severity <> @Severity;
    IF @ResultStatus IS NOT NULL DELETE FROM #R WHERE ResultStatus <> @ResultStatus;
    IF @Communication = 'LATE' DELETE FROM #R WHERE NOT (CommunicationStatus = 'INFORMED' AND WithinTarget = 0);
    ELSE IF @Communication IS NOT NULL DELETE FROM #R WHERE CommunicationStatus <> @Communication;

    -- RS1 summary
    SELECT COUNT(1) AS Flagged, SUM(CASE WHEN Severity = 'PANIC' THEN 1 ELSE 0 END) AS Panic,
           SUM(CASE WHEN Severity = 'CRITICAL' THEN 1 ELSE 0 END) AS Critical,
           COUNT(DISTINCT PatientCode) AS Patients,
           SUM(CASE WHEN ResultStatus = 'PENDING' THEN 1 ELSE 0 END) AS AwaitingApproval,
           CAST(AVG(HoursToApproval) AS DECIMAL(10, 1)) AS AvgHoursToApproval,
           (SELECT TOP 1 TestName FROM #R GROUP BY TestName ORDER BY COUNT(1) DESC, TestName) AS TopTest,
           SUM(CASE WHEN CommunicationStatus = 'INFORMED' THEN 1 ELSE 0 END) AS Informed,
           SUM(CASE WHEN CommunicationStatus = 'ATTEMPTED' THEN 1 ELSE 0 END) AS Attempted,
           SUM(CASE WHEN CommunicationStatus = 'NOTRECORDED' THEN 1 ELSE 0 END) AS NotRecorded,
           SUM(CASE WHEN WithinTarget = 1 THEN 1 ELSE 0 END) AS InformedWithinTarget,
           CAST(100.0 * SUM(CASE WHEN CommunicationStatus = 'INFORMED' THEN 1 ELSE 0 END) / NULLIF(COUNT(1), 0) AS DECIMAL(6, 1)) AS InformedPct,
           -- NABL QI: critical values informed within the target time, out of all critical values
           CAST(100.0 * SUM(CASE WHEN WithinTarget = 1 THEN 1 ELSE 0 END) / NULLIF(COUNT(1), 0) AS DECIMAL(6, 1)) AS WithinTargetPct,
           CAST(AVG(CAST(MinutesToInform AS DECIMAL(10, 1))) AS DECIMAL(10, 1)) AS AvgMinutesToInform,
           SUM(CASE WHEN CommunicationStatus = 'INFORMED' AND ReadBack = 1 THEN 1 ELSE 0 END) AS ReadBackCount,
           @Target AS TargetMinutes, @Enabled AS CommunicationEnabled
    FROM #R;

    -- RS2 groups
    ;WITH g AS (
        SELECT 'byTest' AS GroupKey, NULL AS GroupId, TestName AS GroupName, 0 AS SortOrder, * FROM #R
        UNION ALL SELECT 'bySeverity', NULL, Severity, CASE Severity WHEN 'PANIC' THEN 0 ELSE 1 END, * FROM #R
        UNION ALL SELECT 'byCommunication', NULL, CommunicationGroup,
                         CASE CommunicationGroup WHEN 'Not recorded' THEN 0 WHEN 'Attempted, not reached' THEN 1 WHEN 'Informed late' THEN 2 ELSE 3 END, * FROM #R
        UNION ALL SELECT 'byDepartment', DepartmentId, Department, 0, * FROM #R
        UNION ALL SELECT 'byStatus', NULL, ResultStatus, CASE ResultStatus WHEN 'PENDING' THEN 0 ELSE 1 END, * FROM #R
        UNION ALL SELECT 'byDate', NULL, EnteredDay, 0, * FROM #R)
    SELECT GroupKey, GroupId, GroupName, MIN(SortOrder) AS SortOrder,
           COUNT(1) AS Flagged, SUM(CASE WHEN Severity = 'PANIC' THEN 1 ELSE 0 END) AS Panic,
           SUM(CASE WHEN Severity = 'CRITICAL' THEN 1 ELSE 0 END) AS Critical,
           SUM(CASE WHEN ThresholdDir = 'L' THEN 1 ELSE 0 END) AS Low, SUM(CASE WHEN ThresholdDir = 'H' THEN 1 ELSE 0 END) AS High,
           SUM(CASE WHEN ResultStatus = 'PENDING' THEN 1 ELSE 0 END) AS AwaitingApproval,
           CAST(AVG(HoursToApproval) AS DECIMAL(10, 1)) AS AvgHoursToApproval,
           SUM(CASE WHEN CommunicationStatus = 'INFORMED' THEN 1 ELSE 0 END) AS Informed,
           SUM(CASE WHEN WithinTarget = 1 THEN 1 ELSE 0 END) AS InformedWithinTarget,
           SUM(CASE WHEN CommunicationStatus = 'NOTRECORDED' THEN 1 ELSE 0 END) AS NotRecorded,
           CAST(AVG(CAST(MinutesToInform AS DECIMAL(10, 1))) AS DECIMAL(10, 1)) AS AvgMinutesToInform
    FROM g GROUP BY GroupKey, GroupId, GroupName
    ORDER BY GroupKey, MIN(SortOrder), COUNT(1) DESC, GroupName;

    -- RS3 rows: not yet informed first, then not yet approved, newest first
    SELECT * FROM #R ORDER BY CASE CommunicationStatus WHEN 'NOTRECORDED' THEN 0 WHEN 'ATTEMPTED' THEN 1 ELSE 2 END,
                              CASE ResultStatus WHEN 'PENDING' THEN 0 ELSE 1 END, EnteredOn DESC;

    -- RS4 filter options
    SELECT DISTINCT 'departmentId' AS FilterKey, CAST(DepartmentId AS VARCHAR(20)) AS Value, Department AS Text FROM #R WHERE DepartmentId IS NOT NULL;

    DROP TABLE #R; DROP TABLE #C;
END;
GO

-- ── permission control CRITICAL_COMM on the sign-off / entry / register pages ──
DECLARE @page INT, @ctl INT, @code NVARCHAR(150);
DECLARE pg CURSOR LOCAL FAST_FORWARD FOR
    SELECT Page_ID, Page_Code FROM dbo.PageMaster
    WHERE Page_Code IN (N'LAB.PATHOLOGISTDASHBOARD', N'LAB.LABREPORTING', N'LAB.MICROBIOLOGYREPORTING', N'REPORTS.LABCRITICAL');
OPEN pg; FETCH NEXT FROM pg INTO @page, @code;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'CRITICAL_COMM',
         @Title = N'Record critical value communication', @Sort_Order = 80, @Control_ID = @ctl OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST',
         @Controller = N'LabCriticalCommunication', @Action = N'Pending', @Route = N'LabCriticalCommunication/Pending', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST',
         @Controller = N'LabCriticalCommunication', @Action = N'Record', @Route = N'LabCriticalCommunication/Record', @Source = 'SEED';
    FETCH NEXT FROM pg INTO @page, @code;
END
CLOSE pg; DEALLOCATE pg;

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2202 applied: critical value communication record (LabCriticalCommunication, sign-off check, LR-16).';
GO
