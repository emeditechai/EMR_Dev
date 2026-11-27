-- ============================================================================================================
-- 2566  Ask eMedi data answer: cancelled bills (application database)
--   "Is there any cancelled bill today?", "cancelled bills this month", "refunds yesterday in pharmacy" ...
--   Every cancellation of the period in the modules asked (and allowed for the user):
--     LAB, OPD, PHR (pharmacy)  - Bill Cancellation records (full / partial cancellation, refund), by cancellation date
--     IPD                       - final bills cancelled (IpdBill.Status CANCELLED) and admissions cancelled, by cancel time
--   Patient, amount, reason and the user who cancelled. Read only. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_HelpData_Cancellations
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Modules VARCHAR(40) = 'LAB,OPD,IPD,PHR'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME)), @start DATETIME = CAST(@From AS DATETIME);

    ;WITH c AS (
        -- LAB / OPD / pharmacy: the Bill Cancellation record
        SELECT bc.ModuleCode AS Module, bc.ModuleRefId AS RefId,
               COALESCE(lo.BillNo, o.OPDBillNo, s.SaleNo) AS BillNo, bc.CancellationNo AS CancelNo, bc.CancellationDate AS CancelledAt,
               CASE bc.CancellationType WHEN 'F' THEN 'Full' WHEN 'P' THEN 'Partial' ELSE ISNULL(bc.CancellationType, '') END AS CancelType,
               bc.CancelledAmount AS Amount, bc.Reason,
               COALESCE(lo.PatientId, o.PatientId, s.PatientId) AS PatientId, s.CustomerName, bc.CreatedBy AS CancelledBy,
               COALESCE(lo.BranchId, o.BranchId, s.BranchId) AS BranchId
        FROM dbo.BillCancellation bc
        LEFT JOIN dbo.LabOrder lo ON bc.ModuleCode = 'LAB' AND lo.LabOrderId = bc.ModuleRefId
        LEFT JOIN dbo.PatientOPDService o ON bc.ModuleCode = 'OPD' AND o.OPDServiceId = bc.ModuleRefId
        LEFT JOIN dbo.PhSale s ON bc.ModuleCode = 'PHR' AND s.SaleId = bc.ModuleRefId
        WHERE ISNULL(bc.IsActive, 1) = 1 AND bc.ModuleCode IN ('LAB', 'OPD', 'PHR')
          AND bc.CancellationDate >= @start AND bc.CancellationDate < @end
        UNION ALL
        -- pharmacy sales cancelled without a Bill Cancellation record
        SELECT 'PHR', s.SaleId, s.SaleNo, NULL, s.CancelledDate, 'Full', s.NetAmount, s.CancelReason, s.PatientId, s.CustomerName, s.CancelledBy, s.BranchId
        FROM dbo.PhSale s
        WHERE s.CompanyId = @CompanyId AND s.Status = 'CANCELLED' AND s.CancelledDate >= @start AND s.CancelledDate < @end
          AND NOT EXISTS (SELECT 1 FROM dbo.BillCancellation x WHERE x.ModuleCode = 'PHR' AND x.ModuleRefId = s.SaleId AND ISNULL(x.IsActive, 1) = 1)
        UNION ALL
        -- IPD final bills cancelled
        SELECT 'IPD', b.AdmissionId, b.BillNo, NULL, b.CancelledAt, 'IPD bill', b.Net, b.CancelReason, a.PatientId, NULL, b.CancelledBy, b.BranchId
        FROM dbo.IpdBill b JOIN dbo.IpdAdmission a ON a.AdmissionId = b.AdmissionId
        WHERE b.CompanyId = @CompanyId AND b.Status = 'CANCELLED' AND b.CancelledAt >= @start AND b.CancelledAt < @end
        UNION ALL
        -- IPD admissions cancelled (made by mistake)
        SELECT 'IPD', a.AdmissionId, a.IpNo, NULL, a.CancelledAt, 'Admission', NULL, a.CancelReason, a.PatientId, NULL, a.CancelledBy, a.BranchId
        FROM dbo.IpdAdmission a
        WHERE a.CompanyId = @CompanyId AND a.Status = 'CANCELLED' AND a.CancelledAt >= @start AND a.CancelledAt < @end
    )
    SELECT c.Module, c.RefId, c.BillNo, c.CancelNo, c.CancelledAt, c.CancelType, c.Amount, c.Reason,
           COALESCE(NULLIF(LTRIM(RTRIM(CONCAT(p.Salutation, N' ', p.FirstName, N' ', p.LastName))), N''), c.CustomerName) AS PatientName,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), N''), u.Username) AS CancelledByName
    FROM c
    JOIN dbo.BranchMaster br ON br.BranchID = c.BranchId AND br.CompanyId = @CompanyId
    LEFT JOIN dbo.PatientMaster p ON p.PatientId = c.PatientId
    LEFT JOIN dbo.Users u ON u.Id = c.CancelledBy
    WHERE (@BranchId IS NULL OR c.BranchId = @BranchId) AND CHARINDEX(c.Module, @Modules) > 0
    ORDER BY c.CancelledAt DESC;
END
GO

PRINT 'Script 2566 applied: Ask eMedi - cancelled bills data answer.';
GO
