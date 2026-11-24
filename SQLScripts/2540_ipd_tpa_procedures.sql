-- ============================================================================================================
-- Migration: 2540_ipd_tpa_procedures.sql (after 2539)
-- IPD Phase 6 - Insurance / TPA procedures (EMR.Api api/ipd/insurance..., IpdInsuranceController):
--   pre-auth (workspace tab, worklist with the IRDAI clock), document checklist and uploads, payer split figures,
--   claims (checklist, submission, query / reply, settlement with TDS and disallowance, settlement cancel,
--   write-off approval), TPA receivable ageing and statement, Master > IPD Master > TPA Document Checklist.
-- Write procedures are savepoint-safe and return Success / Error rows; business errors 58020-58199. Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── lookups: insurers / TPAs, settlement modes, document types ────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdTpa_Lookups @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT InsuranceTPA_ID AS InsuranceTpaId, Name, Type, Code FROM dbo.InsuranceTPAMaster WHERE CompanyId = @CompanyId AND Status = 1 ORDER BY Name;
    SELECT MethodName, MethodCode FROM dbo.PaymentMethodMaster WHERE IsActive = 1 AND UPPER(MethodCode) NOT IN ('POINTS', 'WALLET') ORDER BY MethodName;
    SELECT DocTypeId, Name, Stage, IsMandatory, SortOrder FROM dbo.IpdTpaDocType WHERE CompanyId = @CompanyId AND IsActive = 1 ORDER BY SortOrder, Name;
END
GO

-- ── the Insurance / TPA tab of the IPD Patient workspace ──────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdTpa_Data @CompanyId INT, @AdmissionId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME = GETDATE();
    IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId) RETURN;
    DECLARE @live INT = (SELECT TOP 1 PreAuthId FROM dbo.IpdPreAuth WHERE AdmissionId = @AdmissionId AND IsLive = 1);
    -- 1 admission, primary payer, bill / live split
    SELECT a.AdmissionId, a.IpNo, a.Status, a.IsOpen, a.PayerType, a.BillId, a.AdmissionAt,
           py.PayerId, py.InsuranceTpaId, ins.Name AS PayerName, ins.Type AS PayerKind, ins.AuthorizationRequired, py.PolicyNo, py.MemberId, py.CardHolderName,
           py.RelationToHolder, py.PolicyValidTo, py.CardFilePath,
           lt.Net AS BillNow, b.BillNo, b.Status AS BillStatus, b.Net AS BillNet, b.PayerAuthorised, b.CoPayPercent AS BillCoPayPercent, b.CoPayAmount AS BillCoPayAmount,
           b.Deductible AS BillDeductible, b.NonPayable AS BillNonPayable, b.PayerShare AS BillPayerShare, b.PayerToPatient,
           CAST(b.Net - b.PayerShare + b.PayerToPatient AS DECIMAL(18,2)) AS BillPatientShare,
           pa.Authorised AS LiveAuthorised, sp.Base AS LiveBase, sp.CoPayAmount AS LiveCoPayAmount, sp.PayerShare AS LivePayerShare,
           CAST(lt.Net - ISNULL(sp.PayerShare, 0) AS DECIMAL(18,2)) AS LivePatientShare, mo.NetAdvance,
           @live AS LivePreAuthId,
           CAST(CASE WHEN a.PayerType = 'INSURANCE' AND a.Status <> 'CANCELLED' AND py.InsuranceTpaId IS NOT NULL AND @live IS NULL THEN 1 ELSE 0 END AS BIT) AS CanStartPreAuth
    FROM dbo.IpdAdmission a
    LEFT JOIN dbo.IpdAdmissionPayer py ON py.AdmissionId = a.AdmissionId AND py.Seq = 1 AND py.PayerType = 'INSURANCE'
    LEFT JOIN dbo.InsuranceTPAMaster ins ON ins.InsuranceTPA_ID = py.InsuranceTpaId
    LEFT JOIN dbo.IpdBill b ON b.BillId = a.BillId
    CROSS APPLY dbo.fn_Ipd_LiveTotal(a.AdmissionId, @now) lt
    CROSS APPLY dbo.fn_Ipd_Money(a.AdmissionId) mo
    OUTER APPLY (SELECT TOP 1 Authorised, CoPayPercent, Deductible, NonPayable FROM dbo.fn_Ipd_PreAuthAuthorised(a.AdmissionId)) pa
    OUTER APPLY dbo.fn_Ipd_PayerSplit(lt.Net, pa.Authorised, pa.CoPayPercent, pa.Deductible, pa.NonPayable) sp
    WHERE a.AdmissionId = @AdmissionId;
    -- 2 pre-auths (newest first) with the IRDAI clock
    SELECT p.*, ins.Name AS PayerName,
           CASE WHEN p.Status = 'FINAL_APPROVED' THEN p.FinalApprovedAmount ELSE p.ApprovedAmount END AS Authorised,
           DATEDIFF(MINUTE, p.RequestedAt, p.DecisionAt) AS DecisionMinutes,
           DATEDIFF(MINUTE, p.FinalRequestedAt, p.FinalDecisionAt) AS FinalMinutes,
           w.WaitingSince, CASE WHEN w.WaitingSince IS NOT NULL THEN DATEDIFF(MINUTE, w.WaitingSince, @now) END AS WaitingMinutes, w.SlaMinutes,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.IpdBill x WHERE x.PreAuthId = p.PreAuthId AND x.Status = 'FINAL') THEN 1 ELSE 0 END AS BIT) AS UsedByBill,
           uc.FullName AS CreatedByName
    FROM dbo.IpdPreAuth p
    LEFT JOIN dbo.InsuranceTPAMaster ins ON ins.InsuranceTPA_ID = p.InsuranceTpaId
    LEFT JOIN dbo.Users uc ON uc.Id = p.CreatedBy
    OUTER APPLY (SELECT CASE p.Status WHEN 'FINAL_REQUESTED' THEN p.FinalRequestedAt
                                      WHEN 'REQUESTED' THEN p.RequestedAt
                                      WHEN 'ENHANCE_REQUESTED' THEN (SELECT MAX(e.EventAt) FROM dbo.IpdPreAuthEvent e WHERE e.PreAuthId = p.PreAuthId AND e.EventType = 'ENHANCE_REQUEST') END AS WaitingSince,
                        CASE p.Status WHEN 'FINAL_REQUESTED' THEN 180 WHEN 'REQUESTED' THEN 60 WHEN 'ENHANCE_REQUESTED' THEN 60 END AS SlaMinutes) w
    WHERE p.AdmissionId = @AdmissionId
    ORDER BY p.IsLive DESC, p.PreAuthId DESC;
    -- 3 events
    SELECT e.*, u.FullName AS CreatedByName, d.FilePath AS DocumentPath, d.Title AS DocumentTitle
    FROM dbo.IpdPreAuthEvent e JOIN dbo.IpdPreAuth p ON p.PreAuthId = e.PreAuthId
    LEFT JOIN dbo.Users u ON u.Id = e.CreatedBy LEFT JOIN dbo.IpdDocument d ON d.DocumentId = e.DocumentId
    WHERE p.AdmissionId = @AdmissionId ORDER BY e.EventAt DESC, e.EventId DESC;
    -- 4 pre-auth document checklist of the live pre-auth
    SELECT t.DocTypeId, t.Name, t.Stage, t.IsMandatory, t.SortOrder, ISNULL(c.IsDone, 0) AS IsDone, c.Remarks, c.CheckedAt, u.FullName AS CheckedByName,
           c.DocumentId, d.FilePath AS DocumentPath, d.Title AS DocumentTitle
    FROM dbo.IpdTpaDocType t
    LEFT JOIN dbo.IpdTpaChecklist c ON c.PreAuthId = @live AND c.DocTypeId = t.DocTypeId
    LEFT JOIN dbo.Users u ON u.Id = c.CheckedBy LEFT JOIN dbo.IpdDocument d ON d.DocumentId = c.DocumentId AND d.IsActive = 1
    WHERE @live IS NOT NULL AND t.CompanyId = @CompanyId AND t.Stage IN ('PREAUTH', 'BOTH') AND (t.IsActive = 1 OR c.ChecklistId IS NOT NULL)
    ORDER BY t.SortOrder, t.Name;
    -- 5 claims
    SELECT c.ClaimId, c.ClaimNo, c.Status, c.ClaimAmount, c.SettledAmount, c.TdsAmount, c.DisallowedAmount, c.SubmittedAt, c.TpaClaimRef,
           CAST(c.ClaimAmount - c.SettledAmount - c.TdsAmount - c.DisallowedAmount AS DECIMAL(18,2)) AS Outstanding, b.BillNo
    FROM dbo.IpdClaim c JOIN dbo.IpdBill b ON b.BillId = c.BillId
    WHERE c.AdmissionId = @AdmissionId ORDER BY c.ClaimId DESC;
END
GO

