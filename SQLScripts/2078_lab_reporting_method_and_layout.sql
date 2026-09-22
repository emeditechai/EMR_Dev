-- Migration: Add Test Method to LabReporting GetDetail and configure Lipid Profile methods
USE Dev_EMR;
GO

-- 1. Ensure Calculation Method exists in LabTestMethodMaster
IF NOT EXISTS (SELECT 1 FROM dbo.LabTestMethodMaster WHERE Method_Code = 'MTH0012' OR Method_Name LIKE '%Calculate%')
BEGIN
    INSERT INTO dbo.LabTestMethodMaster (CompanyId, Department_ID, Method_Name, Method_Code, Display_Order, Status, CreatedDate, IsDeleted)
    VALUES (1, 13, 'Calculated Ratio / Formula', 'MTH0012', 12, 1, SYSUTCDATETIME(), 0);
END
GO

-- 2. Update Method_ID for Lipid Profile tests
DECLARE @CalcMethodId INT = (SELECT TOP 1 Method_ID FROM dbo.LabTestMethodMaster WHERE Method_Code = 'MTH0012' OR Method_Name LIKE '%Calculate%');

-- Tests 40-44: Photometric / Spectrophotometry (Method_ID = 2)
UPDATE dbo.LabInvestigationMaster 
SET Method_ID = 2 
WHERE Test_Code IN ('TST0040', 'TST0041', 'TST0042', 'TST0043', 'TST0044');

UPDATE dbo.LabReferenceRangeMaster 
SET Method_ID = 2 
WHERE Test_ID IN (SELECT Test_ID FROM dbo.LabInvestigationMaster WHERE Test_Code IN ('TST0040', 'TST0041', 'TST0042', 'TST0043', 'TST0044'));

-- Tests 45-46: Calculated Ratio / Formula
UPDATE dbo.LabInvestigationMaster 
SET Method_ID = @CalcMethodId 
WHERE Test_Code IN ('TST0045', 'TST0046');

UPDATE dbo.LabReferenceRangeMaster 
SET Method_ID = @CalcMethodId 
WHERE Test_ID IN (SELECT Test_ID FROM dbo.LabInvestigationMaster WHERE Test_Code IN ('TST0045', 'TST0046'));
GO

-- 3. Update dbo.usp_LabReporting_GetDetail to return MethodName
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
        @ReceivedDate AS ReceivedDate
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
        -- Status Details
        ISNULL(led.ReportStatusId, 0) AS ReportStatusId,
        ISNULL(res.StatusName, 'Pending Entry') AS ReportStatusName,
        ISNULL(res.BadgeClass, 'bg-secondary-subtle text-secondary border border-secondary-subtle') AS ReportBadgeClass,
        led.Drafted_Date AS DraftedDate,
        led.Submitted_Date AS SubmittedDate,
        led.Validated_date AS ValidatedDate,
        led.Approved_Date AS ApprovedDate,
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
END;
GO
