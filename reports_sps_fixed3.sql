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
            ph.PaymentHeaderId,
            s.OPDBillNo,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation + ' ', '') + p.FirstName + ' ' + ISNULL(p.MiddleName + ' ', '') + p.LastName)) AS PatientName,
            ph.CreatedDate AS PaymentDate,
            ISNULL(ph.SubTotal, 0) AS TotalAmount,
            ISNULL(ph.HeaderDiscountAmount, 0) + ISNULL(ph.LineDiscountTotal, 0) AS DiscountAmount,
            ISNULL(ph.NetAmount, 0) AS NetAmount,
            ISNULL(ph.TotalCgstAmount, 0) + ISNULL(ph.TotalSgstAmount, 0) + ISNULL(ph.TotalIgstAmount, 0) AS GstAmount,
            ISNULL(ph.TotalPaid, 0) AS TotalPaid,
            ISNULL(ph.PaymentStatus, 'U') AS PaymentStatus,
            ISNULL(
                STUFF((SELECT DISTINCT ', ' + pm.MethodName
                       FROM dbo.PaymentDetail pd
                       INNER JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
                       WHERE pd.PaymentHeaderId = ph.PaymentHeaderId AND pd.IsActive = 1
                       FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 2, ''), 'Unpaid'
            ) AS PaymentModes
        FROM dbo.PaymentHeader ph
        INNER JOIN dbo.PatientOPDService s ON s.OPDServiceId = ph.OPDServiceId
        INNER JOIN dbo.PatientMaster p ON p.PatientId = s.PatientId
        WHERE ph.BranchId = @BranchId
          AND CAST(ph.CreatedDate AS DATE) >= @FromDate
          AND CAST(ph.CreatedDate AS DATE) <= @ToDate
          AND ph.IsActive = 1
          AND ph.ModuleCode = 'OPD'
        ORDER BY ph.CreatedDate DESC, ph.PaymentHeaderId DESC;
    END
    ELSE
    BEGIN
        -- DETAILED REPORT (Item Wise)
        SELECT 
            ph.PaymentHeaderId,
            s.OPDBillNo,
            p.PatientCode,
            LTRIM(RTRIM(ISNULL(p.Salutation + ' ', '') + p.FirstName + ' ' + ISNULL(p.MiddleName + ' ', '') + p.LastName)) AS PatientName,
            ph.CreatedDate AS PaymentDate,
            pli.ItemDescription AS ItemName,
            pli.ServiceType,
            ISNULL(pli.OriginalAmount, 0) AS ServiceCharges,
            ISNULL(pli.LineDiscountAmount, 0) AS ItemDiscount,
            ISNULL(pli.GstPercentage, 0) AS GstPercentage,
            ISNULL(pli.CgstAmount, 0) + ISNULL(pli.SgstAmount, 0) + ISNULL(pli.IgstAmount, 0) AS ItemGstAmount,
            ISNULL(pli.NetLineAmount, 0) AS ItemTotalAmount
        FROM dbo.PaymentHeader ph
        INNER JOIN dbo.PatientOPDService s ON s.OPDServiceId = ph.OPDServiceId
        INNER JOIN dbo.PatientMaster p ON p.PatientId = s.PatientId
        INNER JOIN dbo.PaymentLineItem pli ON pli.PaymentHeaderId = ph.PaymentHeaderId
        WHERE ph.BranchId = @BranchId
          AND CAST(ph.CreatedDate AS DATE) >= @FromDate
          AND CAST(ph.CreatedDate AS DATE) <= @ToDate
          AND ph.IsActive = 1
          AND pli.IsActive = 1
          AND ph.ModuleCode = 'OPD'
        ORDER BY ph.CreatedDate DESC, ph.PaymentHeaderId DESC, pli.PaymentLineItemId ASC;
    END
END
GO