-- ── create / edit the pre-auth details (status changes go through _Event) ──────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPreAuth_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @PreAuthId INT = NULL, @TpaRefNo NVARCHAR(60) = NULL,
    @Diagnosis NVARCHAR(300) = NULL, @TreatmentPlan NVARCHAR(500) = NULL, @ExpectedDays INT = NULL, @EstimatedAmount DECIMAL(18,2) = 0, @Remarks NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @status VARCHAR(20), @payer VARCHAR(12), @open BIT, @admAt DATETIME, @diag NVARCHAR(300);
        SELECT @status = Status, @payer = PayerType, @open = IsOpen, @admAt = AdmissionAt, @diag = ProvisionalDiagnosis FROM dbo.IpdAdmission WITH (UPDLOCK)
        WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @status IS NULL THROW 58020, 'The admission was not found in this branch.', 1;
        IF @status = 'CANCELLED' THROW 58021, 'The admission is cancelled.', 1;
        IF @EstimatedAmount < 0 OR @ExpectedDays < 0 THROW 58022, 'Amounts and days cannot be negative.', 1;
        SET @TpaRefNo = NULLIF(LTRIM(RTRIM(@TpaRefNo)), N'');
        IF ISNULL(@PreAuthId, 0) = 0
        BEGIN
            IF @payer <> 'INSURANCE' THROW 58023, 'Pre-authorisation is for insurance / TPA patients: change the payer of the admission first (Edit admission).', 1;
            IF EXISTS (SELECT 1 FROM dbo.IpdPreAuth WITH (UPDLOCK, HOLDLOCK) WHERE AdmissionId = @AdmissionId AND IsLive = 1)
                THROW 58024, 'The patient already has a pre-authorisation in progress.', 1;
            DECLARE @pid INT, @tpa INT, @pol NVARCHAR(60), @mem NVARCHAR(60);
            SELECT TOP 1 @pid = PayerId, @tpa = InsuranceTpaId, @pol = PolicyNo, @mem = MemberId FROM dbo.IpdAdmissionPayer
            WHERE AdmissionId = @AdmissionId AND PayerType = 'INSURANCE' ORDER BY Seq;
            IF @tpa IS NULL THROW 58025, 'The admission has no insurance / TPA (Edit admission > payer).', 1;
            DECLARE @no NVARCHAR(40), @now DATETIME = GETDATE();
            EXEC dbo.usp_Ipd_NextNumber @BranchId = @BranchId, @DocType = 'IPA', @DocDate = @now, @DocNo = @no OUTPUT;
            INSERT dbo.IpdPreAuth (CompanyId, BranchId, AdmissionId, PayerId, InsuranceTpaId, PreAuthNo, TpaRefNo, PolicyNo, MemberId, Status, Diagnosis, TreatmentPlan,
                   ExpectedDays, EstimatedAmount, Remarks, CreatedBy)
            VALUES (@CompanyId, @BranchId, @AdmissionId, @pid, @tpa, @no, @TpaRefNo, @pol, @mem, 'DRAFT', ISNULL(NULLIF(LTRIM(RTRIM(@Diagnosis)), N''), @diag),
                    NULLIF(LTRIM(RTRIM(@TreatmentPlan)), N''), @ExpectedDays, ISNULL(@EstimatedAmount, 0), NULLIF(LTRIM(RTRIM(@Remarks)), N''), @UserId);
            SET @PreAuthId = CAST(SCOPE_IDENTITY() AS INT);
            -- the pre-auth document checklist
            INSERT dbo.IpdTpaChecklist (PreAuthId, DocTypeId)
            SELECT @PreAuthId, DocTypeId FROM dbo.IpdTpaDocType WHERE CompanyId = @CompanyId AND IsActive = 1 AND Stage IN ('PREAUTH', 'BOTH');
            INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy) VALUES (@AdmissionId, 'PREAUTH', CONCAT(N'Pre-authorisation ', @no, N' started'), @UserId);
        END
        ELSE
        BEGIN
            DECLARE @ps VARCHAR(20);
            SELECT @ps = Status FROM dbo.IpdPreAuth WITH (UPDLOCK) WHERE PreAuthId = @PreAuthId AND AdmissionId = @AdmissionId AND CompanyId = @CompanyId;
            IF @ps IS NULL THROW 58026, 'The pre-authorisation was not found.', 1;
            IF @ps IN ('REJECTED', 'CANCELLED') THROW 58027, 'A rejected or cancelled pre-authorisation cannot be changed.', 1;
            UPDATE dbo.IpdPreAuth SET TpaRefNo = @TpaRefNo, Diagnosis = NULLIF(LTRIM(RTRIM(@Diagnosis)), N''), TreatmentPlan = NULLIF(LTRIM(RTRIM(@TreatmentPlan)), N''),
                   ExpectedDays = @ExpectedDays, EstimatedAmount = ISNULL(@EstimatedAmount, 0), Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N''),
                   ModifiedBy = @UserId, ModifiedDate = GETDATE()
            WHERE PreAuthId = @PreAuthId;
        END
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @PreAuthId AS PreAuthId, (SELECT PreAuthNo FROM dbo.IpdPreAuth WHERE PreAuthId = @PreAuthId) AS PreAuthNo;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END
GO

-- ── a step of the pre-auth: REQUEST QUERY QUERY_REPLY APPROVAL REJECTION ENHANCE_REQUEST FINAL_REQUEST FINAL_APPROVAL CANCEL NOTE
--    @EventAt = when it happened (the IRDAI clock uses it): not in the future, not before the admission or the previous step
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPreAuth_Event
    @CompanyId INT, @BranchId INT, @UserId INT, @PreAuthId INT, @EventType VARCHAR(20), @EventAt DATETIME = NULL, @Amount DECIMAL(18,2) = NULL,
    @RefNo NVARCHAR(60) = NULL, @Remarks NVARCHAR(500) = NULL, @DocumentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE(), @msg NVARCHAR(600);
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        SET @EventType = UPPER(LTRIM(RTRIM(@EventType)));
        SET @Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N''); SET @RefNo = NULLIF(LTRIM(RTRIM(@RefNo)), N'');
        DECLARE @st VARCHAR(20), @prev VARCHAR(20), @adm INT, @approved DECIMAL(18,2), @no NVARCHAR(40), @admAt DATETIME, @admStatus VARCHAR(20);
        SELECT @st = p.Status, @prev = p.PrevStatus, @adm = p.AdmissionId, @approved = p.ApprovedAmount, @no = p.PreAuthNo, @admAt = a.AdmissionAt, @admStatus = a.Status
        FROM dbo.IpdPreAuth p WITH (UPDLOCK) JOIN dbo.IpdAdmission a ON a.AdmissionId = p.AdmissionId
        WHERE p.PreAuthId = @PreAuthId AND p.CompanyId = @CompanyId AND p.BranchId = @BranchId;
        IF @st IS NULL THROW 58030, 'The pre-authorisation was not found in this branch.', 1;
        IF @EventType NOT IN ('REQUEST', 'QUERY', 'QUERY_REPLY', 'APPROVAL', 'REJECTION', 'ENHANCE_REQUEST', 'FINAL_REQUEST', 'FINAL_APPROVAL', 'CANCEL', 'NOTE')
            THROW 58031, 'Unknown pre-authorisation step.', 1;
        IF @st IN ('REJECTED', 'CANCELLED') AND @EventType <> 'NOTE' THROW 58032, 'The pre-authorisation is closed (rejected / cancelled): start a new one if needed.', 1;
        IF @EventType <> 'NOTE' AND EXISTS (SELECT 1 FROM dbo.IpdBill WHERE PreAuthId = @PreAuthId AND Status = 'FINAL')
            THROW 58033, 'The final bill is already made on this pre-authorisation: cancel the bill to change it (only notes can be added now).', 1;
        SET @EventAt = ISNULL(@EventAt, @now);
        IF @EventAt > DATEADD(MINUTE, 5, @now) THROW 58034, 'The time cannot be in the future.', 1;
        IF @EventAt < DATEADD(DAY, -2, @admAt) THROW 58035, 'The time cannot be before the admission.', 1;
        DECLARE @last DATETIME = (SELECT MAX(EventAt) FROM dbo.IpdPreAuthEvent WHERE PreAuthId = @PreAuthId AND EventType <> 'NOTE');
        IF @EventType <> 'NOTE' AND @last IS NOT NULL AND @EventAt < @last THROW 58036, 'The time cannot be before the previous step of the pre-authorisation.', 1;
        IF @EventType IN ('REQUEST', 'APPROVAL', 'ENHANCE_REQUEST', 'FINAL_REQUEST', 'FINAL_APPROVAL') AND ISNULL(@Amount, 0) <= 0
            THROW 58037, 'Enter the amount.', 1;
        IF @Amount IS NOT NULL AND (@Amount < 0 OR @Amount > 100000000) THROW 58038, 'The amount is not valid.', 1;
        IF @EventType IN ('QUERY', 'REJECTION', 'CANCEL') AND @Remarks IS NULL THROW 58039, 'Enter the remarks (the TPA''s query / reason).', 1;

        -- the step decides the next status
        DECLARE @to VARCHAR(20) = @st, @stage VARCHAR(20) = CASE WHEN @st = 'QUERY' THEN @prev ELSE @st END;
        IF @EventType = 'REQUEST'
        BEGIN
            IF @st <> 'DRAFT' THROW 58040, 'The request is already sent.', 1;
            SET @to = 'REQUESTED';
            UPDATE dbo.IpdPreAuth SET RequestedAmount = @Amount, RequestedAt = @EventAt WHERE PreAuthId = @PreAuthId;
        END
        ELSE IF @EventType = 'QUERY'
        BEGIN
            IF @st NOT IN ('REQUESTED', 'ENHANCE_REQUESTED', 'FINAL_REQUESTED') THROW 58041, 'A query can come only on a request that waits for the TPA.', 1;
            SET @to = 'QUERY';
            UPDATE dbo.IpdPreAuth SET PrevStatus = @st WHERE PreAuthId = @PreAuthId;
        END
        ELSE IF @EventType = 'QUERY_REPLY'
        BEGIN
            IF @st <> 'QUERY' THROW 58042, 'There is no open query to reply to.', 1;
            SET @to = ISNULL(@prev, 'REQUESTED');
            UPDATE dbo.IpdPreAuth SET PrevStatus = NULL WHERE PreAuthId = @PreAuthId;
        END
        ELSE IF @EventType = 'APPROVAL'
        BEGIN
            IF @stage NOT IN ('REQUESTED', 'ENHANCE_REQUESTED') THROW 58043, 'Approval (initial or enhancement) is recorded on a request that waits for the TPA.', 1;
            SET @to = 'APPROVED';
            UPDATE dbo.IpdPreAuth SET ApprovedAmount = @Amount, DecisionAt = ISNULL(DecisionAt, @EventAt), PrevStatus = NULL, EnhancementRequested = NULL,
                   TpaRefNo = ISNULL(TpaRefNo, @RefNo) WHERE PreAuthId = @PreAuthId;
        END
        ELSE IF @EventType = 'REJECTION'
        BEGIN
            IF @stage NOT IN ('REQUESTED', 'ENHANCE_REQUESTED', 'FINAL_REQUESTED') THROW 58044, 'A rejection is recorded on a request that waits for the TPA.', 1;
            -- an enhancement turned down keeps the approval; anything else closes the pre-auth (the patient pays, or claims reimbursement)
            SET @to = CASE WHEN @stage = 'ENHANCE_REQUESTED' AND @approved > 0 THEN 'APPROVED' ELSE 'REJECTED' END;
            UPDATE dbo.IpdPreAuth SET PrevStatus = NULL, EnhancementRequested = NULL,
                   DecisionAt = CASE WHEN @stage = 'REQUESTED' THEN ISNULL(DecisionAt, @EventAt) ELSE DecisionAt END,
                   FinalDecisionAt = CASE WHEN @stage = 'FINAL_REQUESTED' THEN @EventAt ELSE FinalDecisionAt END,
                   IsLive = CASE WHEN @to = 'REJECTED' THEN 0 ELSE 1 END WHERE PreAuthId = @PreAuthId;
        END
        ELSE IF @EventType = 'ENHANCE_REQUEST'
        BEGIN
            IF @st <> 'APPROVED' THROW 58045, 'An enhancement is asked after the first approval.', 1;
            IF @Amount <= @approved
            BEGIN
                SET @msg = CONCAT(N'The enhancement asks for a new total above the approved ₹', FORMAT(@approved, 'N2', 'en-IN'), N'.');
                THROW 58046, @msg, 1;
            END;
            SET @to = 'ENHANCE_REQUESTED';
            UPDATE dbo.IpdPreAuth SET EnhancementRequested = @Amount WHERE PreAuthId = @PreAuthId;
        END
        ELSE IF @EventType = 'FINAL_REQUEST'
        BEGIN
            IF @st NOT IN ('APPROVED', 'ENHANCE_REQUESTED') THROW 58047, 'Final authorisation is asked after the pre-authorisation is approved.', 1;
            SET @to = 'FINAL_REQUESTED';
            UPDATE dbo.IpdPreAuth SET FinalRequestedAmount = @Amount, FinalRequestedAt = @EventAt, EnhancementRequested = NULL WHERE PreAuthId = @PreAuthId;
        END
        ELSE IF @EventType = 'FINAL_APPROVAL'
        BEGIN
            IF @stage <> 'FINAL_REQUESTED' THROW 58048, 'Final authorisation is recorded after it is asked for (Final request).', 1;
            SET @to = 'FINAL_APPROVED';
            UPDATE dbo.IpdPreAuth SET FinalApprovedAmount = @Amount, FinalDecisionAt = @EventAt, PrevStatus = NULL WHERE PreAuthId = @PreAuthId;
        END
        ELSE IF @EventType = 'CANCEL'
        BEGIN
            SET @to = 'CANCELLED';
            UPDATE dbo.IpdPreAuth SET IsLive = 0, CancelReason = @Remarks, PrevStatus = NULL WHERE PreAuthId = @PreAuthId;
        END
        IF @RefNo IS NOT NULL AND @EventType IN ('APPROVAL', 'FINAL_APPROVAL', 'REQUEST')
            UPDATE dbo.IpdPreAuth SET TpaRefNo = ISNULL(TpaRefNo, @RefNo) WHERE PreAuthId = @PreAuthId;
        IF @DocumentId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.IpdDocument WHERE DocumentId = @DocumentId AND AdmissionId = @adm) SET @DocumentId = NULL;

        UPDATE dbo.IpdPreAuth SET Status = @to, ModifiedBy = @UserId, ModifiedDate = @now WHERE PreAuthId = @PreAuthId;
        INSERT dbo.IpdPreAuthEvent (PreAuthId, EventType, EventAt, Amount, RefNo, Remarks, FromStatus, ToStatus, DocumentId, CreatedBy)
        VALUES (@PreAuthId, @EventType, @EventAt, @Amount, @RefNo, @Remarks, @st, @to, @DocumentId, @UserId);
        IF @EventType <> 'NOTE'
            INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
            VALUES (@adm, 'PREAUTH', CONCAT(N'Pre-auth ', @no, N': ', LOWER(REPLACE(@EventType, '_', ' ')), CASE WHEN @Amount IS NOT NULL THEN N' ₹' + FORMAT(@Amount, 'N2', 'en-IN') ELSE N'' END,
                    ISNULL(N' - ' + LEFT(@Remarks, 200), N'')), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @PreAuthId AS PreAuthId, @to AS Status, @no AS PreAuthNo, @adm AS AdmissionId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END
GO

-- ── the patient's share as per the policy: co-pay %, deductible, non-payables (used by the final bill) ─────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPreAuth_SetSplit
    @CompanyId INT, @BranchId INT, @UserId INT, @PreAuthId INT, @CoPayPercent DECIMAL(5,2) = 0, @Deductible DECIMAL(18,2) = 0, @NonPayable DECIMAL(18,2) = 0, @Remarks NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @st VARCHAR(20), @adm INT, @no NVARCHAR(40);
    SELECT @st = Status, @adm = AdmissionId, @no = PreAuthNo FROM dbo.IpdPreAuth WHERE PreAuthId = @PreAuthId AND CompanyId = @CompanyId AND BranchId = @BranchId;
    IF @st IS NULL BEGIN SELECT CAST(0 AS BIT) AS Success, N'The pre-authorisation was not found in this branch.' AS Error; RETURN; END;
    IF @st IN ('REJECTED', 'CANCELLED') BEGIN SELECT CAST(0 AS BIT) AS Success, N'The pre-authorisation is closed.' AS Error; RETURN; END;
    IF EXISTS (SELECT 1 FROM dbo.IpdBill WHERE PreAuthId = @PreAuthId AND Status = 'FINAL')
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'The final bill is already made: cancel the bill to change the split.' AS Error; RETURN; END;
    IF ISNULL(@CoPayPercent, 0) < 0 OR @CoPayPercent > 100 BEGIN SELECT CAST(0 AS BIT) AS Success, N'Co-pay must be between 0 and 100 %.' AS Error; RETURN; END;
    IF ISNULL(@Deductible, 0) < 0 OR ISNULL(@NonPayable, 0) < 0 BEGIN SELECT CAST(0 AS BIT) AS Success, N'Deductible and non-payables cannot be negative.' AS Error; RETURN; END;
    UPDATE dbo.IpdPreAuth SET CoPayPercent = ISNULL(@CoPayPercent, 0), Deductible = ISNULL(@Deductible, 0), NonPayable = ISNULL(@NonPayable, 0),
           SplitRemarks = NULLIF(LTRIM(RTRIM(@Remarks)), N''), ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE PreAuthId = @PreAuthId;
    INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
    VALUES (@adm, 'PREAUTH', CONCAT(N'Pre-auth ', @no, N': patient share set - co-pay ', FORMAT(ISNULL(@CoPayPercent, 0), '0.##'), N' %, deductible ₹', FORMAT(ISNULL(@Deductible, 0), 'N2', 'en-IN'),
            N', non-payables ₹', FORMAT(ISNULL(@NonPayable, 0), 'N2', 'en-IN')), @UserId);
    SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @PreAuthId AS PreAuthId;
END
GO

-- ── checklist tick (pre-auth or claim) ─────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdTpa_ChecklistSet
    @CompanyId INT, @BranchId INT, @UserId INT, @PreAuthId INT = NULL, @ClaimId INT = NULL, @DocTypeId INT, @IsDone BIT, @Remarks NVARCHAR(300) = NULL, @DocumentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF (@PreAuthId IS NULL AND @ClaimId IS NULL) OR (@PreAuthId IS NOT NULL AND @ClaimId IS NOT NULL)
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'Choose the pre-authorisation or the claim.' AS Error; RETURN; END;
    IF @PreAuthId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.IpdPreAuth WHERE PreAuthId = @PreAuthId AND CompanyId = @CompanyId AND BranchId = @BranchId AND IsLive = 1)
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'The pre-authorisation was not found or is closed.' AS Error; RETURN; END;
    IF @ClaimId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.IpdClaim WHERE ClaimId = @ClaimId AND CompanyId = @CompanyId AND BranchId = @BranchId AND Status <> 'CANCELLED')
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'The claim was not found or is cancelled.' AS Error; RETURN; END;
    IF NOT EXISTS (SELECT 1 FROM dbo.IpdTpaDocType WHERE DocTypeId = @DocTypeId AND CompanyId = @CompanyId)
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'The document type was not found.' AS Error; RETURN; END;
    MERGE dbo.IpdTpaChecklist AS t
    USING (SELECT @PreAuthId AS PreAuthId, @ClaimId AS ClaimId, @DocTypeId AS DocTypeId) s
       ON t.DocTypeId = s.DocTypeId AND ((s.PreAuthId IS NOT NULL AND t.PreAuthId = s.PreAuthId) OR (s.ClaimId IS NOT NULL AND t.ClaimId = s.ClaimId))
    WHEN MATCHED THEN UPDATE SET IsDone = @IsDone, Remarks = COALESCE(NULLIF(LTRIM(RTRIM(@Remarks)), N''), t.Remarks), DocumentId = COALESCE(@DocumentId, t.DocumentId),
                                 CheckedBy = @UserId, CheckedAt = GETDATE()
    WHEN NOT MATCHED THEN INSERT (PreAuthId, ClaimId, DocTypeId, IsDone, Remarks, DocumentId, CheckedBy, CheckedAt)
                          VALUES (@PreAuthId, @ClaimId, @DocTypeId, @IsDone, NULLIF(LTRIM(RTRIM(@Remarks)), N''), @DocumentId, @UserId, GETDATE());
    SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error;
