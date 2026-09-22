-- ============================================================================
-- Migration: 2116_lab_reporting_critical_panic_thresholds.sql
-- Description:
--   Lab Reference Range "Tier / Severity" = 'Critical Value' or 'Panic Value' now drives result flagging:
--   a numeric result below Low_Threshold or above High_Threshold is flagged 'Critical' / 'Panic', checked
--   before the normal Low_Value / High_Value (L / H) comparison - the same rule the Report Entry screen
--   applies live while typing. 'Reportable Range' and ranges with no tier are unchanged.
--
--   usp_LabReporting_GetDetail (live definition + 3 additive edits):
--     * the matched reference range also returns Tier, Low_Threshold, High_Threshold
--     * RS2 gains RangeTier / LowThreshold / HighThreshold (NULL unless tier is Critical / Panic)
--     * the fallback flag (used only when no flag was saved) checks the thresholds first
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LabReporting_GetDetail
    @LabOrderId INT,
    @BranchId   INT = NULL      -- NULL = every sample of the order (print / dispatch); otherwise only this branch's samples
AS
BEGIN
    SET NOCOUNT ON;

    -- Which samples belong to @BranchId (same rule as dbo.usp_LabReporting_GetHeaderList):
    --   * a sample that was never transferred belongs to the branch that booked it (sc.BranchID)
    --   * a transferred sample belongs to the TARGET branch, and only once it has been received
    --   * once the TARGET branch approves it, it also comes back to the SOURCE branch - read-only there
    --     (IsReadOnlyForBranch = 1), so the booking branch can see the result and print the report
    -- so a partially transferred order shows only its own tests on each branch's Report Entry screen.

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
      AND sc.IsTransferred = 1
      AND (@BranchId IS NULL
           OR (sc.TargetBranchID = @BranchId AND ISNULL(sc.IsReceived, 0) = 1));

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
        @FilledItems = COUNT(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN 1 ELSE NULL END),
        @MinStatusId = ISNULL(MIN(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN ISNULL(led.ReportStatusId, 0) ELSE 0 END), 0),
        @MaxStatusId = ISNULL(MAX(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN ISNULL(led.ReportStatusId, 0) ELSE 0 END), 0),
        @DraftedDate = MAX(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Drafted_Date ELSE NULL END),
        @SubmittedDate = MAX(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Submitted_Date ELSE NULL END),
        @ValidatedDate = MAX(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Validated_date ELSE NULL END),
        @ApprovedDate = MAX(CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Approved_Date ELSE NULL END)
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    WHERE sc.Laborderid = @LabOrderId
      AND sc.CollectionstatusID IN (2, 3, 4)
      AND ISNULL(sc.IsoutSource, 0) = 0
      AND (@BranchId IS NULL
           OR (ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @BranchId)
           OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @BranchId AND ISNULL(sc.IsReceived, 0) = 1)
           -- a sample this branch transferred OUT comes back once the target branch has APPROVED it,
           -- so the booking branch can see the finished result and print the report (read-only here)
           OR (sc.IsTransferred = 1 AND sc.SourceBranchID = @BranchId
               AND EXISTS (SELECT 1 FROM dbo.labentrydetails l_ap
                           WHERE l_ap.SamplecollectionID = sc.samplecollectionID
                             AND l_ap.IsActive = 1 AND l_ap.ReportStatusId = 5)));

    -- Compute Overall Order Status based on entered test results
    -- Supports partial reporting: overall status reflects the status of entered collected tests
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

    -- RS 2: Eligible Investigation Items for this Order (Collected, Re-Collect, Rejected)
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
        -- Sample Status metadata
        ISNULL(sc.CollectionstatusID, 2) AS CollectionstatusID,
        ISNULL(scs.StatusName, 'Collected') AS SampleCollectionStatus,
        ISNULL(scs.StatusCode, 'COLLECTED') AS SampleCollectionStatusCode,
        sc.RejectionReasonId,
        sc.RejectionReason,
        led.LabEntryDetailId,
        CASE WHEN sc.CollectionstatusID IN (3, 4) THEN NULL ELSE led.TestValue END AS TestValue,
        -- Pre-populate Remarks from LabReferenceRangeMaster.Special_Remarks if empty
        COALESCE(NULLIF(led.Remarks, ''), ref.Special_Remarks, '') AS Remarks,
        ref.Special_Remarks AS SpecialRemarks,

        -- Header/Group-level Lab Remarks
        COALESCE(rem_prof.LabRemarks, rem_inv.LabRemarks, led.LabRemarks, '') AS GroupLabRemarks,

        -- Reference Range Values
        ref.RefRange_ID AS RefRangeId,
        ref.Low_Value AS LowValue,
        ref.High_Value AS HighValue,
        -- Critical / Panic tier: a result beyond Low_Threshold / High_Threshold is flagged 'Critical' / 'Panic'
        CASE WHEN ref.Tier IN ('Critical Value', 'Panic Value') THEN ref.Tier END AS RangeTier,
        CASE WHEN ref.Tier IN ('Critical Value', 'Panic Value') THEN ref.Low_Threshold END AS LowThreshold,
        CASE WHEN ref.Tier IN ('Critical Value', 'Panic Value') THEN ref.High_Threshold END AS HighThreshold,
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
        CASE 
            WHEN sc.CollectionstatusID IN (3, 4) THEN NULL
            ELSE COALESCE(led.AbnormalFlag, 
                CASE 
                    WHEN ISNUMERIC(led.TestValue) = 1 AND ref.Tier IN ('Critical Value', 'Panic Value')
                         AND ((ref.Low_Threshold IS NOT NULL AND CAST(led.TestValue AS DECIMAL(18,4)) < ref.Low_Threshold)
                           OR (ref.High_Threshold IS NOT NULL AND CAST(led.TestValue AS DECIMAL(18,4)) > ref.High_Threshold))
                         THEN CASE ref.Tier WHEN 'Panic Value' THEN 'Panic' ELSE 'Critical' END
                    WHEN ISNUMERIC(led.TestValue) = 1 AND ref.Low_Value IS NOT NULL AND CAST(led.TestValue AS DECIMAL(18,4)) < ref.Low_Value THEN 'L'
                    WHEN ISNUMERIC(led.TestValue) = 1 AND ref.High_Value IS NOT NULL AND CAST(led.TestValue AS DECIMAL(18,4)) > ref.High_Value THEN 'H'
                    WHEN ISNUMERIC(led.TestValue) = 1 AND (ref.Low_Value IS NOT NULL OR ref.High_Value IS NOT NULL) THEN 'Normal'
                    ELSE NULL
                END
            )
        END AS AbnormalFlag,
        -- TAT
        ISNULL(lim.TAT_Hours, 24) AS TATHours,
        -- Prior Result for Delta Check
        prev.PreviousTestValue,
        prev.PreviousOrderDate,
        prev.PreviousUnitSymbol,
        -- Status Details: Strictly guard empty TestValue or Rejected/Re-collected items
        CASE 
            WHEN sc.CollectionstatusID IN (3, 4) THEN 0
            WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' THEN 0
            ELSE ISNULL(led.ReportStatusId, 0)
        END AS ReportStatusId,
        CASE 
            WHEN sc.CollectionstatusID IN (3, 4) THEN 'Pending Entry'
            WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' THEN 'Pending Entry'
            ELSE ISNULL(res.StatusName, 'Pending Entry')
        END AS ReportStatusName,
        CASE 
            WHEN sc.CollectionstatusID IN (3, 4) THEN 'bg-secondary-subtle text-secondary border border-secondary-subtle'
            WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) = '' THEN 'bg-secondary-subtle text-secondary border border-secondary-subtle'
            ELSE ISNULL(res.BadgeClass, 'bg-secondary-subtle text-secondary border border-secondary-subtle')
        END AS ReportBadgeClass,
        CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Drafted_Date ELSE NULL END AS DraftedDate,
        CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Submitted_Date ELSE NULL END AS SubmittedDate,
        CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Validated_date ELSE NULL END AS ValidatedDate,
        CASE WHEN sc.CollectionstatusID = 2 AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' THEN led.Approved_Date ELSE NULL END AS ApprovedDate,
        led.ModifiedDate AS LastSavedDate,
        -- Sample transfer fields
        ISNULL(sc.IsTransferred, 0) AS IsTransferred,
        sc.SourceBranchID           AS SourceBranchId,
        srcB.BranchName             AS SourceBranchName,
        sc.TargetBranchID           AS TargetBranchId,
        -- 1 = this branch only transferred the sample out; the result was produced and approved elsewhere,
        --     so the Report Entry screen shows it but must not let this branch change anything on it.
        CAST(CASE WHEN @BranchId IS NOT NULL
                   AND sc.IsTransferred = 1
                   AND sc.SourceBranchID = @BranchId
                   AND ISNULL(sc.TargetBranchID, 0) <> @BranchId
                  THEN 1 ELSE 0 END AS BIT) AS IsReadOnlyForBranch,
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
    LEFT JOIN dbo.SampleCollectionStatus scs ON scs.StatusID = sc.CollectionstatusID

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
            r.Tier,
            r.Low_Threshold,
            r.High_Threshold,
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
      AND sc.CollectionstatusID IN (2, 3, 4)
      AND ISNULL(sc.IsoutSource, 0) = 0
      AND (@BranchId IS NULL
           OR (ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @BranchId)
           OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @BranchId AND ISNULL(sc.IsReceived, 0) = 1)
           -- a sample this branch transferred OUT comes back once the target branch has APPROVED it,
           -- so the booking branch can see the finished result and print the report (read-only here)
           OR (sc.IsTransferred = 1 AND sc.SourceBranchID = @BranchId
               AND EXISTS (SELECT 1 FROM dbo.labentrydetails l_ap
                           WHERE l_ap.SamplecollectionID = sc.samplecollectionID
                             AND l_ap.IsActive = 1 AND l_ap.ReportStatusId = 5)))
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

PRINT 'Updated dbo.usp_LabReporting_GetDetail (Critical / Panic threshold flagging).';
GO
