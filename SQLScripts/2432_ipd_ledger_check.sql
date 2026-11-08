-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2432  IPD accounts: check and repair of ledger posting
--   Every IPD money movement is posted when it happens (2423 usp_Ipd_PostLedger): advance receipt = RCT
--   (Dr Cash / Bank by mode, Cr IPD Patient Advance), advance refund (also on cancelling an admission) = PMT
--   (Dr IPD Patient Advance, Cr Cash / Bank). Bed and other charges are revenue at the final bill (Phase 5).
--   usp_Ipd_LedgerCheck lists IPD money without a voucher and the advance ledger against the IPD advances;
--   @Repair = 1 posts what is missing (posting a reference twice is not possible). Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_LedgerCheck @BranchId INT = NULL, @Repair BIT = 0, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @M TABLE (Kind VARCHAR(10), RefId INT, DocNo NVARCHAR(50), Amount DECIMAL(18,2), IpNo NVARCHAR(40), CreatedDate DATETIME);
    INSERT @M
    SELECT 'ADVRCPT', pd.PaymentDetailId, pd.ReceiptNo, pd.PaidAmount, a.IpNo, pd.CreatedDate
    FROM dbo.PaymentDetail pd JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND RTRIM(ph.ModuleCode) = 'IPD' AND ph.IsActive = 1
    JOIN dbo.IpdAdmission a ON a.AdmissionId = ph.ModuleRefId
    WHERE pd.IsActive = 1 AND pd.PaidAmount > 0 AND (@BranchId IS NULL OR ph.BranchId = @BranchId)
      AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType = 'IPD_ADVANCE' AND t.ReferenceId = pd.PaymentDetailId AND t.IsActive = 1 AND t.ReversalOfTransactionId IS NULL)
    UNION ALL
    SELECT 'ADVREFUND', v.AdvanceId, v.DocNo, v.Amount, a.IpNo, v.CreatedDate
    FROM dbo.IpdAdvance v JOIN dbo.IpdAdmission a ON a.AdmissionId = v.AdmissionId
    WHERE v.Kind = 'REFUND' AND v.IsActive = 1 AND (@BranchId IS NULL OR a.BranchId = @BranchId)
      AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType = 'IPD_ADVREFUND' AND t.ReferenceId = v.AdvanceId AND t.IsActive = 1 AND t.ReversalOfTransactionId IS NULL);

    IF @Repair = 1
    BEGIN
        DECLARE @k VARCHAR(10), @id INT;
        DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT Kind, RefId FROM @M ORDER BY CreatedDate;
        OPEN c; FETCH NEXT FROM c INTO @k, @id;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY EXEC dbo.usp_Ipd_PostLedger @Kind = @k, @RefId = @id, @UserId = @UserId; END TRY
            BEGIN CATCH PRINT CONCAT('Not posted ', @k, ' ', @id, ': ', ERROR_MESSAGE()); END CATCH
            FETCH NEXT FROM c INTO @k, @id;
        END
        CLOSE c; DEALLOCATE c;
    END
    -- 1 money without a voucher (before the repair)
    SELECT * FROM @M ORDER BY CreatedDate;
    -- 2 advance held per IPD against the IPD Patient Advance ledger balance (all branches when @BranchId is NULL)
    SELECT (SELECT ISNULL(SUM(CASE WHEN v.Kind = 'ADVANCE' THEN v.Amount ELSE -v.Amount END), 0) FROM dbo.IpdAdvance v JOIN dbo.IpdAdmission a ON a.AdmissionId = v.AdmissionId
             WHERE v.IsActive = 1 AND (@BranchId IS NULL OR a.BranchId = @BranchId)) AS AdvanceHeldPerIpd,
           (SELECT ISNULL(SUM(d.CreditAmount - d.DebitAmount), 0) FROM dbo.Acc_LedgerTransactionDetail d
             JOIN dbo.Acc_LedgerTransaction t ON t.TransactionId = d.TransactionId AND t.IsActive = 1 AND (@BranchId IS NULL OR t.BranchId = @BranchId)
             JOIN dbo.Acc_LedgerMaster l ON l.LedgerId = d.LedgerId AND l.LedgerName = 'IPD Patient Advance') AS AdvanceLedgerBalance;
END;
GO
PRINT '2432 IPD ledger check - done.';
GO
