USE [Dev_EMR];
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Update usp_SampleTransfer_GetWorksheetData
--    - Displays the actual booked/billed Test Name instead of segregated tests.
--    - Groups multiple segregated parameters of the same billed test / barcode
--      so that only 1 row per sample tube / billed test is displayed on the sheet.
--    - Returns TransferredByName and ReceivedByName.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_SampleTransfer_GetWorksheetData
(
    @SampleCollectionIds NVARCHAR(MAX)
)
AS
BEGIN
    SET NOCOUNT ON;

    -- Parse the comma-separated IDs into a temporary table
    CREATE TABLE #SelectedIds (Id BIGINT PRIMARY KEY);
    
    INSERT INTO #SelectedIds (Id)
    SELECT DISTINCT CAST(LTRIM(RTRIM(value)) AS BIGINT)
    FROM STRING_SPLIT(@SampleCollectionIds, ',')
    WHERE LTRIM(RTRIM(value)) <> '';

    ;WITH RawData AS (
        SELECT 
            sc.samplecollectionID AS SampleCollectionId,
            sc.Laborderid AS LabOrderId,
            lo.BranchId AS CurrentBranchId,
            sc.PatientID AS PatientId,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
            CASE 
                WHEN p.DateOfBirth IS NOT NULL THEN 
                    DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) - 
                    CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END
                ELSE NULL 
            END AS Age,
            p.Gender,
            p.PhoneNumber,
            lo.BillNo,
            lo.TokenNo,
            lo.OrderDate,
            ISNULL(lo.BookingDate, sc.Bookingdatetime) AS BookingDateTime,
            sc.Samplecollectiondate AS CollectionDate,
            sc.Samplecollectiontime AS CollectionTime,
            sc.BarcodeNo,
            sc.InvestigationID AS InvestigationId,
            COALESCE(NULLIF(limBilled.Test_Code, ''), limSeg.Test_Code) AS TestCode,
            -- Actual taken Test Name as per Billing (e.g. Complete Blood Count (CBC) with ESR or Profile/Package name):
            COALESCE(
                NULLIF(pkg.Profile_Name, ''),
                NULLIF(sc.PackageName, ''),
                NULLIF(limBilled.Test_Name, ''), 
                NULLIF(ph.Profile_Name, ''), 
                NULLIF(sc.ProfileName, ''), 
                NULLIF(sc.ProfilePackageName, '—'), 
                limSeg.Test_Name
            ) AS TestName,
            ISNULL(ldm.DeptName, 'General') AS DepartmentName,
            ISNULL(stm.Sample_Name, 'Standard Sample') AS SampleTypeName,
            ISNULL(NULLIF(stm.Container_Type, ''), 'Standard Tube') AS ContainerTypeName,
            COALESCE(NULLIF(sc.ProfileName, ''), NULLIF(sc.PackageName, ''), NULLIF(sc.ProfilePackageName, '—'), '—') AS ProfilePackageName,
            
            -- Transfer details
            ISNULL(sc.IsTransferred, 0) AS IsTransferred,
            sc.TransferredDate,
            sc.TransferredBy,
            ISNULL(u1.FullName, u1.UserName) AS TransferredByName,
            sc.TransferRemarks,
            ISNULL(sc.SourceBranchID, sc.BranchID) AS SourceBranchId,
            ISNULL(srcB.BranchName, 'Main Branch') AS SourceBranchName,
            sc.TargetBranchID AS TargetBranchId,
            tgtB.BranchName AS TargetBranchName,
            
            -- Receive details
            ISNULL(sc.IsReceived, 0) AS IsReceived,
            sc.ReceivedDate,
            sc.ReceivedBy,
            ISNULL(u2.FullName, u2.UserName) AS ReceivedByName,
            sc.ReceiveRemarks,
            -- Deduplication: One entry per Barcode and Billed Test Name
            ROW_NUMBER() OVER (
                PARTITION BY sc.Laborderid, 
                             ISNULL(NULLIF(sc.BarcodeNo, ''), CAST(sc.samplecollectionID AS NVARCHAR(50))), 
                             COALESCE(
                                 NULLIF(pkg.Profile_Name, ''),
                                 NULLIF(sc.PackageName, ''),
                                 NULLIF(limBilled.Test_Name, ''), 
                                 NULLIF(ph.Profile_Name, ''), 
                                 NULLIF(sc.ProfileName, ''), 
                                 NULLIF(sc.ProfilePackageName, '—'), 
                                 limSeg.Test_Name
                             )
                ORDER BY sc.samplecollectionID ASC
            ) AS RowNum
        FROM 
            dbo.SampleCollection sc
        INNER JOIN #SelectedIds ids ON sc.samplecollectionID = ids.Id
        INNER JOIN dbo.LabOrder lo ON sc.Laborderid = lo.LabOrderId
        INNER JOIN dbo.PatientMaster p ON p.PatientId = sc.PatientID
        LEFT JOIN dbo.LabInvestigationMaster limSeg ON sc.InvestigationID = limSeg.Test_ID
        LEFT JOIN dbo.LabInvestigationProfileHeader ph ON sc.ProfileId = ph.Profile_ID
        LEFT JOIN dbo.LabInvestigationMaster limBilled ON ph.Test_ID = limBilled.Test_ID
        LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON sc.PackageId = pkg.Profile_ID
        LEFT JOIN dbo.DepartmentMaster ldm ON COALESCE(limBilled.Department_ID, limSeg.Department_ID) = ldm.DeptId
        LEFT JOIN dbo.LabSampleTypeMaster stm ON COALESCE(limBilled.Sample_Type_ID, limSeg.Sample_Type_ID) = stm.Sample_Type_ID
        LEFT JOIN dbo.Branchmaster srcB ON srcB.BranchID = ISNULL(sc.SourceBranchID, sc.BranchID)
        LEFT JOIN dbo.Branchmaster tgtB ON tgtB.BranchID = sc.TargetBranchID
        LEFT JOIN dbo.Users u1 ON sc.TransferredBy = u1.Id
        LEFT JOIN dbo.Users u2 ON sc.ReceivedBy = u2.Id
    )
    SELECT 
        SampleCollectionId,
        LabOrderId,
        CurrentBranchId,
        PatientId,
        PatientCode,
        PatientName,
        Age,
        Gender,
        PhoneNumber,
        BillNo,
        TokenNo,
        OrderDate,
        BookingDateTime,
        CollectionDate,
        CollectionTime,
        BarcodeNo,
        InvestigationId,
        TestCode,
        TestName,
        DepartmentName,
        SampleTypeName,
        ContainerTypeName,
        ProfilePackageName,
        IsTransferred,
        TransferredDate,
        TransferredBy,
        TransferredByName,
        TransferRemarks,
        SourceBranchId,
        SourceBranchName,
        TargetBranchId,
        TargetBranchName,
        IsReceived,
        ReceivedDate,
        ReceivedBy,
        ReceivedByName,
        ReceiveRemarks
    FROM RawData
    WHERE RowNum = 1
    ORDER BY SampleCollectionId ASC;

    DROP TABLE #SelectedIds;
END
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Backfill TransferredBy for existing records where created by user 2 (abhik)
-- ─────────────────────────────────────────────────────────────────────────────
UPDATE sc
SET sc.TransferredBy = lo.CreatedBy
FROM dbo.SampleCollection sc
INNER JOIN dbo.LabOrder lo ON sc.Laborderid = lo.LabOrderId
WHERE sc.IsTransferred = 1 
  AND sc.TransferredBy = 1 
  AND lo.CreatedBy IS NOT NULL 
  AND lo.CreatedBy <> 1;
GO
