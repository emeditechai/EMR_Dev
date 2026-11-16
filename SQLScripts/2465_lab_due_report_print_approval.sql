-- ============================================================================================================
-- Migration: 2465_lab_due_report_print_approval.sql
-- LAB > Report Dispatch: printing the report of a B2C bill that still has a balance due, after approval.
--   * Hospital Settings > LAB "Allow Print Lab Report in Due" (2464) = No  -> unchanged: a bill with a due never prints.
--   * = Yes -> the Action menu offers "Send Approval for Due Report Print". The request goes to the approvers of the
--     Approval Matrix module "Due Report Print" (LAB.DUEREPORTPRINT; branch-wise set-up first, else company-wise), is
--     approved / sent back on Utility > Approval Dashboard, and once approved the report of that bill prints from
--     Report Dispatch.
--   ApprovalRequest.Action_Type gets 'PRINT' (nothing is applied to a master on approval).
--   usp_LabDuePrint_Submit    : records the request, returns it and the approvers to notify.
--   usp_LabDuePrint_GetStates : per bill, the setting and the newest request (for the list and the print check).
-- Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_ApprovalRequest_Action'
             AND definition NOT LIKE '%PRINT%')
    ALTER TABLE dbo.ApprovalRequest DROP CONSTRAINT CK_ApprovalRequest_Action;
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_ApprovalRequest_Action')
    ALTER TABLE dbo.ApprovalRequest ADD CONSTRAINT CK_ApprovalRequest_Action CHECK (Action_Type IN ('CREATE', 'UPDATE', 'PRINT'));
GO

MERGE dbo.ApprovalModule AS t
USING (VALUES ('LAB.DUEREPORTPRINT', N'Due Report Print', 40)) AS s (Module_Code, Module_Name, Sort_Order)
   ON t.Module_Code = s.Module_Code
WHEN MATCHED THEN UPDATE SET Module_Name = s.Module_Name
WHEN NOT MATCHED THEN INSERT (Module_Code, Module_Name, Sort_Order, IsActive) VALUES (s.Module_Code, s.Module_Name, s.Sort_Order, 1);
GO

-- ── the bill: branch, company, due and the branch setting ────────────────────────────────────────────────────
CREATE OR ALTER FUNCTION dbo.fn_LabDuePrint_Bill (@LabOrderId INT)
RETURNS TABLE
AS
RETURN
    SELECT lo.LabOrderId, lo.BillNo, lo.BranchId, bm.CompanyId, bm.BranchName,
           CAST(ISNULL(lo.IsB2B, 0) AS BIT) AS IsB2B,
           LTRIM(RTRIM(CONCAT(pm.FirstName, N' ', pm.LastName))) AS PatientName,
           ISNULL(ph.NetAmount, 0) AS NetAmount, ISNULL(ph.TotalPaid, 0) AS TotalPaid, ISNULL(ph.BalanceDue, 0) AS BalanceDue,
           CAST(ISNULL((SELECT TOP 1 hs.AllowPrintLabReportInDue FROM dbo.HospitalSettings hs
                         WHERE hs.BranchId = lo.BranchId AND hs.IsActive = 1 ORDER BY hs.Id DESC), 0) AS BIT) AS AllowPrintInDue
      FROM dbo.LabOrder lo
      JOIN dbo.Branchmaster bm ON bm.BranchID = lo.BranchId
      LEFT JOIN dbo.PatientMaster pm ON pm.PatientId = lo.PatientId
     OUTER APPLY (SELECT TOP 1 h.NetAmount, h.TotalPaid, h.BalanceDue
                    FROM dbo.PaymentHeader h
                   WHERE h.ModuleCode = 'LAB' AND h.ModuleRefId = lo.LabOrderId AND ISNULL(h.IsActive, 1) = 1
                   ORDER BY h.PaymentHeaderId DESC) ph
     WHERE lo.LabOrderId = @LabOrderId;
GO

