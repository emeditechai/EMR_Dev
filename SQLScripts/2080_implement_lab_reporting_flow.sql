-- ============================================================
-- Script: 2080_implement_lab_reporting_flow.sql
-- Description:
--   1. Ensure dbo.labentrydetails.ReportStatusId allows NULL
--   2. Clean up invalid empty rows in dbo.labentrydetails (reset ReportStatusId = NULL where TestValue is empty)
--   3. Update dbo.usp_LabReporting_SaveEntry to:
--      - Only update status & dates for rows with non-empty TestValue
--      - Leave empty rows as ReportStatusId = NULL (Pending Entry)
--   4. Update dbo.usp_LabReporting_GetDetail to:
--      - Calculate overall order status in RS 1 (ReportStatusId, StatusCode, ReportStatusName, ReportBadgeClass, status dates)
--      - Force ReportStatusId = 0 / Pending Entry in RS 2 for any row with empty TestValue
-- ============================================================

USE Dev_EMR;
GO

-- 1. Ensure ReportStatusId is nullable
ALTER TABLE dbo.labentrydetails ALTER COLUMN ReportStatusId INT NULL;
GO

-- 2. Clean up test records: reset empty TestValues to ReportStatusId = NULL
UPDATE dbo.labentrydetails
SET 
    ReportStatusId = NULL,
    Drafted_Date = NULL,
    Submitted_Date = NULL,
    Validated_date = NULL,
    Approved_Date = NULL
WHERE LTRIM(RTRIM(ISNULL(TestValue, ''))) = '';

PRINT 'Cleaned up empty test entries to ReportStatusId = NULL.';
GO