END
GO

-- ── a document of a pre-auth / claim: saved with the admission's documents and ticked on the checklist ──────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdTpa_AddDocument
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @PreAuthId INT = NULL, @ClaimId INT = NULL, @DocTypeId INT = NULL,
    @Title NVARCHAR(150) = NULL, @FilePath NVARCHAR(400), @Remarks NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId AND Status <> 'CANCELLED')
            THROW 58050, 'The admission was not found in this branch.', 1;
        IF NULLIF(LTRIM(RTRIM(@FilePath)), N'') IS NULL THROW 58051, 'Choose the file to upload.', 1;
        IF @PreAuthId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.IpdPreAuth WHERE PreAuthId = @PreAuthId AND AdmissionId = @AdmissionId)
            THROW 58052, 'The pre-authorisation was not found.', 1;
        IF @ClaimId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.IpdClaim WHERE ClaimId = @ClaimId AND AdmissionId = @AdmissionId)
            THROW 58053, 'The claim was not found.', 1;
        DECLARE @dt NVARCHAR(150) = (SELECT Name FROM dbo.IpdTpaDocType WHERE DocTypeId = @DocTypeId AND CompanyId = @CompanyId);
        IF @DocTypeId IS NOT NULL AND @dt IS NULL THROW 58054, 'The document type was not found.', 1;
        INSERT dbo.IpdDocument (AdmissionId, DocType, Title, FilePath, Remarks, CreatedBy, PreAuthId, ClaimId, TpaDocTypeId)
        VALUES (@AdmissionId, CASE WHEN @ClaimId IS NOT NULL THEN N'TPA claim' ELSE N'TPA pre-auth' END,
                LEFT(COALESCE(NULLIF(LTRIM(RTRIM(@Title)), N''), @dt, N'Document'), 150), @FilePath, NULLIF(LTRIM(RTRIM(@Remarks)), N''), @UserId, @PreAuthId, @ClaimId, @DocTypeId);
        DECLARE @doc INT = CAST(SCOPE_IDENTITY() AS INT);
        IF @DocTypeId IS NOT NULL AND (@PreAuthId IS NOT NULL OR @ClaimId IS NOT NULL)
            MERGE dbo.IpdTpaChecklist AS t
            USING (SELECT CASE WHEN @ClaimId IS NULL THEN @PreAuthId END AS PreAuthId, @ClaimId AS ClaimId, @DocTypeId AS DocTypeId) s
               ON t.DocTypeId = s.DocTypeId AND ((s.PreAuthId IS NOT NULL AND t.PreAuthId = s.PreAuthId) OR (s.ClaimId IS NOT NULL AND t.ClaimId = s.ClaimId))
            WHEN MATCHED THEN UPDATE SET IsDone = 1, DocumentId = @doc, CheckedBy = @UserId, CheckedAt = GETDATE()
            WHEN NOT MATCHED THEN INSERT (PreAuthId, ClaimId, DocTypeId, IsDone, DocumentId, CheckedBy, CheckedAt) VALUES (s.PreAuthId, s.ClaimId, s.DocTypeId, 1, @doc, @UserId, GETDATE());
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'DOCUMENT', CONCAT(N'TPA document added: ', COALESCE(@dt, @Title, N'document')), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @doc AS DocumentId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END
GO