-- ── submit ────────────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_LabDuePrint_Submit
    @LabOrderId INT,
    @UserId     INT,
    @Reason     NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Module VARCHAR(40) = 'LAB.DUEREPORTPRINT';
    DECLARE @BillNo NVARCHAR(100), @BranchId INT, @CompanyId INT, @BranchName NVARCHAR(200), @IsB2B BIT, @Patient NVARCHAR(300),
            @Net DECIMAL(18, 2), @Paid DECIMAL(18, 2), @Due DECIMAL(18, 2), @Allow BIT;

    SELECT @BillNo = BillNo, @BranchId = BranchId, @CompanyId = CompanyId, @BranchName = BranchName, @IsB2B = IsB2B, @Patient = PatientName,
           @Net = NetAmount, @Paid = TotalPaid, @Due = BalanceDue, @Allow = AllowPrintInDue
      FROM dbo.fn_LabDuePrint_Bill(@LabOrderId);

    DECLARE @Error NVARCHAR(400) =
        CASE WHEN @BranchId IS NULL THEN N'The bill was not found.'
             WHEN @IsB2B = 1 THEN N'A B2B bill prints without approval.'
             WHEN @Due <= 0 THEN N'The bill has no due: the report can be printed.'
             WHEN @Allow = 0 THEN N'Printing a report with a due is switched off for this branch (Hospital Settings > LAB > Allow Print Lab Report in Due).' END;

    DECLARE @MatrixId INT, @Scope CHAR(1);
    IF @Error IS NULL
    BEGIN
        SELECT TOP 1 @MatrixId = m.Matrix_ID, @Scope = m.Scope
          FROM dbo.ApprovalMatrix m
          JOIN dbo.ApprovalModule am ON am.Module_Code = m.Module_Code AND am.IsActive = 1
         WHERE m.CompanyId = @CompanyId AND m.Module_Code = @Module AND m.IsActive = 1
           AND (m.Scope = 'C' OR m.Branch_ID = @BranchId)
           AND EXISTS (SELECT 1 FROM dbo.ApprovalMatrixApprover a WHERE a.Matrix_ID = m.Matrix_ID)
         ORDER BY CASE m.Scope WHEN 'B' THEN 0 ELSE 1 END;
        IF @MatrixId IS NULL
            SET @Error = N'No approval flow is set up for Due Report Print. Ask an administrator to add it in Settings > Approval Matrix.';
        ELSE IF EXISTS (SELECT 1 FROM dbo.ApprovalRequest WHERE Module_Code = @Module AND Entity_ID = @LabOrderId AND Status = 'P')
            SET @Error = N'An approval request for this bill is already waiting.';
        ELSE IF (SELECT TOP 1 Status FROM dbo.ApprovalRequest WHERE Module_Code = @Module AND Entity_ID = @LabOrderId AND Status <> 'X' ORDER BY Request_ID DESC) = 'A'
            SET @Error = N'Printing this bill''s report is already approved.';
    END

    IF @Error IS NOT NULL
    BEGIN
        SELECT CAST(0 AS INT) AS Request_ID, @Error AS ErrorMessage, @BillNo AS BillNo, @Patient AS PatientName, @BranchId AS BranchId,
               @BranchName AS BranchName, CAST(NULL AS CHAR(1)) AS Scope, ISNULL(@Due, 0) AS BalanceDue;
        SELECT CAST(NULL AS INT) AS UserId WHERE 1 = 0;
        RETURN;
    END

    DECLARE @Fields NVARCHAR(MAX) = (
        SELECT f.Field, f.Value
          FROM (VALUES (1, N'Bill No', @BillNo),
                       (2, N'Patient', @Patient),
                       (3, N'Bill Amount', FORMAT(@Net, 'N2')),
                       (4, N'Paid', FORMAT(@Paid, 'N2')),
                       (5, N'Balance Due', FORMAT(@Due, 'N2')),
                       (6, N'Reason', ISNULL(NULLIF(LTRIM(RTRIM(@Reason)), N''), N'—'))) f (Seq, Field, Value)
         ORDER BY f.Seq
           FOR JSON PATH);

    INSERT dbo.ApprovalRequest (CompanyId, Branch_ID, Matrix_ID, Scope, Module_Code, Entity_ID, Entity_Name, Action_Type,
                                Requested_Active, Old_Values, New_Values, Payload, Status, Requested_By, Requested_Date, Remarks)
    VALUES (@CompanyId, @BranchId, @MatrixId, @Scope, @Module, @LabOrderId, LEFT(CONCAT(@BillNo, N' · ', @Patient), 200), 'PRINT',
            NULL, NULL, @Fields, NULL, 'P', @UserId, GETDATE(), NULL);
    DECLARE @Id INT = CAST(SCOPE_IDENTITY() AS INT);

    SELECT @Id AS Request_ID, CAST(NULL AS NVARCHAR(400)) AS ErrorMessage, @BillNo AS BillNo, @Patient AS PatientName, @BranchId AS BranchId,
           @BranchName AS BranchName, @Scope AS Scope, @Due AS BalanceDue;
    SELECT a.UserId FROM dbo.ApprovalMatrixApprover a WHERE a.Matrix_ID = @MatrixId AND a.UserId <> @UserId;
END
GO

-- ── states of bills (comma-separated LabOrderIds) ────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_LabDuePrint_GetStates
    @LabOrderIds NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT b.LabOrderId, b.AllowPrintInDue, b.BalanceDue, b.IsB2B,
           r.Request_ID, r.Status, r.Remarks, r.Requested_Date, r.Actioned_Date,
           COALESCE(NULLIF(rb.FullName, ''), rb.Username) AS RequestedByName,
           COALESCE(NULLIF(ab.FullName, ''), ab.Username) AS ActionedByName
      FROM (SELECT DISTINCT TRY_CAST(value AS INT) AS Id FROM STRING_SPLIT(@LabOrderIds, ',')) ids
     CROSS APPLY dbo.fn_LabDuePrint_Bill(ids.Id) b
     OUTER APPLY (SELECT TOP 1 x.Request_ID, x.Status, x.Remarks, x.Requested_Date, x.Actioned_Date, x.Requested_By, x.Actioned_By
                    FROM dbo.ApprovalRequest x
                   WHERE x.Module_Code = 'LAB.DUEREPORTPRINT' AND x.Entity_ID = b.LabOrderId AND x.Status <> 'X'
                   ORDER BY x.Request_ID DESC) r
      LEFT JOIN dbo.Users rb ON rb.Id = r.Requested_By
      LEFT JOIN dbo.Users ab ON ab.Id = r.Actioned_By
     WHERE ids.Id IS NOT NULL;
END
GO

-- ── permission: "Send Approval for Due Report Print" goes with the page's report-print permission (no new grant) ──
DECLARE @page INT, @ctl INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'LAB.LABREPORTDISPATCH';
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = (SELECT TOP 1 Control_ID FROM dbo.PageEndpointMap WHERE Page_ID = @page AND Action = N'PrintReportPdf');
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST',
         @Controller = N'LabReportDispatch', @Action = N'RequestDuePrint', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2465 applied: Due Report Print approval (Approval Matrix module LAB.DUEREPORTPRINT).';
GO
