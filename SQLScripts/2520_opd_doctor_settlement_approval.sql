-- ============================================================================================================
-- Migration: 2520_opd_doctor_settlement_approval.sql   (application database)
-- OPD > Doctor Commission & Disbursals under the Approval Matrix: module 'OPD.DOCTORSETTLEMENT' ("OPD Doctor Share
-- Settlement"). When the matrix has a set-up for it (branch-wise, else company-wise), a prepared settlement is approved
-- only on Utility > Approval Dashboard by the matrix's approvers (Approve = the settlement is approved, Send back = it is
-- rejected and its shares go back to be settled); the page's own Approve / Reject is then refused. Without a set-up the
-- page works as before (maker-checker on the page).
--   ApprovalRequest.Action_Type gets 'SETTLE' (the request is applied by the doctor payout procedures, not to a master).
-- Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_ApprovalRequest_Action'
           AND OBJECT_DEFINITION(object_id) NOT LIKE N'%SETTLE%')
    ALTER TABLE dbo.ApprovalRequest DROP CONSTRAINT CK_ApprovalRequest_Action;
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_ApprovalRequest_Action')
    ALTER TABLE dbo.ApprovalRequest ADD CONSTRAINT CK_ApprovalRequest_Action CHECK (Action_Type IN ('CREATE', 'UPDATE', 'PRINT', 'SETTLE'));
GO
MERGE dbo.ApprovalModule AS t
USING (VALUES ('OPD.DOCTORSETTLEMENT', N'OPD Doctor Share Settlement', 200)) s (Code, Name, Sort)
ON t.Module_Code = s.Code
WHEN NOT MATCHED THEN INSERT (Module_Code, Module_Name, Sort_Order, IsActive) VALUES (s.Code, s.Name, s.Sort, 1);
GO
PRINT 'Script 2520 applied: OPD Doctor Share Settlement under the Approval Matrix.';
GO