-- ── IPD > Pre-Authorisations: worklist with the IRDAI clock (1 h decision, 3 h final authorisation) ────────────────
--    @View OPEN = in progress, WAITING = waiting for the TPA, BREACHED = past the time limit, ALL = everything in the dates
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPreAuth_List
    @CompanyId INT, @BranchId INT, @View VARCHAR(10) = 'OPEN', @InsuranceTpaId INT = NULL, @Search NVARCHAR(100) = NULL, @FromDate DATE = NULL, @ToDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME = GETDATE(), @like NVARCHAR(110) = N'%' + NULLIF(LTRIM(RTRIM(@Search)), N'') + N'%';
    SET @FromDate = ISNULL(@FromDate, DATEADD(DAY, -90, CAST(@now AS DATE))); SET @ToDate = ISNULL(@ToDate, CAST(@now AS DATE));
    SELECT p.PreAuthId, p.PreAuthNo, p.AdmissionId, p.Status, p.PrevStatus, p.TpaRefNo, p.RequestedAmount, p.ApprovedAmount, p.EnhancementRequested,
           p.FinalRequestedAmount, p.FinalApprovedAmount, p.RequestedAt, p.DecisionAt, p.FinalRequestedAt, p.FinalDecisionAt, p.CreatedDate,
           a.IpNo, a.Status AS AdmissionStatus, pt.PatientCode, LTRIM(RTRIM(CONCAT(NULLIF(pt.Salutation, '') + ' ', pt.FirstName, ' ', pt.LastName))) AS PatientName,
           ins.Name AS PayerName, ins.Type AS PayerKind, d.FullName AS ConsultantDoctorName, bd.BedNumber,
           DATEDIFF(MINUTE, p.RequestedAt, p.DecisionAt) AS DecisionMinutes, DATEDIFF(MINUTE, p.FinalRequestedAt, p.FinalDecisionAt) AS FinalMinutes,
           w.WaitingSince, CASE WHEN w.WaitingSince IS NOT NULL THEN DATEDIFF(MINUTE, w.WaitingSince, @now) END AS WaitingMinutes, w.SlaMinutes,
           CAST(CASE WHEN w.WaitingSince IS NOT NULL AND DATEDIFF(MINUTE, w.WaitingSince, @now) > w.SlaMinutes THEN 1 ELSE 0 END AS BIT) AS Breached,
           (SELECT TOP 1 e.Remarks FROM dbo.IpdPreAuthEvent e WHERE e.PreAuthId = p.PreAuthId AND e.EventType = 'QUERY' ORDER BY e.EventAt DESC) AS LastQuery
    FROM dbo.IpdPreAuth p
    JOIN dbo.IpdAdmission a ON a.AdmissionId = p.AdmissionId
    JOIN dbo.PatientMaster pt ON pt.PatientId = a.PatientId
    LEFT JOIN dbo.InsuranceTPAMaster ins ON ins.InsuranceTPA_ID = p.InsuranceTpaId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = a.ConsultantDoctorId
    LEFT JOIN dbo.BedMaster bd ON bd.BedId = a.CurrentBedId
    OUTER APPLY (SELECT CASE p.Status WHEN 'FINAL_REQUESTED' THEN p.FinalRequestedAt
                                      WHEN 'REQUESTED' THEN p.RequestedAt
                                      WHEN 'ENHANCE_REQUESTED' THEN (SELECT MAX(e.EventAt) FROM dbo.IpdPreAuthEvent e WHERE e.PreAuthId = p.PreAuthId AND e.EventType = 'ENHANCE_REQUEST') END AS WaitingSince,
                        CASE p.Status WHEN 'FINAL_REQUESTED' THEN 180 WHEN 'REQUESTED' THEN 60 WHEN 'ENHANCE_REQUESTED' THEN 60 END AS SlaMinutes) w
    WHERE p.CompanyId = @CompanyId AND p.BranchId = @BranchId
      AND (@InsuranceTpaId IS NULL OR p.InsuranceTpaId = @InsuranceTpaId)
      AND (@like IS NULL OR a.IpNo LIKE @like OR pt.PatientCode LIKE @like OR p.PreAuthNo LIKE @like OR p.TpaRefNo LIKE @like OR CONCAT(pt.FirstName, ' ', pt.LastName) LIKE @like)
      AND (CASE @View WHEN 'ALL' THEN CASE WHEN CAST(p.CreatedDate AS DATE) BETWEEN @FromDate AND @ToDate THEN 1 ELSE 0 END
                      WHEN 'WAITING' THEN CASE WHEN w.WaitingSince IS NOT NULL THEN 1 ELSE 0 END
                      WHEN 'BREACHED' THEN CASE WHEN w.WaitingSince IS NOT NULL AND DATEDIFF(MINUTE, w.WaitingSince, @now) > w.SlaMinutes THEN 1 ELSE 0 END
                      ELSE CASE WHEN p.IsLive = 1 AND (a.IsOpen = 1 OR p.Status <> 'FINAL_APPROVED') THEN 1 ELSE 0 END END) = 1
    ORDER BY CASE WHEN w.WaitingSince IS NOT NULL THEN 0 ELSE 1 END, w.WaitingSince, p.PreAuthId DESC;
    -- KPIs of the branch (live pre-auths) and this month's turnaround
    DECLARE @m1 DATETIME = DATEFROMPARTS(YEAR(@now), MONTH(@now), 1);
    SELECT SUM(CASE WHEN p.Status = 'DRAFT' THEN 1 ELSE 0 END) AS Drafts,
           SUM(CASE WHEN p.Status IN ('REQUESTED', 'ENHANCE_REQUESTED', 'FINAL_REQUESTED') THEN 1 ELSE 0 END) AS WaitingTpa,
           SUM(CASE WHEN p.Status = 'QUERY' THEN 1 ELSE 0 END) AS OpenQueries,
           SUM(CASE WHEN (p.Status = 'REQUESTED' AND DATEDIFF(MINUTE, p.RequestedAt, @now) > 60) OR (p.Status = 'FINAL_REQUESTED' AND DATEDIFF(MINUTE, p.FinalRequestedAt, @now) > 180) THEN 1 ELSE 0 END) AS Breached,
           (SELECT AVG(CAST(DATEDIFF(MINUTE, x.RequestedAt, x.DecisionAt) AS DECIMAL(10,1))) FROM dbo.IpdPreAuth x
             WHERE x.CompanyId = @CompanyId AND x.BranchId = @BranchId AND x.DecisionAt >= @m1) AS AvgDecisionMinutes,
           (SELECT AVG(CAST(DATEDIFF(MINUTE, x.FinalRequestedAt, x.FinalDecisionAt) AS DECIMAL(10,1))) FROM dbo.IpdPreAuth x
             WHERE x.CompanyId = @CompanyId AND x.BranchId = @BranchId AND x.FinalDecisionAt >= @m1) AS AvgFinalMinutes,
           (SELECT COUNT(*) FROM dbo.IpdPreAuth x WHERE x.CompanyId = @CompanyId AND x.BranchId = @BranchId AND x.DecisionAt >= @m1 AND DATEDIFF(MINUTE, x.RequestedAt, x.DecisionAt) <= 60) AS DecidedInTime,
           (SELECT COUNT(*) FROM dbo.IpdPreAuth x WHERE x.CompanyId = @CompanyId AND x.BranchId = @BranchId AND x.DecisionAt >= @m1) AS DecidedThisMonth
    FROM dbo.IpdPreAuth p WHERE p.CompanyId = @CompanyId AND p.BranchId = @BranchId AND p.IsLive = 1;
END
GO

-- ── claims ─────────────────────────────────────────────────────────────────────────────────────────────────────────
-- made by the final bill (2541) when it has a payer share: OPEN, with the claim document checklist
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_ClaimCreate @BillId INT, @UserId INT = NULL, @ClaimId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @co INT, @br INT, @adm INT, @pa INT, @tpa INT, @share DECIMAL(18,2), @at DATETIME;
    SELECT @co = CompanyId, @br = BranchId, @adm = AdmissionId, @pa = PreAuthId, @tpa = InsuranceTpaId, @share = PayerShare, @at = BillAt FROM dbo.IpdBill WHERE BillId = @BillId;
    IF ISNULL(@share, 0) <= 0 OR @tpa IS NULL RETURN;
    SELECT @ClaimId = ClaimId FROM dbo.IpdClaim WHERE BillId = @BillId AND IsLive = 1;
    IF @ClaimId IS NOT NULL RETURN;
    DECLARE @no NVARCHAR(40);
    EXEC dbo.usp_Ipd_NextNumber @BranchId = @br, @DocType = 'CLM', @DocDate = @at, @DocNo = @no OUTPUT;
    INSERT dbo.IpdClaim (CompanyId, BranchId, AdmissionId, BillId, PreAuthId, InsuranceTpaId, ClaimNo, TpaClaimRef, ClaimAmount, Status, CreatedBy)
    VALUES (@co, @br, @adm, @BillId, @pa, @tpa, @no, (SELECT TpaRefNo FROM dbo.IpdPreAuth WHERE PreAuthId = @pa), @share, 'OPEN', @UserId);
    SET @ClaimId = CAST(SCOPE_IDENTITY() AS INT);
    INSERT dbo.IpdTpaChecklist (ClaimId, DocTypeId, IsDone, DocumentId, CheckedBy, CheckedAt)
    SELECT @ClaimId, t.DocTypeId,
           -- documents already given at pre-auth count for the claim too
           CASE WHEN pc.IsDone = 1 THEN 1 ELSE 0 END, pc.DocumentId, CASE WHEN pc.IsDone = 1 THEN pc.CheckedBy END, CASE WHEN pc.IsDone = 1 THEN pc.CheckedAt END
    FROM dbo.IpdTpaDocType t
    LEFT JOIN dbo.IpdTpaChecklist pc ON pc.PreAuthId = @pa AND pc.DocTypeId = t.DocTypeId AND t.Stage = 'BOTH'
    WHERE t.CompanyId = @co AND t.IsActive = 1 AND t.Stage IN ('CLAIM', 'BOTH');
    INSERT dbo.IpdClaimEvent (ClaimId, EventType, EventAt, Amount, Remarks, CreatedBy)
    VALUES (@ClaimId, 'CREATED', GETDATE(), @share, N'Claim made with the final bill (TPA / insurance share).', @UserId);
END
GO

