USE [Dev_EMR];
GO

IF OBJECT_ID('dbo.usp_SampleTransfer_GetWorksheetData', 'P') IS NOT NULL
BEGIN
    DROP PROCEDURE dbo.usp_SampleTransfer_GetWorksheetData;
END
GO

CREATE PROCEDURE dbo.usp_SampleTransfer_GetWorksheetData
(
    @SampleCollectionIds NVARCHAR(MAX)
)
AS
BEGIN
    SET NOCOUNT ON;

    -- Parse the comma-separated IDs into a temporary table
    CREATE TABLE #SelectedIds (Id BIGINT PRIMARY KEY);
    
    INSERT INTO #SelectedIds (Id)
    SELECT CAST(value AS BIGINT)
    FROM STRING_SPLIT(@SampleCollectionIds, ',')
    WHERE LTRIM(RTRIM(value)) <> '';

    SELECT 
        sc.SampleCollectionId,
        sc.LabOrderId,
        lo.BranchId AS CurrentBranchId,
        sc.PatientId,
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
        sc.InvestigationId,
        lim.Test_Code AS TestCode,
        lim.Test_Name AS TestName,
        ldm.DeptName AS DepartmentName,
        ISNULL(stm.Sample_Name, 'Standard Sample') AS SampleTypeName,
        ISNULL(NULLIF(stm.Container_Type, ''), 'Standard Tube') AS ContainerTypeName,
        COALESCE(sc.ProfileName, sc.PackageName, sc.ProfilePackageName, '—') AS ProfilePackageName,
        
        -- Transfer details
        ISNULL(sc.IsTransferred, 0) AS IsTransferred,
        sc.TransferredDate,
        sc.TransferredBy,
        u1.FullName AS TransferredByName,
        sc.TransferRemarks,
        ISNULL(sc.SourceBranchID, sc.BranchID) AS SourceBranchId,
        ISNULL(srcB.BranchName, 'Main Branch') AS SourceBranchName,
        sc.TargetBranchID AS TargetBranchId,
        tgtB.BranchName AS TargetBranchName,
        
        -- Receive details
        ISNULL(sc.IsReceived, 0) AS IsReceived,
        sc.ReceivedDate,
        sc.ReceivedBy,
        u2.FullName AS ReceivedByName,
        sc.ReceiveRemarks
    FROM 
        dbo.SampleCollection sc
    INNER JOIN #SelectedIds ids ON sc.SampleCollectionId = ids.Id
    INNER JOIN dbo.LabOrder lo ON sc.LabOrderId = lo.LabOrderId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = sc.PatientId
    LEFT JOIN dbo.LabInvestigationMaster lim ON sc.InvestigationId = lim.Test_ID
    LEFT JOIN dbo.DepartmentMaster ldm ON lim.Department_ID = ldm.DeptId
    LEFT JOIN dbo.LabSampleTypeMaster stm ON lim.Sample_Type_ID = stm.Sample_Type_ID
    LEFT JOIN dbo.Branchmaster srcB ON srcB.BranchID = ISNULL(sc.SourceBranchID, sc.BranchID)
    LEFT JOIN dbo.Branchmaster tgtB ON tgtB.BranchID = sc.TargetBranchID
    LEFT JOIN dbo.Users u1 ON sc.TransferredBy = u1.Id
    LEFT JOIN dbo.Users u2 ON sc.ReceivedBy = u2.Id
    ORDER BY
        sc.SampleCollectionId ASC;

    DROP TABLE #SelectedIds;
END
GO