-- 3. Update Stored Procedure: dbo.usp_LabReporting_SaveEntry
CREATE OR ALTER PROCEDURE dbo.usp_LabReporting_SaveEntry
    @LabOrderId         INT,
    @ReportStatusId     INT,
    @UserId             INT,
    @EntriesJson        NVARCHAR(MAX),
    @GroupRemarksJson   NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
    BEGIN
        RAISERROR('Valid LabOrderId is required.', 16, 1);
        RETURN;
    END

    DECLARE @StatusCode VARCHAR(30);
    SELECT @StatusCode = StatusCode FROM dbo.Reportentrystatus WHERE ReportStatusId = @ReportStatusId;

    IF @StatusCode IS NULL
    BEGIN
        RAISERROR('Invalid ReportStatusId.', 16, 1);
        RETURN;
    END

    DECLARE @PatientId INT;
    SELECT @PatientId = PatientId FROM dbo.LabOrder WHERE LabOrderId = @LabOrderId;

    IF @PatientId IS NULL
    BEGIN
        RAISERROR('LabOrder not found.', 16, 1);
        RETURN;
    END

    -- Temporary table for parsed entries
    CREATE TABLE #ParsedEntries (
        SamplecollectionID BIGINT,
        InvestigationID    INT,
        TestValue          NVARCHAR(MAX),
        Remarks            NVARCHAR(500),
        Reporting_Type     NVARCHAR(100),
        AbnormalFlag       VARCHAR(20)
    );

    INSERT INTO #ParsedEntries (SamplecollectionID, InvestigationID, TestValue, Remarks, Reporting_Type, AbnormalFlag)
    SELECT 
        COALESCE(j.samplecollectionID, j.SamplecollectionID, j.samplecollectionId, j.SampleCollectionId, 0),
        COALESCE(j.investigationID, j.InvestigationID, j.investigationId, 0),
        COALESCE(j.testValue, j.TestValue, ''),
        COALESCE(j.remarks, j.Remarks, ''),
        COALESCE(j.reportingType, j.ReportingType, j.reporting_type, j.Reporting_Type, ''),
        COALESCE(j.abnormalFlag, j.AbnormalFlag, j.flag, j.Flag, NULL)
    FROM OPENJSON(@EntriesJson)
    WITH (
        samplecollectionID BIGINT        '$.samplecollectionID',
        SamplecollectionID BIGINT        '$.SamplecollectionID',
        samplecollectionId BIGINT        '$.samplecollectionId',
        SampleCollectionId BIGINT        '$.SampleCollectionId',
        investigationID    INT           '$.investigationID',
        InvestigationID    INT           '$.InvestigationID',
        investigationId    INT           '$.investigationId',
        testValue          NVARCHAR(MAX) '$.testValue',
        TestValue          NVARCHAR(MAX) '$.TestValue',
        remarks            NVARCHAR(500) '$.remarks',
        Remarks            NVARCHAR(500) '$.Remarks',
        reportingType      NVARCHAR(100) '$.reportingType',
        ReportingType      NVARCHAR(100) '$.ReportingType',
        reporting_type     NVARCHAR(100) '$.reporting_type',
        Reporting_Type     NVARCHAR(100) '$.Reporting_Type',
        abnormalFlag       VARCHAR(20)   '$.abnormalFlag',
        AbnormalFlag       VARCHAR(20)   '$.AbnormalFlag',
        flag               VARCHAR(20)   '$.flag',
        Flag               VARCHAR(20)   '$.Flag'
    ) j
    WHERE COALESCE(j.samplecollectionID, j.SamplecollectionID, j.samplecollectionId, j.SampleCollectionId, 0) > 0;

    DECLARE @Now DATETIME = GETDATE();

    -- Update existing records in labentrydetails
    -- IMPORTANT: If pe.TestValue is empty, DO NOT update ReportStatusId or status dates for that row!
    UPDATE led
    SET 
        led.TestValue      = pe.TestValue,
        led.Remarks        = pe.Remarks,
        led.Reporting_Type = COALESCE(NULLIF(pe.Reporting_Type, ''), led.Reporting_Type, lim.Reporting_Type, 'Numeric'),
        led.AbnormalFlag   = pe.AbnormalFlag,
        led.ReportStatusId = CASE 
                                WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) <> '' THEN @ReportStatusId 
                                ELSE NULL 
                             END,
        led.ModifiedBy     = @UserId,
        led.ModifiedDate   = @Now,
        led.Drafted_Date   = CASE 
                                WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) <> '' AND (@ReportStatusId = 1 OR @StatusCode = 'DRAFT') THEN @Now 
                                WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) = '' THEN NULL
                                ELSE led.Drafted_Date 
                             END,
        led.Submitted_Date = CASE 
                                WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) <> '' AND (@ReportStatusId = 2 OR @StatusCode = 'REPORT_ENTRY') THEN @Now 
                                WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) = '' THEN NULL
                                ELSE led.Submitted_Date 
                             END,
        led.Validated_date = CASE 
                                WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) <> '' AND (@ReportStatusId = 3 OR @StatusCode = 'REPORT_VALIDATED') THEN @Now 
                                WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) = '' THEN NULL
                                ELSE led.Validated_date 
                             END,
        led.Approved_Date  = CASE 
                                WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) <> '' AND (@ReportStatusId = 5 OR @StatusCode IN ('REPORT_APPROVE', 'REPORT_APPROVED')) THEN @Now 
                                WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) = '' THEN NULL
                                ELSE led.Approved_Date 
                             END,
        led.IsActive       = 1
    FROM dbo.labentrydetails led
    INNER JOIN #ParsedEntries pe ON pe.SamplecollectionID = led.SamplecollectionID
    LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = pe.InvestigationID;

    -- Insert new records that don't exist yet
    -- IMPORTANT: If pe.TestValue is empty, insert with ReportStatusId = NULL and NULL status dates
    INSERT INTO dbo.labentrydetails (
        SamplecollectionID,
        LabOrderId,
        PatientId,
        InvestigationID,
        TestValue,
        Remarks,
        AbnormalFlag,
        ReportStatusId,
        Reporting_Type,
        Drafted_Date,
        Submitted_Date,
        Validated_date,
        Approved_Date,
        CreatedBy,
        CreatedDate,
        IsActive
    )
    SELECT 
        pe.SamplecollectionID,
        @LabOrderId,
        @PatientId,
        pe.InvestigationID,
        pe.TestValue,
        pe.Remarks,
        pe.AbnormalFlag,
        CASE WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) <> '' THEN @ReportStatusId ELSE NULL END,
        COALESCE(NULLIF(pe.Reporting_Type, ''), lim.Reporting_Type, 'Numeric'),
        CASE WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) <> '' AND (@ReportStatusId = 1 OR @StatusCode = 'DRAFT') THEN @Now ELSE NULL END,
        CASE WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) <> '' AND (@ReportStatusId = 2 OR @StatusCode = 'REPORT_ENTRY') THEN @Now ELSE NULL END,
        CASE WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) <> '' AND (@ReportStatusId = 3 OR @StatusCode = 'REPORT_VALIDATED') THEN @Now ELSE NULL END,
        CASE WHEN LTRIM(RTRIM(ISNULL(pe.TestValue, ''))) <> '' AND (@ReportStatusId = 5 OR @StatusCode IN ('REPORT_APPROVE', 'REPORT_APPROVED')) THEN @Now ELSE NULL END,
        @UserId,
        @Now,
        1
    FROM #ParsedEntries pe
    LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = pe.InvestigationID
    WHERE NOT EXISTS (
        SELECT 1 
        FROM dbo.labentrydetails led 
        WHERE led.SamplecollectionID = pe.SamplecollectionID
    );

    -- Process Header / Test Group Remarks if provided
    IF @GroupRemarksJson IS NOT NULL AND LTRIM(RTRIM(@GroupRemarksJson)) <> '' AND @GroupRemarksJson <> '[]'
    BEGIN
        MERGE dbo.LabReportTestRemarks AS target
        USING (
            SELECT 
                @LabOrderId AS LabOrderId,
                COALESCE(j.groupKey, j.GroupKey) AS GroupKey,
                COALESCE(j.headerName, j.HeaderName, '') AS HeaderName,
                COALESCE(j.profileId, j.ProfileId) AS ProfileId,
                COALESCE(j.investigationId, j.InvestigationId) AS InvestigationId,
                COALESCE(j.labRemarks, j.LabRemarks, '') AS LabRemarks
            FROM OPENJSON(@GroupRemarksJson)
            WITH (
                groupKey        VARCHAR(100)  '$.groupKey',
                GroupKey        VARCHAR(100)  '$.GroupKey',
                headerName      NVARCHAR(250) '$.headerName',
                HeaderName      NVARCHAR(250) '$.HeaderName',
                profileId       INT           '$.profileId',
                ProfileId       INT           '$.ProfileId',
                investigationId INT           '$.investigationId',
                InvestigationId INT           '$.InvestigationId',
                labRemarks      NVARCHAR(MAX) '$.labRemarks',
                LabRemarks      NVARCHAR(MAX) '$.LabRemarks'
            ) j
            WHERE COALESCE(j.groupKey, j.GroupKey) IS NOT NULL 
              AND LTRIM(RTRIM(COALESCE(j.groupKey, j.GroupKey))) <> ''
        ) AS src
        ON (target.LabOrderId = src.LabOrderId AND target.GroupKey = src.GroupKey)
        WHEN MATCHED THEN
            UPDATE SET 
                target.LabRemarks      = src.LabRemarks,
                target.HeaderName      = src.HeaderName,
                target.ProfileId       = src.ProfileId,
                target.InvestigationId = src.InvestigationId,
                target.ModifiedBy      = @UserId,
                target.ModifiedDate    = @Now,
                target.IsActive        = 1
        WHEN NOT MATCHED THEN
            INSERT (LabOrderId, GroupKey, HeaderName, ProfileId, InvestigationId, LabRemarks, CreatedBy, CreatedDate, IsActive)
            VALUES (src.LabOrderId, src.GroupKey, src.HeaderName, src.ProfileId, src.InvestigationId, src.LabRemarks, @UserId, @Now, 1);

        -- Also sync to labentrydetails for convenient direct querying
        UPDATE led
        SET 
            led.LabRemarks = rem.LabRemarks,
            led.ModifiedBy = @UserId,
            led.ModifiedDate = @Now
        FROM dbo.labentrydetails led
        INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = led.SamplecollectionID
        INNER JOIN dbo.LabReportTestRemarks rem ON rem.LabOrderId = sc.Laborderid
        WHERE rem.LabOrderId = @LabOrderId
          AND rem.IsActive = 1
          AND (
              (sc.ProfileId IS NOT NULL AND rem.GroupKey = 'PRF_' + CAST(sc.ProfileId AS VARCHAR(20)))
              OR
              (sc.ProfileId IS NULL AND rem.GroupKey = 'INV_' + CAST(sc.InvestigationID AS VARCHAR(20)))
          );
    END;

    -- Return 1 on success
    SELECT 1 AS Result;