-- IPD > TPA Claims: @Status ACTIVE (open .. part-settled), a status, or ALL; dates on the bill
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdClaim_List
    @CompanyId INT, @BranchId INT, @Status VARCHAR(20) = 'ACTIVE', @InsuranceTpaId INT = NULL, @Search NVARCHAR(100) = NULL, @FromDate DATE = NULL, @ToDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME = GETDATE(), @like NVARCHAR(110) = N'%' + NULLIF(LTRIM(RTRIM(@Search)), N'') + N'%';
    SET @Status = ISNULL(NULLIF(@Status, ''), 'ACTIVE');
    SELECT c.ClaimId, c.ClaimNo, c.Status, c.TpaClaimRef, c.ClaimAmount, c.SettledAmount, c.TdsAmount, c.DisallowedAmount, c.ToPatientAmount, c.WrittenOffAmount,
           CAST(c.ClaimAmount - c.SettledAmount - c.TdsAmount - c.DisallowedAmount AS DECIMAL(18,2)) AS Outstanding,
           c.SubmittedAt, c.SubmissionMode, c.LastSettledAt, c.AdmissionId, c.InsuranceTpaId,
           b.BillNo, b.BillAt, b.Net AS BillNet, a.IpNo, a.DischargeAt, pt.PatientCode, LTRIM(RTRIM(CONCAT(NULLIF(pt.Salutation, '') + ' ', pt.FirstName, ' ', pt.LastName))) AS PatientName,
           ins.Name AS PayerName, pa.PreAuthNo,
           DATEDIFF(DAY, b.BillAt, @now) AS AgeDays,
           (SELECT COUNT(*) FROM dbo.IpdTpaChecklist k JOIN dbo.IpdTpaDocType t ON t.DocTypeId = k.DocTypeId WHERE k.ClaimId = c.ClaimId AND t.IsMandatory = 1 AND k.IsDone = 0) AS MissingDocs,
           (SELECT ISNULL(SUM(o.Amount), 0) FROM dbo.IpdClaimWriteOff o WHERE o.ClaimId = c.ClaimId AND o.Status = 'PENDING') AS PendingWriteOff
    FROM dbo.IpdClaim c
    JOIN dbo.IpdBill b ON b.BillId = c.BillId
    JOIN dbo.IpdAdmission a ON a.AdmissionId = c.AdmissionId
    JOIN dbo.PatientMaster pt ON pt.PatientId = a.PatientId
    LEFT JOIN dbo.InsuranceTPAMaster ins ON ins.InsuranceTPA_ID = c.InsuranceTpaId
    LEFT JOIN dbo.IpdPreAuth pa ON pa.PreAuthId = c.PreAuthId
    WHERE c.CompanyId = @CompanyId AND c.BranchId = @BranchId
      AND (@InsuranceTpaId IS NULL OR c.InsuranceTpaId = @InsuranceTpaId)
      AND (@FromDate IS NULL OR CAST(b.BillAt AS DATE) >= @FromDate) AND (@ToDate IS NULL OR CAST(b.BillAt AS DATE) <= @ToDate)
      AND (@like IS NULL OR c.ClaimNo LIKE @like OR c.TpaClaimRef LIKE @like OR b.BillNo LIKE @like OR a.IpNo LIKE @like OR pt.PatientCode LIKE @like OR CONCAT(pt.FirstName, ' ', pt.LastName) LIKE @like)
      AND (@Status = 'ALL' OR c.Status = @Status OR (@Status = 'ACTIVE' AND c.Status IN ('OPEN', 'SUBMITTED', 'QUERY', 'PART_SETTLED'))
           OR (@Status = 'WRITEOFF' AND EXISTS (SELECT 1 FROM dbo.IpdClaimWriteOff o WHERE o.ClaimId = c.ClaimId AND o.Status = 'PENDING')))
    ORDER BY CASE c.Status WHEN 'QUERY' THEN 0 WHEN 'OPEN' THEN 1 WHEN 'SUBMITTED' THEN 2 WHEN 'PART_SETTLED' THEN 3 ELSE 4 END, b.BillAt;
    -- KPIs (branch)
    SELECT SUM(CASE WHEN Status = 'OPEN' THEN 1 ELSE 0 END) AS ToSubmit,
           SUM(CASE WHEN Status IN ('SUBMITTED', 'PART_SETTLED') THEN 1 ELSE 0 END) AS AwaitingSettlement,
           SUM(CASE WHEN Status = 'QUERY' THEN 1 ELSE 0 END) AS OpenQueries,
           CAST(SUM(CASE WHEN Status NOT IN ('CANCELLED') THEN ClaimAmount - SettledAmount - TdsAmount - DisallowedAmount ELSE 0 END) AS DECIMAL(18,2)) AS Outstanding,
           (SELECT COUNT(*) FROM dbo.IpdClaimWriteOff o JOIN dbo.IpdClaim x ON x.ClaimId = o.ClaimId WHERE x.CompanyId = @CompanyId AND x.BranchId = @BranchId AND o.Status = 'PENDING') AS PendingWriteOffs,
           (SELECT CAST(ISNULL(SUM(s.Amount), 0) AS DECIMAL(18,2)) FROM dbo.IpdClaimSettlement s JOIN dbo.IpdClaim x ON x.ClaimId = s.ClaimId
             WHERE x.CompanyId = @CompanyId AND x.BranchId = @BranchId AND s.Status = 'POSTED' AND s.SettledOn >= DATEFROMPARTS(YEAR(@now), MONTH(@now), 1)) AS ReceivedThisMonth
    FROM dbo.IpdClaim WHERE CompanyId = @CompanyId AND BranchId = @BranchId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdClaim_Get @CompanyId INT, @ClaimId INT
AS
BEGIN
    SET NOCOUNT ON;
    -- 1 claim
    SELECT c.*, CAST(c.ClaimAmount - c.SettledAmount - c.TdsAmount - c.DisallowedAmount AS DECIMAL(18,2)) AS Outstanding,
           b.BillNo, b.BillAt, b.Net AS BillNet, b.PayerAuthorised, b.CoPayPercent, b.CoPayAmount, b.Deductible, b.NonPayable, b.PayerShare,
           CAST(b.Net - b.PayerShare + b.PayerToPatient AS DECIMAL(18,2)) AS PatientShare,
           a.IpNo, a.AdmissionAt, a.DischargeAt, a.Status AS AdmissionStatus, pt.PatientCode, pt.PhoneNumber,
           LTRIM(RTRIM(CONCAT(NULLIF(pt.Salutation, '') + ' ', pt.FirstName, ' ', pt.LastName))) AS PatientName,
           ins.Name AS PayerName, ins.Type AS PayerKind, ins.ContactPerson AS PayerContact, ins.ContactNumber AS PayerPhone, ins.Email AS PayerEmail,
           pa.PreAuthNo, pa.ApprovedAmount, pa.FinalApprovedAmount, py.PolicyNo, py.MemberId, d.FullName AS ConsultantDoctorName,
           (SELECT COUNT(*) FROM dbo.IpdTpaChecklist k JOIN dbo.IpdTpaDocType t ON t.DocTypeId = k.DocTypeId WHERE k.ClaimId = c.ClaimId AND t.IsMandatory = 1 AND k.IsDone = 0) AS MissingDocs
    FROM dbo.IpdClaim c
    JOIN dbo.IpdBill b ON b.BillId = c.BillId
    JOIN dbo.IpdAdmission a ON a.AdmissionId = c.AdmissionId
    JOIN dbo.PatientMaster pt ON pt.PatientId = a.PatientId
    LEFT JOIN dbo.InsuranceTPAMaster ins ON ins.InsuranceTPA_ID = c.InsuranceTpaId
    LEFT JOIN dbo.IpdPreAuth pa ON pa.PreAuthId = c.PreAuthId
    LEFT JOIN dbo.IpdAdmissionPayer py ON py.AdmissionId = a.AdmissionId AND py.Seq = 1
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = a.ConsultantDoctorId
    WHERE c.ClaimId = @ClaimId AND c.CompanyId = @CompanyId;
    IF @@ROWCOUNT = 0 RETURN;
    -- 2 checklist
    SELECT t.DocTypeId, t.Name, t.Stage, t.IsMandatory, t.SortOrder, k.IsDone, k.Remarks, k.CheckedAt, u.FullName AS CheckedByName,
           k.DocumentId, d.FilePath AS DocumentPath, d.Title AS DocumentTitle
    FROM dbo.IpdTpaChecklist k JOIN dbo.IpdTpaDocType t ON t.DocTypeId = k.DocTypeId
    LEFT JOIN dbo.Users u ON u.Id = k.CheckedBy LEFT JOIN dbo.IpdDocument d ON d.DocumentId = k.DocumentId AND d.IsActive = 1
    WHERE k.ClaimId = @ClaimId ORDER BY t.SortOrder, t.Name;
    -- 3 events
    SELECT e.*, u.FullName AS CreatedByName FROM dbo.IpdClaimEvent e LEFT JOIN dbo.Users u ON u.Id = e.CreatedBy
    WHERE e.ClaimId = @ClaimId ORDER BY e.EventAt DESC, e.EventId DESC;
    -- 4 settlements
    SELECT s.*, u.FullName AS CreatedByName, uc.FullName AS CancelledByName,
           (SELECT VoucherNo FROM dbo.Acc_LedgerTransaction WHERE TransactionId = s.ReceiptTxnId) AS ReceiptVoucherNo,
           (SELECT VoucherNo FROM dbo.Acc_LedgerTransaction WHERE TransactionId = s.PatientTxnId) AS PatientVoucherNo
    FROM dbo.IpdClaimSettlement s LEFT JOIN dbo.Users u ON u.Id = s.CreatedBy LEFT JOIN dbo.Users uc ON uc.Id = s.CancelledBy
    WHERE s.ClaimId = @ClaimId ORDER BY s.SettledOn DESC, s.SettlementId DESC;
    -- 5 write-offs
    SELECT o.*, ur.FullName AS RequestedByName, ud.FullName AS DecidedByName FROM dbo.IpdClaimWriteOff o
    LEFT JOIN dbo.Users ur ON ur.Id = o.RequestedBy LEFT JOIN dbo.Users ud ON ud.Id = o.DecidedBy
    WHERE o.ClaimId = @ClaimId ORDER BY o.WriteOffId DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdClaim_Update @CompanyId INT, @BranchId INT, @UserId INT, @ClaimId INT, @TpaClaimRef NVARCHAR(60) = NULL, @Remarks NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.IpdClaim WHERE ClaimId = @ClaimId AND CompanyId = @CompanyId AND BranchId = @BranchId AND Status <> 'CANCELLED')
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'The claim was not found or is cancelled.' AS Error; RETURN; END;
    UPDATE dbo.IpdClaim SET TpaClaimRef = NULLIF(LTRIM(RTRIM(@TpaClaimRef)), N''), Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N''), ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE ClaimId = @ClaimId;
    SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error;
END
GO

