SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_Report_DailyCollectionRegister
    @BranchId INT,
    @FromDate DATE,
    @ToDate DATE,
    @IsDetailed BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @IsDetailed = 0
    BEGIN
        -- SUMMARY REPORT
        SELECT 
            ph.PaymentId,
            ph.ReceiptNo,
            s.OPDBillNo,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation + ' ', '') + p.FirstName + ' ' + ISNULL(p.MiddleName + ' ', '') + p.LastName)) AS PatientName,
            ph.PaymentDate,
            ISNULL(ph.TotalAmount, 0) AS TotalAmount,
            ISNULL(ph.DiscountAmount, 0) AS DiscountAmount,
            ISNULL(ph.NetAmount, 0) AS NetAmount,
            ISNULL(ph.GstAmount, 0) AS GstAmount,
            ISNULL(ph.TotalPaid, 0) AS TotalPaid,
            ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
            ISNULL(
                STUFF((SELECT ', ' + pm.PaymentModeName
                       FROM dbo.PaymentLineItem pli
                       INNER JOIN dbo.PaymentModeMaster pm ON pm.PaymentModeId = pli.PaymentModeId
                       WHERE pli.PaymentId = ph.PaymentId AND pli.IsActive = 1
                       FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 2, ''), 'Cash'
            ) AS PaymentModes
        FROM dbo.PaymentHeader ph
        INNER JOIN dbo.PatientOPDService s ON s.OPDServiceId = ph.OPDServiceId
        INNER JOIN dbo.PatientMaster p ON p.PatientId = s.PatientId
        WHERE ph.BranchId = @BranchId
          AND CAST(ph.PaymentDate AS DATE) >= @FromDate
          AND CAST(ph.PaymentDate AS DATE) <= @ToDate
          AND ph.IsActive = 1
          AND ph.ModuleCode = 'OPD'
        ORDER BY ph.PaymentDate DESC, ph.PaymentId DESC;
    END
    ELSE
    BEGIN
        -- DETAILED REPORT (Item Wise)
        SELECT 
            ph.PaymentId,
            ph.ReceiptNo,
            s.OPDBillNo,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation + ' ', '') + p.FirstName + ' ' + ISNULL(p.MiddleName + ' ', '') + p.LastName)) AS PatientName,
            ph.PaymentDate,
            si.ItemName,
            si.ServiceType,
            ISNULL(si.ServiceCharges, 0) AS ServiceCharges,
            ISNULL(si.DiscountAmount, 0) AS ItemDiscount,
            ISNULL(si.GstPercentage, 0) AS GstPercentage,
            ISNULL(si.GstAmount, 0) AS ItemGstAmount,
            ISNULL(si.TotalAmount, 0) AS ItemTotalAmount
        FROM dbo.PaymentHeader ph
        INNER JOIN dbo.PatientOPDService s ON s.OPDServiceId = ph.OPDServiceId
        INNER JOIN dbo.PatientMaster p ON p.PatientId = s.PatientId
        INNER JOIN dbo.PatientOPDServiceItem si ON si.OPDServiceId = s.OPDServiceId
        WHERE ph.BranchId = @BranchId
          AND CAST(ph.PaymentDate AS DATE) >= @FromDate
          AND CAST(ph.PaymentDate AS DATE) <= @ToDate
          AND ph.IsActive = 1
          AND si.IsActive = 1
          AND ph.ModuleCode = 'OPD'
        ORDER BY ph.PaymentDate DESC, ph.PaymentId DESC, si.OPDServiceItemId ASC;
    END
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_Report_PatientRegister
    @BranchId INT,
    @FromDate DATE,
    @ToDate DATE,
    @DependentOnly BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @DependentOnly = 0
    BEGIN
        -- All Patients
        SELECT 
            p.PatientId,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation + ' ', '') + p.FirstName + ' ' + ISNULL(p.MiddleName + ' ', '') + p.LastName)) AS PatientName,
            p.PhoneNumber,
            p.Gender,
            CASE
                WHEN p.DateOfBirth IS NULL THEN NULL
                ELSE DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
                     - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END
            END AS Age,
            p.CreatedDate AS RegistrationDate,
            r.RelationName,
            NULL AS ParentName
        FROM dbo.PatientMaster p
        LEFT JOIN dbo.RelationMaster r ON r.RelationId = p.RelationId
        WHERE p.BranchId = @BranchId
          AND CAST(p.CreatedDate AS DATE) >= @FromDate
          AND CAST(p.CreatedDate AS DATE) <= @ToDate
          AND p.IsActive = 1
        ORDER BY p.CreatedDate DESC;
    END
    ELSE
    BEGIN
        -- Dependent Only
        -- Find all patients in the date range who have a relation that is NOT 'Self' (RelationId <> 1),
        -- and also join them with their Parent (the patient who has RelationId = 1 and the same PhoneNumber).
        SELECT 
            p.PatientId,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation + ' ', '') + p.FirstName + ' ' + ISNULL(p.MiddleName + ' ', '') + p.LastName)) AS PatientName,
            p.PhoneNumber,
            p.Gender,
            CASE
                WHEN p.DateOfBirth IS NULL THEN NULL
                ELSE DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
                     - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END
            END AS Age,
            p.CreatedDate AS RegistrationDate,
            r.RelationName,
            LTRIM(RTRIM(ISNULL(parent.Salutation + ' ', '') + parent.FirstName + ' ' + ISNULL(parent.MiddleName + ' ', '') + parent.LastName)) AS ParentName
        FROM dbo.PatientMaster p
        LEFT JOIN dbo.RelationMaster r ON r.RelationId = p.RelationId
        LEFT JOIN dbo.PatientMaster parent ON parent.PhoneNumber = p.PhoneNumber AND parent.RelationId = 1 AND parent.IsActive = 1
        WHERE p.BranchId = @BranchId
          AND CAST(p.CreatedDate AS DATE) >= @FromDate
          AND CAST(p.CreatedDate AS DATE) <= @ToDate
          AND p.IsActive = 1
          AND ISNULL(p.RelationId, 0) <> 1
          AND ISNULL(p.PhoneNumber, '') <> ''
        ORDER BY p.PhoneNumber, p.CreatedDate DESC;
    END
END
GO