END;
GO

PRINT 'Updated dbo.usp_LabReporting_SaveEntry';
GO

-- 4. Update Stored Procedure: dbo.usp_LabReporting_GetDetail
CREATE OR ALTER PROCEDURE dbo.usp_LabReporting_GetDetail
    @LabOrderId INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Check if any sample was transferred for this order
    DECLARE @IsTransferred BIT = 0;
    DECLARE @SourceBranchId INT = NULL;
    DECLARE @SourceBranchName NVARCHAR(150) = NULL;
    DECLARE @TransferredDate DATETIME = NULL;
    DECLARE @TransferRemarks NVARCHAR(500) = NULL;
    DECLARE @IsReceived BIT = 0;
    DECLARE @ReceivedDate DATETIME = NULL;

    SELECT TOP 1
        @IsTransferred = 1,
        @SourceBranchId = sc.SourceBranchID,
        @SourceBranchName = bm.BranchName,
        @TransferredDate = sc.TransferredDate,
        @TransferRemarks = sc.TransferRemarks,
        @IsReceived = ISNULL(sc.IsReceived, 0),
        @ReceivedDate = sc.ReceivedDate
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.Branchmaster bm ON bm.BranchID = sc.SourceBranchID
    WHERE sc.Laborderid = @LabOrderId 
      AND sc.IsTransferred = 1;

    -- Patient Demographic variables for reference range and delta check matching
    DECLARE @PatientId INT = NULL;
    DECLARE @PatientGender VARCHAR(20) = NULL;
    DECLARE @PatientAge DECIMAL(6,2) = NULL;
    DECLARE @CompanyId INT = 1;

    SELECT 
        @PatientId = lo.PatientId,
        @PatientGender = p.Gender,
        @CompanyId = ISNULL(bm.CompanyId, 1),
        @PatientAge = CASE 
            WHEN p.DateOfBirth IS NOT NULL THEN 
                DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) - 
                CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END
            ELSE NULL 
        END
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.Branchmaster bm ON bm.BranchID = lo.BranchId
    WHERE lo.LabOrderId = @LabOrderId;

    -- Compute Overall Order Status based on entered test results
    DECLARE @OverallStatusId INT = 0;
    DECLARE @OverallStatusCode VARCHAR(30) = 'PENDING';
    DECLARE @OverallStatusName NVARCHAR(100) = 'Pending Entry';
    DECLARE @OverallBadgeClass NVARCHAR(200) = 'bg-secondary-subtle text-secondary border border-secondary-subtle';
    DECLARE @DraftedDate DATETIME = NULL;
    DECLARE @SubmittedDate DATETIME = NULL;
    DECLARE @ValidatedDate DATETIME = NULL;
    DECLARE @ApprovedDate DATETIME = NULL;

    DECLARE @TotalItems INT = 0;
    DECLARE @FilledItems INT = 0;
    DECLARE @MinStatusId INT = 0;
    DECLARE @MaxStatusId INT = 0;

    SELECT 
        @TotalItems = COUNT(*),
        @FilledItems = COUNT(CASE WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN 1 ELSE NULL END),
        @MinStatusId = ISNULL(MIN(CASE WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN ISNULL(led.ReportStatusId, 0) ELSE 0 END), 0),
        @MaxStatusId = ISNULL(MAX(CASE WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN ISNULL(led.ReportStatusId, 0) ELSE 0 END), 0),
        @DraftedDate = MAX(CASE WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Drafted_Date ELSE NULL END),
        @SubmittedDate = MAX(CASE WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Submitted_Date ELSE NULL END),
        @ValidatedDate = MAX(CASE WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Validated_date ELSE NULL END),
        @ApprovedDate = MAX(CASE WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Approved_Date ELSE NULL END)
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    WHERE sc.Laborderid = @LabOrderId
      AND sc.CollectionstatusID = 2
      AND ISNULL(sc.IsoutSource, 0) = 0;

    -- Compute Overall Order Status based on entered test results
    -- Supports partial reporting: overall status reflects the status of entered tests
    IF @FilledItems > 0
    BEGIN
        SET @OverallStatusId = @MaxStatusId;
    END
    ELSE
    BEGIN
        SET @OverallStatusId = 0; -- Pending Entry
    END

    IF @OverallStatusId > 0
    BEGIN
        SELECT 
            @OverallStatusCode = StatusCode,
            @OverallStatusName = StatusName,
            @OverallBadgeClass = BadgeClass
        FROM dbo.Reportentrystatus
        WHERE ReportStatusId = @OverallStatusId;
    END

    -- RS 1: Order and Patient Header Details
    SELECT 
        lo.LabOrderId,
        lo.BranchId,
        ISNULL(bm.BranchName, 'Main Branch') AS BranchName,
        lo.PatientId,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        @PatientAge AS Age,
        p.Gender,
        p.PhoneNumber,
        p.EmailId,
        p.Address,
        lo.OrderDate,
        lo.BookingDate AS BookingDateTime,
        lo.BillNo,
        lo.TokenNo,
        lo.IsUrgent,
        ISNULL(lo.CollectionType, 'Lab') AS CollectionType,
        lo.PhlebotomistId,
        phleb.FullName AS PhlebotomistName,
        ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
        ISNULL(ph.TotalPaid, 0.00) AS TotalPaid,
        ISNULL(ph.BalanceDue, lo.TotalAmount) AS BalanceDue,
        lo.TotalAmount,
        -- Transfer information
        ISNULL(@IsTransferred, 0) AS IsTransferred,
        @SourceBranchId AS SourceBranchId,
        @SourceBranchName AS SourceBranchName,
        @TransferredDate AS TransferredDate,
        @TransferRemarks AS TransferRemarks,
        ISNULL(@IsReceived, 0) AS IsReceived,
        @ReceivedDate AS ReceivedDate,
        -- Overall Report Status Information
        @OverallStatusId AS ReportStatusId,
        @OverallStatusCode AS StatusCode,
        @OverallStatusName AS ReportStatusName,
        @OverallBadgeClass AS ReportBadgeClass,
        @DraftedDate AS DraftedDate,
        @SubmittedDate AS SubmittedDate,
        @ValidatedDate AS ValidatedDate,
        @ApprovedDate AS ApprovedDate
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.Branchmaster bm ON bm.BranchID = lo.BranchId
    LEFT JOIN dbo.Users phleb ON phleb.Id = lo.PhlebotomistId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    WHERE lo.LabOrderId = @LabOrderId;

    -- RS 2: Eligible Collected In-House Investigation Items for this Order
    SELECT 
        sc.samplecollectionID,
        sc.Laborderid,
        sc.InvestigationID,
        lim.Test_Code AS TestCode,
        lim.Test_Name AS TestName,
        sc.DepartmentID,
        ISNULL(ldm.DeptName, '') AS DepartmentName,
        -- Test Method Name
        COALESCE(NULLIF(m_ref.Method_Name, ''), NULLIF(m_inv.Method_Name, ''), '') AS MethodName,
        lim.Sample_Type_ID AS SampleTypeId,
        ISNULL(stm.Sample_Name, 'Standard Sample') AS SampleTypeName,
        ISNULL(NULLIF(stm.Container_Type, ''), 'Standard Tube') AS ContainerType,
        -- Unit Name / Symbol from LabReferenceRangeMaster.Unit_ID (with lim.Unit_ID fallback)
        COALESCE(NULLIF(ref.UnitSymbol, ''), NULLIF(u_inv.Unit_Symbol, ''), u_inv.Unit_Name, '') AS UnitName,
        COALESCE(led.Reporting_Type, lim.Reporting_Type, 'Numeric') AS ReportingType,
        sc.BarcodeNo,
        sc.Samplecollectiondate,
        sc.Samplecollectiontime,
        sc.ProfileId,
        sc.ProfileName,
        sc.PackageId,
        sc.PackageName,
        COALESCE(sc.ProfileName, sc.PackageName, sc.ProfilePackageName, '—') AS ProfilePackageName,
        led.LabEntryDetailId,
        led.TestValue,
        -- Pre-populate Remarks from LabReferenceRangeMaster.Special_Remarks if empty
        COALESCE(NULLIF(led.Remarks, ''), ref.Special_Remarks, '') AS Remarks,
        ref.Special_Remarks AS SpecialRemarks,

        -- Header/Group-level Lab Remarks
        COALESCE(rem_prof.LabRemarks, rem_inv.LabRemarks, led.LabRemarks, '') AS GroupLabRemarks,

        -- Reference Range Values
        ref.RefRange_ID AS RefRangeId,
        ref.Low_Value AS LowValue,
        ref.High_Value AS HighValue,
        CASE 
            WHEN ref.Low_Value IS NOT NULL AND ref.High_Value IS NOT NULL AND ref.Low_Value > 0 THEN
                CONCAT(
                    CAST(CAST(ref.Low_Value AS FLOAT) AS VARCHAR(30)), 
                    ' — ', 
                    CAST(CAST(ref.High_Value AS FLOAT) AS VARCHAR(30))
                )
            WHEN ref.Low_Value = 0 AND ref.High_Value IS NOT NULL THEN
                CONCAT('< ', CAST(CAST(ref.High_Value AS FLOAT) AS VARCHAR(30)))
            WHEN ref.Low_Value IS NULL AND ref.High_Value IS NOT NULL THEN
                CONCAT('< ', CAST(CAST(ref.High_Value AS FLOAT) AS VARCHAR(30)))
            WHEN ref.Low_Value IS NOT NULL AND ref.High_Value IS NULL THEN
                CONCAT('> ', CAST(CAST(ref.Low_Value AS FLOAT) AS VARCHAR(30)))
            ELSE '—'
        END AS ReferenceRange,
        -- Flag: Saved AbnormalFlag, or dynamically evaluated
        COALESCE(led.AbnormalFlag, 
            CASE 
                WHEN ISNUMERIC(led.TestValue) = 1 AND ref.Low_Value IS NOT NULL AND CAST(led.TestValue AS DECIMAL(18,4)) < ref.Low_Value THEN 'L'
                WHEN ISNUMERIC(led.TestValue) = 1 AND ref.High_Value IS NOT NULL AND CAST(led.TestValue AS DECIMAL(18,4)) > ref.High_Value THEN 'H'
                WHEN ISNUMERIC(led.TestValue) = 1 AND (ref.Low_Value IS NOT NULL OR ref.High_Value IS NOT NULL) THEN 'Normal'
                ELSE NULL
            END
        ) AS AbnormalFlag,
        -- TAT
        ISNULL(lim.TAT_Hours, 24) AS TATHours,
        -- Prior Result for Delta Check
        prev.PreviousTestValue,
        prev.PreviousOrderDate,
        prev.PreviousUnitSymbol,
        -- Status Details: Strictly guard empty TestValue
        CASE 
            WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' THEN 0
            ELSE ISNULL(led.ReportStatusId, 0)
        END AS ReportStatusId,
        CASE 
            WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' THEN 'Pending Entry'
            ELSE ISNULL(res.StatusName, 'Pending Entry')
        END AS ReportStatusName,
        CASE 
            WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' THEN 'bg-secondary-subtle text-secondary border border-secondary-subtle'
            ELSE ISNULL(res.BadgeClass, 'bg-secondary-subtle text-secondary border border-secondary-subtle')
        END AS ReportBadgeClass,
        CASE WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Drafted_Date ELSE NULL END AS DraftedDate,
        CASE WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Submitted_Date ELSE NULL END AS SubmittedDate,
        CASE WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Validated_date ELSE NULL END AS ValidatedDate,
        CASE WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Approved_Date ELSE NULL END AS ApprovedDate,
        led.ModifiedDate AS LastSavedDate,
        -- Sample transfer fields
        ISNULL(sc.IsTransferred, 0) AS IsTransferred,
        sc.SourceBranchID           AS SourceBranchId,
        srcB.BranchName             AS SourceBranchName,
        sc.TargetBranchID           AS TargetBranchId,
        tgtB.BranchName             AS TargetBranchName,
        sc.TransferredDate,
        sc.TransferRemarks,
        ISNULL(sc.IsReceived, 0)    AS IsReceived,
        sc.ReceivedDate,
        sc.ReceiveRemarks
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT JOIN dbo.DepartmentMaster ldm ON ldm.DeptId = sc.DepartmentID
    LEFT JOIN dbo.LabTestMethodMaster m_inv ON m_inv.Method_ID = lim.Method_ID
    LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
    LEFT JOIN dbo.LabUnitMaster u_inv ON u_inv.Unit_ID = lim.Unit_ID
    LEFT JOIN dbo.Branchmaster srcB ON srcB.BranchID = sc.SourceBranchID
    LEFT JOIN dbo.Branchmaster tgtB ON tgtB.BranchID = sc.TargetBranchID
    LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    LEFT JOIN dbo.Reportentrystatus res ON res.ReportStatusId = led.ReportStatusId

    -- Join Group-level remarks if saved
    LEFT JOIN dbo.LabReportTestRemarks rem_prof ON rem_prof.LabOrderId = sc.Laborderid 
                                               AND rem_prof.GroupKey = 'PRF_' + CAST(sc.ProfileId AS VARCHAR(20))
                                               AND sc.ProfileId IS NOT NULL
                                               AND rem_prof.IsActive = 1
    LEFT JOIN dbo.LabReportTestRemarks rem_inv ON rem_inv.LabOrderId = sc.Laborderid 
                                              AND rem_inv.GroupKey = 'INV_' + CAST(sc.InvestigationID AS VARCHAR(20))
                                              AND rem_inv.IsActive = 1

    -- Match best Reference Range for patient's Gender & Age
    OUTER APPLY (
        SELECT TOP 1 
            r.RefRange_ID,
            r.Method_ID AS RefMethodId,
            r.Unit_ID,
            r.Low_Value,
            r.High_Value,
            r.Special_Remarks,
            r.Age_From,
            r.Age_To,
            r.Gender AS RangeGender,
            u.Unit_Name,
            COALESCE(NULLIF(u.Unit_Symbol, ''), u.Unit_Name, '') AS UnitSymbol
        FROM dbo.LabReferenceRangeMaster r
        LEFT JOIN dbo.LabUnitMaster u ON u.Unit_ID = r.Unit_ID
        WHERE r.Test_ID = sc.InvestigationID
          AND r.IsDeleted = 0
          AND r.Status = 1
          AND (r.CompanyId = @CompanyId OR r.CompanyId = 1)
          AND r.Effective_From <= CAST(GETDATE() AS DATE)
          AND (r.Effective_To IS NULL OR r.Effective_To >= CAST(GETDATE() AS DATE))
          AND (
              (@PatientAge IS NULL)
              OR (r.Age_Unit = 'Years' AND @PatientAge >= r.Age_From AND @PatientAge <= r.Age_To)
              OR (r.Age_Unit = 'Months' AND (@PatientAge * 12.0) >= r.Age_From AND (@PatientAge * 12.0) <= r.Age_To)
              OR (r.Age_Unit = 'Days' AND (@PatientAge * 365.25) >= r.Age_From AND (@PatientAge * 365.25) <= r.Age_To)
              OR r.Is_Common_For_All = 1
          )
          AND (
              r.Is_Common_For_All = 1
              OR r.Gender = 'All'
              OR LOWER(r.Gender) = LOWER(ISNULL(@PatientGender, ''))
          )
        ORDER BY 
          CASE WHEN LOWER(r.Gender) = LOWER(ISNULL(@PatientGender, '')) THEN 1 ELSE 2 END ASC,
          CASE WHEN r.Is_Common_For_All = 0 THEN 1 ELSE 2 END ASC,
          r.RefRange_ID DESC
    ) ref
    LEFT JOIN dbo.LabTestMethodMaster m_ref ON m_ref.Method_ID = ref.RefMethodId

    -- Previous Historical Result for Delta Check
    OUTER APPLY (
        SELECT TOP 1 
            prev_led.TestValue AS PreviousTestValue,
            prev_lo.OrderDate AS PreviousOrderDate,
            COALESCE(NULLIF(prev_u.Unit_Symbol, ''), prev_u.Unit_Name, '') AS PreviousUnitSymbol
        FROM dbo.labentrydetails prev_led
        INNER JOIN dbo.LabOrder prev_lo ON prev_lo.LabOrderId = prev_led.LabOrderId
        LEFT JOIN dbo.LabInvestigationMaster prev_lim ON prev_lim.Test_ID = prev_led.InvestigationID
        LEFT JOIN dbo.LabUnitMaster prev_u ON prev_u.Unit_ID = prev_lim.Unit_ID
        WHERE prev_led.PatientId = @PatientId
          AND prev_led.InvestigationID = sc.InvestigationID
          AND prev_led.LabOrderId != @LabOrderId
          AND prev_led.IsActive = 1
          AND prev_led.TestValue IS NOT NULL
          AND LTRIM(RTRIM(prev_led.TestValue)) <> ''
        ORDER BY prev_lo.OrderDate DESC, prev_led.LabEntryDetailId DESC
    ) prev

    WHERE sc.Laborderid = @LabOrderId
      AND sc.CollectionstatusID = 2
      AND ISNULL(sc.IsoutSource, 0) = 0
    ORDER BY sc.samplecollectionID ASC;

    -- RS 3: Header-Level Lab Remarks
    SELECT 
        GroupKey,
        HeaderName,
        ProfileId,
        InvestigationId,
        LabRemarks
    FROM dbo.LabReportTestRemarks
    WHERE LabOrderId = @LabOrderId AND IsActive = 1;
END;
GO

PRINT 'Updated dbo.usp_LabReporting_GetDetail';
GO