-- submission: every mandatory document ticked; OPEN -> SUBMITTED
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdClaim_Submit
    @CompanyId INT, @BranchId INT, @UserId INT, @ClaimId INT, @SubmittedAt DATETIME = NULL, @Mode VARCHAR(20), @SubmissionRef NVARCHAR(100) = NULL, @Remarks NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE(), @msg NVARCHAR(600);
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @st VARCHAR(20), @billAt DATETIME, @no NVARCHAR(40);
        SELECT @st = c.Status, @billAt = b.BillAt, @no = c.ClaimNo FROM dbo.IpdClaim c WITH (UPDLOCK) JOIN dbo.IpdBill b ON b.BillId = c.BillId
        WHERE c.ClaimId = @ClaimId AND c.CompanyId = @CompanyId AND c.BranchId = @BranchId;
        IF @st IS NULL THROW 58060, 'The claim was not found in this branch.', 1;
        IF @st <> 'OPEN' THROW 58061, 'The claim is already submitted.', 1;
        SET @Mode = UPPER(LTRIM(RTRIM(@Mode)));
        IF @Mode NOT IN ('PORTAL', 'COURIER', 'EMAIL', 'HAND') THROW 58062, 'Choose how the claim is sent (portal, courier, e-mail or by hand).', 1;
        SET @SubmittedAt = ISNULL(@SubmittedAt, @now);
        IF @SubmittedAt > DATEADD(MINUTE, 5, @now) OR @SubmittedAt < DATEADD(DAY, -1, @billAt) THROW 58063, 'The submission date must be between the bill date and now.', 1;
        DECLARE @missing NVARCHAR(MAX) = (SELECT STRING_AGG(t.Name, N'; ') FROM dbo.IpdTpaChecklist k JOIN dbo.IpdTpaDocType t ON t.DocTypeId = k.DocTypeId
                                          WHERE k.ClaimId = @ClaimId AND t.IsMandatory = 1 AND k.IsDone = 0);
        IF @missing IS NOT NULL
        BEGIN
            SET @msg = LEFT(N'Tick or upload the mandatory documents first: ' + @missing, 600);
            THROW 58064, @msg, 1;
        END;
        UPDATE dbo.IpdClaim SET Status = 'SUBMITTED', SubmittedAt = @SubmittedAt, SubmissionMode = @Mode, SubmissionRef = NULLIF(LTRIM(RTRIM(@SubmissionRef)), N''),
               ModifiedBy = @UserId, ModifiedDate = @now WHERE ClaimId = @ClaimId;
        INSERT dbo.IpdClaimEvent (ClaimId, EventType, EventAt, RefNo, Remarks, CreatedBy)
        VALUES (@ClaimId, 'SUBMITTED', @SubmittedAt, NULLIF(LTRIM(RTRIM(@SubmissionRef)), N''), CONCAT(N'Sent by ', LOWER(@Mode), ISNULL(N' - ' + NULLIF(LTRIM(RTRIM(@Remarks)), N''), N'')), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @ClaimId AS ClaimId, @no AS ClaimNo;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END
GO

-- QUERY (TPA asks), QUERY_REPLY (answered, back to where it was), NOTE
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdClaim_Event
    @CompanyId INT, @BranchId INT, @UserId INT, @ClaimId INT, @EventType VARCHAR(20), @EventAt DATETIME = NULL, @RefNo NVARCHAR(100) = NULL, @Remarks NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @st VARCHAR(20), @prev VARCHAR(20), @now DATETIME = GETDATE();
    SELECT @st = Status, @prev = PrevStatus FROM dbo.IpdClaim WHERE ClaimId = @ClaimId AND CompanyId = @CompanyId AND BranchId = @BranchId;
    SET @EventType = UPPER(LTRIM(RTRIM(@EventType))); SET @Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N''); SET @EventAt = ISNULL(@EventAt, @now);
    IF @st IS NULL BEGIN SELECT CAST(0 AS BIT) AS Success, N'The claim was not found in this branch.' AS Error; RETURN; END;
    IF @EventType NOT IN ('QUERY', 'QUERY_REPLY', 'NOTE') BEGIN SELECT CAST(0 AS BIT) AS Success, N'Unknown claim step.' AS Error; RETURN; END;
    IF @EventAt > DATEADD(MINUTE, 5, @now) BEGIN SELECT CAST(0 AS BIT) AS Success, N'The time cannot be in the future.' AS Error; RETURN; END;
    IF @Remarks IS NULL BEGIN SELECT CAST(0 AS BIT) AS Success, N'Enter the remarks.' AS Error; RETURN; END;
    IF @EventType = 'QUERY' AND @st NOT IN ('SUBMITTED', 'PART_SETTLED') BEGIN SELECT CAST(0 AS BIT) AS Success, N'A query comes on a submitted claim.' AS Error; RETURN; END;
    IF @EventType = 'QUERY_REPLY' AND @st <> 'QUERY' BEGIN SELECT CAST(0 AS BIT) AS Success, N'There is no open query to reply to.' AS Error; RETURN; END;
    UPDATE dbo.IpdClaim SET Status = CASE @EventType WHEN 'QUERY' THEN 'QUERY' WHEN 'QUERY_REPLY' THEN ISNULL(@prev, 'SUBMITTED') ELSE Status END,
           PrevStatus = CASE @EventType WHEN 'QUERY' THEN @st WHEN 'QUERY_REPLY' THEN NULL ELSE PrevStatus END,
           ModifiedBy = @UserId, ModifiedDate = @now
    WHERE ClaimId = @ClaimId;
    INSERT dbo.IpdClaimEvent (ClaimId, EventType, EventAt, RefNo, Remarks, CreatedBy) VALUES (@ClaimId, @EventType, @EventAt, NULLIF(LTRIM(RTRIM(@RefNo)), N''), @Remarks, @UserId);
    SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error;
END
GO

-- settlement: amount received + TDS + disallowance (PATIENT = now payable by the patient, WRITEOFF = needs approval)
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdClaim_Settle
    @CompanyId INT, @BranchId INT, @UserId INT, @ClaimId INT, @SettledOn DATE, @Mode NVARCHAR(30) = NULL, @UtrNo NVARCHAR(60) = NULL,
    @Amount DECIMAL(18,2) = 0, @TdsAmount DECIMAL(18,2) = 0, @DisallowedAmount DECIMAL(18,2) = 0, @DisallowReason NVARCHAR(300) = NULL,
    @DisallowAction VARCHAR(10) = NULL, @Remarks NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE(), @msg NVARCHAR(600);
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @st VARCHAR(20), @out DECIMAL(18,2), @billAt DATETIME, @claimNo NVARCHAR(40), @adm INT;
        SELECT @st = c.Status, @out = c.ClaimAmount - c.SettledAmount - c.TdsAmount - c.DisallowedAmount, @billAt = b.BillAt, @claimNo = c.ClaimNo, @adm = c.AdmissionId
        FROM dbo.IpdClaim c WITH (UPDLOCK) JOIN dbo.IpdBill b ON b.BillId = c.BillId
        WHERE c.ClaimId = @ClaimId AND c.CompanyId = @CompanyId AND c.BranchId = @BranchId;
        IF @st IS NULL THROW 58070, 'The claim was not found in this branch.', 1;
        IF @st NOT IN ('SUBMITTED', 'QUERY', 'PART_SETTLED') THROW 58071, 'Settlements are entered on a submitted claim (submit it first).', 1;
        SET @Amount = ISNULL(@Amount, 0); SET @TdsAmount = ISNULL(@TdsAmount, 0); SET @DisallowedAmount = ISNULL(@DisallowedAmount, 0);
        IF @Amount < 0 OR @TdsAmount < 0 OR @DisallowedAmount < 0 THROW 58072, 'Amounts cannot be negative.', 1;
        IF @Amount + @TdsAmount + @DisallowedAmount <= 0 THROW 58073, 'Enter the amount received, TDS or the disallowed amount.', 1;
        IF @Amount <> ROUND(@Amount, 2) OR @TdsAmount <> ROUND(@TdsAmount, 2) OR @DisallowedAmount <> ROUND(@DisallowedAmount, 2) THROW 58074, 'Amounts can have at most two decimals.', 1;
        IF @Amount + @TdsAmount + @DisallowedAmount > @out
        BEGIN
            SET @msg = CONCAT(N'Received + TDS + disallowed (₹', FORMAT(@Amount + @TdsAmount + @DisallowedAmount, 'N2', 'en-IN'), N') is more than the claim outstanding ₹', FORMAT(@out, 'N2', 'en-IN'), N'.');
            THROW 58075, @msg, 1;
        END;
        IF @SettledOn IS NULL OR @SettledOn > CAST(@now AS DATE) OR @SettledOn < CAST(@billAt AS DATE) THROW 58076, 'The settlement date must be between the bill date and today.', 1;
        DECLARE @modeName NVARCHAR(100) = NULL;
        IF @Amount > 0
        BEGIN
            SET @modeName = (SELECT TOP 1 MethodName FROM dbo.PaymentMethodMaster WHERE IsActive = 1 AND (UPPER(MethodCode) = UPPER(@Mode) OR MethodName = @Mode) AND UPPER(MethodCode) NOT IN ('POINTS', 'WALLET'));
            IF @modeName IS NULL THROW 58077, 'Choose how the money came (NEFT, RTGS, cheque ...).', 1;
            IF NULLIF(LTRIM(RTRIM(@UtrNo)), N'') IS NULL THROW 58078, 'Enter the UTR / cheque number of the payment.', 1;
        END;
        SET @DisallowAction = NULLIF(UPPER(LTRIM(RTRIM(@DisallowAction))), '');
        IF @DisallowedAmount > 0 AND (@DisallowAction IS NULL OR @DisallowAction NOT IN ('PATIENT', 'WRITEOFF'))
            THROW 58079, 'Choose what happens to the disallowed amount: collect from the patient, or write off (needs approval).', 1;
        IF @DisallowedAmount > 0 AND NULLIF(LTRIM(RTRIM(@DisallowReason)), N'') IS NULL THROW 58080, 'Enter the TPA''s reason for the disallowance.', 1;
        IF @DisallowedAmount = 0 SET @DisallowAction = NULL;
        DECLARE @no NVARCHAR(40);
        EXEC dbo.usp_Ipd_NextNumber @BranchId = @BranchId, @DocType = 'TPS', @DocDate = @now, @DocNo = @no OUTPUT;
        INSERT dbo.IpdClaimSettlement (ClaimId, SettlementNo, SettledOn, Mode, UtrNo, Amount, TdsAmount, DisallowedAmount, DisallowReason, DisallowAction, Remarks, CreatedBy)
        VALUES (@ClaimId, @no, @SettledOn, @modeName, NULLIF(LTRIM(RTRIM(@UtrNo)), N''), @Amount, @TdsAmount, @DisallowedAmount, NULLIF(LTRIM(RTRIM(@DisallowReason)), N''),
                @DisallowAction, NULLIF(LTRIM(RTRIM(@Remarks)), N''), @UserId);
        DECLARE @sid INT = CAST(SCOPE_IDENTITY() AS INT), @t1 BIGINT, @t2 BIGINT, @wo INT = NULL;
        IF @Amount + @TdsAmount > 0 EXEC dbo.usp_Ipd_PostTpaLedger @Kind = 'SETTLE', @RefId = @sid, @UserId = @UserId, @TransactionId = @t1 OUTPUT;
        IF @DisallowAction = 'PATIENT' EXEC dbo.usp_Ipd_PostTpaLedger @Kind = 'TOPATIENT', @RefId = @sid, @UserId = @UserId, @TransactionId = @t2 OUTPUT;
        IF @DisallowAction = 'WRITEOFF'
        BEGIN
            INSERT dbo.IpdClaimWriteOff (ClaimId, SettlementId, Amount, Reason, RequestedBy) VALUES (@ClaimId, @sid, @DisallowedAmount, LTRIM(RTRIM(@DisallowReason)), @UserId);
            SET @wo = CAST(SCOPE_IDENTITY() AS INT);
            INSERT dbo.IpdClaimEvent (ClaimId, EventType, EventAt, Amount, Remarks, CreatedBy)
            VALUES (@ClaimId, 'WRITEOFF_REQUEST', @now, @DisallowedAmount, CONCAT(N'Write-off asked: ', LTRIM(RTRIM(@DisallowReason))), @UserId);
        END
        UPDATE dbo.IpdClaimSettlement SET ReceiptTxnId = @t1, PatientTxnId = @t2, WriteOffId = @wo WHERE SettlementId = @sid;
        INSERT dbo.IpdClaimEvent (ClaimId, EventType, EventAt, Amount, RefNo, Remarks, CreatedBy)
        VALUES (@ClaimId, 'SETTLEMENT', CAST(@SettledOn AS DATETIME), @Amount, NULLIF(LTRIM(RTRIM(@UtrNo)), N''),
                CONCAT(N'Settlement ', @no, N': received ₹', FORMAT(@Amount, 'N2', 'en-IN'), N', TDS ₹', FORMAT(@TdsAmount, 'N2', 'en-IN'),
                       CASE WHEN @DisallowedAmount > 0 THEN CONCAT(N', disallowed ₹', FORMAT(@DisallowedAmount, 'N2', 'en-IN'),
                                 CASE @DisallowAction WHEN 'PATIENT' THEN N' (to the patient)' ELSE N' (write-off asked)' END) ELSE N'' END), @UserId);
        EXEC dbo.usp_Ipd_ClaimRefresh @ClaimId = @ClaimId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@adm, 'TPA_SETTLE', CONCAT(N'Claim ', @claimNo, N' settlement ', @no, N' ₹', FORMAT(@Amount, 'N2', 'en-IN'),
                CASE WHEN @DisallowAction = 'PATIENT' THEN CONCAT(N'; ₹', FORMAT(@DisallowedAmount, 'N2', 'en-IN'), N' disallowed now payable by the patient') ELSE N'' END), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @sid AS SettlementId, @no AS SettlementNo, @wo AS WriteOffId,
               (SELECT Status FROM dbo.IpdClaim WHERE ClaimId = @ClaimId) AS ClaimStatus;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdClaim_SettlementCancel @CompanyId INT, @BranchId INT, @UserId INT, @SettlementId INT, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 58090, 'Enter the reason for cancelling the settlement.', 1;
        DECLARE @claim INT, @st VARCHAR(10), @t1 BIGINT, @t2 BIGINT, @wo INT, @no NVARCHAR(40), @adm INT;
        SELECT @claim = s.ClaimId, @st = s.Status, @t1 = s.ReceiptTxnId, @t2 = s.PatientTxnId, @wo = s.WriteOffId, @no = s.SettlementNo, @adm = c.AdmissionId
        FROM dbo.IpdClaimSettlement s WITH (UPDLOCK) JOIN dbo.IpdClaim c ON c.ClaimId = s.ClaimId
        WHERE s.SettlementId = @SettlementId AND c.CompanyId = @CompanyId AND c.BranchId = @BranchId;
        IF @claim IS NULL THROW 58091, 'The settlement was not found in this branch.', 1;
        IF @st <> 'POSTED' THROW 58092, 'The settlement is already cancelled.', 1;
        IF @wo IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.IpdClaimWriteOff WHERE WriteOffId = @wo AND Status = 'APPROVED')
            THROW 58093, 'The write-off of this settlement is already approved: it cannot be cancelled.', 1;
        DECLARE @r BIGINT, @why NVARCHAR(300) = CONCAT(N'TPA settlement ', @no, N' cancelled: ', LTRIM(RTRIM(@Reason)));
        IF @t1 IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction WHERE TransactionId = @t1 AND Status <> 'C')
            EXEC dbo.usp_Acc_CancelVoucher @TransactionId = @t1, @Reason = @why, @UserId = @UserId, @ReversalId = @r OUTPUT;
        IF @t2 IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction WHERE TransactionId = @t2 AND Status <> 'C')
            EXEC dbo.usp_Acc_CancelVoucher @TransactionId = @t2, @Reason = @why, @UserId = @UserId, @ReversalId = @r OUTPUT;
        IF @wo IS NOT NULL UPDATE dbo.IpdClaimWriteOff SET Status = 'CANCELLED', DecidedBy = @UserId, DecidedAt = @now, DecisionRemarks = N'Settlement cancelled' WHERE WriteOffId = @wo AND Status = 'PENDING';
        UPDATE dbo.IpdClaimSettlement SET Status = 'CANCELLED', CancelReason = LTRIM(RTRIM(@Reason)), CancelledBy = @UserId, CancelledAt = @now WHERE SettlementId = @SettlementId;
        INSERT dbo.IpdClaimEvent (ClaimId, EventType, EventAt, Remarks, CreatedBy) VALUES (@claim, 'SETTLEMENT_CANCEL', @now, @why, @UserId);
        -- back to submitted if nothing else is settled
        UPDATE dbo.IpdClaim SET Status = CASE WHEN Status = 'QUERY' THEN 'QUERY' ELSE 'SUBMITTED' END WHERE ClaimId = @claim AND Status IN ('SETTLED', 'PART_SETTLED');
        EXEC dbo.usp_Ipd_ClaimRefresh @ClaimId = @claim;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy) VALUES (@adm, 'TPA_SETTLE', @why, @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @claim AS ClaimId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END
GO

-- write-off decision (the web checks the Approval Matrix IPD.TPAWRITEOFF / the WRITEOFF_APPROVE control); maker never approves
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdClaim_WriteOffDecide @CompanyId INT, @BranchId INT, @UserId INT, @WriteOffId INT, @Approve BIT, @Remarks NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @claim INT, @st VARCHAR(10), @by INT, @amt DECIMAL(18,2), @claimNo NVARCHAR(40), @adm INT;
        SELECT @claim = o.ClaimId, @st = o.Status, @by = o.RequestedBy, @amt = o.Amount, @claimNo = c.ClaimNo, @adm = c.AdmissionId
        FROM dbo.IpdClaimWriteOff o WITH (UPDLOCK) JOIN dbo.IpdClaim c ON c.ClaimId = o.ClaimId
        WHERE o.WriteOffId = @WriteOffId AND c.CompanyId = @CompanyId AND c.BranchId = @BranchId;
        IF @claim IS NULL THROW 58100, 'The write-off request was not found in this branch.', 1;
        IF @st <> 'PENDING' THROW 58101, 'The write-off request is already decided.', 1;
        IF @by = @UserId THROW 58102, 'The person who asked for the write-off cannot approve or reject it.', 1;
        IF ISNULL(@Approve, 0) = 0 AND NULLIF(LTRIM(RTRIM(@Remarks)), N'') IS NULL THROW 58103, 'Enter the reason for rejecting the write-off.', 1;
        UPDATE dbo.IpdClaimWriteOff SET Status = CASE WHEN @Approve = 1 THEN 'APPROVED' ELSE 'REJECTED' END, DecidedBy = @UserId, DecidedAt = @now,
               DecisionRemarks = NULLIF(LTRIM(RTRIM(@Remarks)), N'') WHERE WriteOffId = @WriteOffId;
        IF @Approve = 1
        BEGIN
            DECLARE @t BIGINT;
            EXEC dbo.usp_Ipd_PostTpaLedger @Kind = 'WRITEOFF', @RefId = @WriteOffId, @UserId = @UserId, @TransactionId = @t OUTPUT;
            UPDATE dbo.IpdClaimWriteOff SET TxnId = @t WHERE WriteOffId = @WriteOffId;
        END
        -- a rejected write-off goes back to the outstanding (follow it up with the TPA)
        INSERT dbo.IpdClaimEvent (ClaimId, EventType, EventAt, Amount, Remarks, CreatedBy)
        VALUES (@claim, CASE WHEN @Approve = 1 THEN 'WRITEOFF_APPROVED' ELSE 'WRITEOFF_REJECTED' END, @now, @amt, NULLIF(LTRIM(RTRIM(@Remarks)), N''), @UserId);
        IF @Approve = 0 UPDATE dbo.IpdClaim SET Status = CASE WHEN Status = 'SETTLED' THEN 'PART_SETTLED' ELSE Status END WHERE ClaimId = @claim;
        EXEC dbo.usp_Ipd_ClaimRefresh @ClaimId = @claim;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@adm, 'TPA_WRITEOFF', CONCAT(N'Claim ', @claimNo, N': write-off of ₹', FORMAT(@amt, 'N2', 'en-IN'), CASE WHEN @Approve = 1 THEN N' approved' ELSE N' rejected' END), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @claim AS ClaimId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END
GO

-- ── TPA receivable ageing (outstanding of live claims by age of the bill / submission) ─────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdTpa_Ageing @CompanyId INT, @BranchId INT, @AsOf DATE = NULL, @InsuranceTpaId INT = NULL, @Basis VARCHAR(10) = 'BILL'
AS
BEGIN
    SET NOCOUNT ON;
    SET @AsOf = ISNULL(@AsOf, CAST(GETDATE() AS DATE));
    SELECT c.ClaimId, c.ClaimNo, c.Status, c.InsuranceTpaId, ins.Name AS PayerName, b.BillNo, b.BillAt, c.SubmittedAt, a.IpNo, pt.PatientCode,
           LTRIM(RTRIM(CONCAT(NULLIF(pt.Salutation, '') + ' ', pt.FirstName, ' ', pt.LastName))) AS PatientName, c.ClaimAmount,
           CAST(c.ClaimAmount - c.SettledAmount - c.TdsAmount - c.DisallowedAmount AS DECIMAL(18,2)) AS Outstanding,
           (SELECT ISNULL(SUM(o.Amount), 0) FROM dbo.IpdClaimWriteOff o WHERE o.ClaimId = c.ClaimId AND o.Status = 'PENDING') AS PendingWriteOff,
           DATEDIFF(DAY, CASE WHEN @Basis = 'SUBMIT' THEN ISNULL(c.SubmittedAt, b.BillAt) ELSE b.BillAt END, @AsOf) AS AgeDays
    INTO #c
    FROM dbo.IpdClaim c
    JOIN dbo.IpdBill b ON b.BillId = c.BillId
    JOIN dbo.IpdAdmission a ON a.AdmissionId = c.AdmissionId
    JOIN dbo.PatientMaster pt ON pt.PatientId = a.PatientId
    LEFT JOIN dbo.InsuranceTPAMaster ins ON ins.InsuranceTPA_ID = c.InsuranceTpaId
    WHERE c.CompanyId = @CompanyId AND c.BranchId = @BranchId AND c.Status <> 'CANCELLED' AND CAST(b.BillAt AS DATE) <= @AsOf
      AND (@InsuranceTpaId IS NULL OR c.InsuranceTpaId = @InsuranceTpaId)
      AND (c.ClaimAmount - c.SettledAmount - c.TdsAmount - c.DisallowedAmount > 0 OR EXISTS (SELECT 1 FROM dbo.IpdClaimWriteOff o WHERE o.ClaimId = c.ClaimId AND o.Status = 'PENDING'));
    -- 1 per TPA
    SELECT InsuranceTpaId, PayerName, COUNT(*) AS Claims, CAST(SUM(Outstanding) AS DECIMAL(18,2)) AS Outstanding,
           CAST(SUM(CASE WHEN AgeDays <= 30 THEN Outstanding ELSE 0 END) AS DECIMAL(18,2)) AS D0_30,
           CAST(SUM(CASE WHEN AgeDays BETWEEN 31 AND 60 THEN Outstanding ELSE 0 END) AS DECIMAL(18,2)) AS D31_60,
           CAST(SUM(CASE WHEN AgeDays BETWEEN 61 AND 90 THEN Outstanding ELSE 0 END) AS DECIMAL(18,2)) AS D61_90,
           CAST(SUM(CASE WHEN AgeDays BETWEEN 91 AND 180 THEN Outstanding ELSE 0 END) AS DECIMAL(18,2)) AS D91_180,
           CAST(SUM(CASE WHEN AgeDays > 180 THEN Outstanding ELSE 0 END) AS DECIMAL(18,2)) AS D180Plus,
           CAST(SUM(PendingWriteOff) AS DECIMAL(18,2)) AS PendingWriteOff, MAX(AgeDays) AS OldestDays
    FROM #c GROUP BY InsuranceTpaId, PayerName ORDER BY SUM(Outstanding) DESC;
    -- 2 claims
    SELECT *, CASE WHEN AgeDays <= 30 THEN '0-30' WHEN AgeDays <= 60 THEN '31-60' WHEN AgeDays <= 90 THEN '61-90' WHEN AgeDays <= 180 THEN '91-180' ELSE '180+' END AS Bucket
    FROM #c ORDER BY PayerName, AgeDays DESC;
END
GO

-- ── TPA statement (the receivable ledger of one TPA from the claims): opening, entries, running balance ────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdTpa_Statement @CompanyId INT, @BranchId INT, @InsuranceTpaId INT, @FromDate DATE, @ToDate DATE
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CAST(x.EntryDate AS DATE) AS EntryDate, x.Kind, x.DocNo, x.ClaimNo, x.BillNo, x.IpNo, x.PatientName, x.Narration, x.Debit, x.Credit, x.Seq
    INTO #e
    FROM (
        SELECT b.BillAt AS EntryDate, 'CLAIM' AS Kind, b.BillNo AS DocNo, c.ClaimNo, b.BillNo, a.IpNo,
               LTRIM(RTRIM(CONCAT(pt.FirstName, ' ', pt.LastName))) AS PatientName, N'Claim (TPA share of the final bill)' AS Narration,
               c.ClaimAmount AS Debit, CAST(0 AS DECIMAL(18,2)) AS Credit, 1 AS Seq
        FROM dbo.IpdClaim c JOIN dbo.IpdBill b ON b.BillId = c.BillId JOIN dbo.IpdAdmission a ON a.AdmissionId = c.AdmissionId JOIN dbo.PatientMaster pt ON pt.PatientId = a.PatientId
        WHERE c.CompanyId = @CompanyId AND c.BranchId = @BranchId AND c.InsuranceTpaId = @InsuranceTpaId AND c.Status <> 'CANCELLED'
        UNION ALL
        SELECT s.SettledOn, 'SETTLEMENT', s.SettlementNo, c.ClaimNo, b.BillNo, a.IpNo, LTRIM(RTRIM(CONCAT(pt.FirstName, ' ', pt.LastName))),
               CONCAT(N'Received', ISNULL(N' by ' + s.Mode, N''), ISNULL(N' UTR ' + s.UtrNo, N'')), 0, s.Amount, 2
        FROM dbo.IpdClaimSettlement s JOIN dbo.IpdClaim c ON c.ClaimId = s.ClaimId JOIN dbo.IpdBill b ON b.BillId = c.BillId
        JOIN dbo.IpdAdmission a ON a.AdmissionId = c.AdmissionId JOIN dbo.PatientMaster pt ON pt.PatientId = a.PatientId
        WHERE c.CompanyId = @CompanyId AND c.BranchId = @BranchId AND c.InsuranceTpaId = @InsuranceTpaId AND s.Status = 'POSTED' AND s.Amount > 0
        UNION ALL
        SELECT s.SettledOn, 'TDS', s.SettlementNo, c.ClaimNo, b.BillNo, a.IpNo, LTRIM(RTRIM(CONCAT(pt.FirstName, ' ', pt.LastName))), N'TDS deducted by the TPA', 0, s.TdsAmount, 3
        FROM dbo.IpdClaimSettlement s JOIN dbo.IpdClaim c ON c.ClaimId = s.ClaimId JOIN dbo.IpdBill b ON b.BillId = c.BillId
        JOIN dbo.IpdAdmission a ON a.AdmissionId = c.AdmissionId JOIN dbo.PatientMaster pt ON pt.PatientId = a.PatientId
        WHERE c.CompanyId = @CompanyId AND c.BranchId = @BranchId AND c.InsuranceTpaId = @InsuranceTpaId AND s.Status = 'POSTED' AND s.TdsAmount > 0
        UNION ALL
        SELECT s.SettledOn, 'TO_PATIENT', s.SettlementNo, c.ClaimNo, b.BillNo, a.IpNo, LTRIM(RTRIM(CONCAT(pt.FirstName, ' ', pt.LastName))),
               CONCAT(N'Disallowed, payable by the patient: ', s.DisallowReason), 0, s.DisallowedAmount, 4
        FROM dbo.IpdClaimSettlement s JOIN dbo.IpdClaim c ON c.ClaimId = s.ClaimId JOIN dbo.IpdBill b ON b.BillId = c.BillId
        JOIN dbo.IpdAdmission a ON a.AdmissionId = c.AdmissionId JOIN dbo.PatientMaster pt ON pt.PatientId = a.PatientId
        WHERE c.CompanyId = @CompanyId AND c.BranchId = @BranchId AND c.InsuranceTpaId = @InsuranceTpaId AND s.Status = 'POSTED' AND s.DisallowAction = 'PATIENT'
        UNION ALL
        SELECT o.DecidedAt, 'WRITE_OFF', CONCAT(N'WO-', o.WriteOffId), c.ClaimNo, b.BillNo, a.IpNo, LTRIM(RTRIM(CONCAT(pt.FirstName, ' ', pt.LastName))),
               CONCAT(N'Disallowance written off: ', o.Reason), 0, o.Amount, 5
        FROM dbo.IpdClaimWriteOff o JOIN dbo.IpdClaim c ON c.ClaimId = o.ClaimId JOIN dbo.IpdBill b ON b.BillId = c.BillId
        JOIN dbo.IpdAdmission a ON a.AdmissionId = c.AdmissionId JOIN dbo.PatientMaster pt ON pt.PatientId = a.PatientId
        WHERE c.CompanyId = @CompanyId AND c.BranchId = @BranchId AND c.InsuranceTpaId = @InsuranceTpaId AND o.Status = 'APPROVED'
    ) x;
    DECLARE @opening DECIMAL(18,2) = (SELECT ISNULL(SUM(Debit - Credit), 0) FROM #e WHERE EntryDate < @FromDate);
    -- 1 header
    SELECT @InsuranceTpaId AS InsuranceTpaId, (SELECT Name FROM dbo.InsuranceTPAMaster WHERE InsuranceTPA_ID = @InsuranceTpaId) AS PayerName, @FromDate AS FromDate, @ToDate AS ToDate,
           @opening AS Opening,
           CAST(ISNULL((SELECT SUM(Debit) FROM #e WHERE EntryDate BETWEEN @FromDate AND @ToDate), 0) AS DECIMAL(18,2)) AS Debits,
           CAST(ISNULL((SELECT SUM(Credit) FROM #e WHERE EntryDate BETWEEN @FromDate AND @ToDate), 0) AS DECIMAL(18,2)) AS Credits,
           CAST(@opening + ISNULL((SELECT SUM(Debit - Credit) FROM #e WHERE EntryDate BETWEEN @FromDate AND @ToDate), 0) AS DECIMAL(18,2)) AS Closing;
    -- 2 entries with the running balance
    SELECT EntryDate, Kind, DocNo, ClaimNo, BillNo, IpNo, PatientName, Narration, Debit, Credit,
           CAST(@opening + SUM(Debit - Credit) OVER (ORDER BY EntryDate, Seq, DocNo ROWS UNBOUNDED PRECEDING) AS DECIMAL(18,2)) AS Balance
    FROM #e WHERE EntryDate BETWEEN @FromDate AND @ToDate ORDER BY EntryDate, Seq, DocNo;
END
GO

-- ── Master > IPD Master > TPA Document Checklist ───────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdTpaDocType_List @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT t.DocTypeId, t.Name, t.Stage, t.IsMandatory, t.SortOrder, t.IsActive, t.ModifiedDate,
           (SELECT COUNT(*) FROM dbo.IpdTpaChecklist k WHERE k.DocTypeId = t.DocTypeId) AS TimesUsed
    FROM dbo.IpdTpaDocType t WHERE t.CompanyId = @CompanyId ORDER BY t.IsActive DESC, t.SortOrder, t.Name;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdTpaDocType_Save
    @CompanyId INT, @UserId INT, @DocTypeId INT = NULL, @Name NVARCHAR(150), @Stage VARCHAR(10), @IsMandatory BIT = 1, @SortOrder INT = 100, @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET @Name = NULLIF(LTRIM(RTRIM(@Name)), N''); SET @Stage = UPPER(LTRIM(RTRIM(@Stage)));
    IF @Name IS NULL BEGIN SELECT CAST(0 AS BIT) AS Success, N'Enter the document name.' AS Error; RETURN; END;
    IF @Stage NOT IN ('PREAUTH', 'CLAIM', 'BOTH') BEGIN SELECT CAST(0 AS BIT) AS Success, N'Choose when the document is needed (pre-auth, claim or both).' AS Error; RETURN; END;
    IF EXISTS (SELECT 1 FROM dbo.IpdTpaDocType WHERE CompanyId = @CompanyId AND Name = @Name AND DocTypeId <> ISNULL(@DocTypeId, 0))
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'A document with this name already exists.' AS Error; RETURN; END;
    IF ISNULL(@DocTypeId, 0) = 0
    BEGIN
        INSERT dbo.IpdTpaDocType (CompanyId, Name, Stage, IsMandatory, SortOrder, IsActive, CreatedBy) VALUES (@CompanyId, @Name, @Stage, ISNULL(@IsMandatory, 1), ISNULL(@SortOrder, 100), ISNULL(@IsActive, 1), @UserId);
        SET @DocTypeId = CAST(SCOPE_IDENTITY() AS INT);
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.IpdTpaDocType WHERE DocTypeId = @DocTypeId AND CompanyId = @CompanyId)
        BEGIN SELECT CAST(0 AS BIT) AS Success, N'The document type was not found.' AS Error; RETURN; END;
        UPDATE dbo.IpdTpaDocType SET Name = @Name, Stage = @Stage, IsMandatory = ISNULL(@IsMandatory, 1), SortOrder = ISNULL(@SortOrder, 100), IsActive = ISNULL(@IsActive, 1),
               ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE DocTypeId = @DocTypeId;
    END
    SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @DocTypeId AS DocTypeId;
END
GO

PRINT 'Script 2540 applied: IPD Insurance / TPA procedures.';
GO
