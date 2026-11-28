-- 2576: IPD flow-gap fixes - pre-auth room-rent limits, reads, authorization (2026-11-28). Needs 2570-2575. Safe to re-run.
-- No grants are seeded: give the new controls in Role Permissions.
--   IPD Patient (IPD.PATIENT) new controls:
--     DISCOUNT_HIGH       discount above Hospital Settings IpdDiscountLimitPercent (bill / settlement)
--     INTERIM_BILL        print an interim bill during the stay
--     BILL_ADJUST         supplementary bill / credit note after the discharge;  BILL_ADJUST_CANCEL  cancel one
--     GATEPASS_STALE_BILL gate pass on a bill made before bed days still running (with a reason)
--     DISCHARGE_REOPEN    reopen a gate pass (within IpdReopenHours)
--     ALLERGY             record the allergy status;  CODE_STATUS  code status (DNR / DNI / limited);  ISOLATION  isolation flag
--     ORDER_VERIFY        pharmacist verification / query of medicine orders
--     ESCALATE            call the doctor / close an escalation;  ESCALATION_ACK  doctor's acknowledgement with the response
--     MED_RECON           medication reconciliation;  TRANSFUSION  blood transfusion steps;  RESTRAINT  restraint order / checks
--     NEWBORN             link a newborn to the mother's admission
--   Pages: IPD > Credit Dues (IPD.CREDITDUES), IPD > Medicine Verification (IPD.MEDVERIFY).
-- REPLACES usp_Api_IpdPreAuth_SetSplit (2540) with the room-rent limits (A9). Errors 59690-59699.
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO
-- ── A9: room-rent eligibility with the patient share (live + 2576) ──
-- ── the patient's share as per the policy: co-pay %, deductible, non-payables (used by the final bill) ─────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPreAuth_SetSplit
    @CompanyId INT, @BranchId INT, @UserId INT, @PreAuthId INT, @CoPayPercent DECIMAL(5,2) = 0, @Deductible DECIMAL(18,2) = 0, @NonPayable DECIMAL(18,2) = 0, @Remarks NVARCHAR(300) = NULL,
    @RoomRentLimit DECIMAL(18,2) = NULL, @IcuRentLimit DECIMAL(18,2) = NULL
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
    IF ISNULL(@RoomRentLimit, 0) < 0 OR ISNULL(@IcuRentLimit, 0) < 0 BEGIN SELECT CAST(0 AS BIT) AS Success, N'The room-rent limits cannot be negative.' AS Error; RETURN; END;
    UPDATE dbo.IpdPreAuth SET CoPayPercent = ISNULL(@CoPayPercent, 0), Deductible = ISNULL(@Deductible, 0), NonPayable = ISNULL(@NonPayable, 0),
           SplitRemarks = NULLIF(LTRIM(RTRIM(@Remarks)), N''), RoomRentLimit = NULLIF(@RoomRentLimit, 0), IcuRentLimit = NULLIF(@IcuRentLimit, 0), ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE PreAuthId = @PreAuthId;
    INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
    VALUES (@adm, 'PREAUTH', CONCAT(N'Pre-auth ', @no, N': patient share set - co-pay ', FORMAT(ISNULL(@CoPayPercent, 0), '0.##'), N' %, deductible ₹', FORMAT(ISNULL(@Deductible, 0), 'N2', 'en-IN'),
            N', non-payables ₹', FORMAT(ISNULL(@NonPayable, 0), 'N2', 'en-IN'),
            CASE WHEN ISNULL(@RoomRentLimit, 0) > 0 THEN N', room rent limit ₹' + FORMAT(@RoomRentLimit, 'N0', 'en-IN') + N'/day' ELSE N'' END,
            CASE WHEN ISNULL(@IcuRentLimit, 0) > 0 THEN N', ICU limit ₹' + FORMAT(@IcuRentLimit, 'N0', 'en-IN') + N'/day' ELSE N'' END), @UserId);
    SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @PreAuthId AS PreAuthId;
END
GO

-- ── reads ────────────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdRecordGaps @CompanyId INT, @AdmissionId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId) RETURN;
    SELECT Sort, Owner, Message FROM dbo.fn_Ipd_RecordGaps(@AdmissionId) ORDER BY Sort;
    SELECT Sort, Kind, Message FROM dbo.fn_Ipd_FinalBillBlockers(@AdmissionId) WHERE (SELECT BillId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId) IS NULL ORDER BY Sort;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdCodeStatus_History @CompanyId INT, @AdmissionId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT l.LogId, l.CodeStatus, l.DiscussedWith, l.Relation, l.Reason, l.Limits, l.RecordedAt, d.FullName AS DoctorName, u.FullName AS RecordedByName
    FROM dbo.IpdCodeStatusLog l JOIN dbo.IpdAdmission a ON a.AdmissionId = l.AdmissionId AND a.CompanyId = @CompanyId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = l.DoctorId LEFT JOIN dbo.Users u ON u.Id = l.RecordedBy
    WHERE l.AdmissionId = @AdmissionId ORDER BY l.LogId DESC;
END;
GO

-- ── 1. IPD Patient: new controls and the endpoints of IpdGaps ───────────────────────────────────────────────
DECLARE @pp INT = (SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'IPD.PATIENT' AND CompanyId = 1), @pv INT, @ctl INT, @a NVARCHAR(60);
IF @pp IS NULL THROW 51500, 'Page IPD.PATIENT is missing (SQLScripts/2424).', 1;
SELECT @pv = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @pp AND Control_Code = 'VIEW';
-- reads of the workspace (VIEW); EscalationAction checks ESCALATE / ESCALATION_ACK in the controller
DECLARE v CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(N'BillAdjustments,PrintBillAdjustment,MedCheck,CodeStatus,Escalations,MedRecon,RecordGaps,Safety', ',');
OPEN v; FETCH NEXT FROM v INTO @a;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @pv, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdGaps', @Action = @a, @Source = 'SEED';
    FETCH NEXT FROM v INTO @a;
END
CLOSE v; DEALLOCATE v;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @pv, @App = 'WEB', @Http_Method = 'POST', @Controller = N'IpdGaps', @Action = N'EscalationAction', @Source = 'SEED';

DECLARE @c TABLE (Code VARCHAR(30), Title NVARCHAR(150), Sort INT, Method VARCHAR(6), Acts NVARCHAR(300));
INSERT @c VALUES
    ('DISCOUNT_HIGH',       N'Give a discount above the branch''s limit (Hospital Settings > IPD discount limit %)', 150, 'POST', N''),
    ('INTERIM_BILL',        N'Print an interim bill during the stay', 151, 'GET', N'InterimBill'),
    ('BILL_ADJUST',         N'Supplementary bill / credit note after the discharge', 152, 'POST', N'SaveBillAdjustment'),
    ('BILL_ADJUST_CANCEL',  N'Cancel a supplementary bill / credit note', 153, 'POST', N'CancelBillAdjustment'),
    ('GATEPASS_STALE_BILL', N'Gate pass on an older bill (bed days after the bill time not charged, with a reason)', 154, 'POST', N''),
    ('DISCHARGE_REOPEN',    N'Reopen a gate pass (patient did not leave / discharged by mistake)', 155, 'POST', N'ReopenDischarge'),
    ('ALLERGY',             N'Record the allergy status of the patient', 156, 'POST', N'SaveAllergy'),
    ('CODE_STATUS',         N'Record the code status (Full / DNR / DNI / limited treatment)', 157, 'POST', N'SaveCodeStatus'),
    ('ISOLATION',           N'Start / end isolation (contact, droplet, airborne, protective)', 158, 'POST', N'SaveIsolation'),
    ('ORDER_VERIFY',        N'Pharmacist: verify / query medicine orders', 159, 'POST', N'VerifyOrder'),
    ('ESCALATE',            N'Call the doctor (escalation) and close an acknowledged escalation', 160, 'POST', N''),
    ('ESCALATION_ACK',      N'Doctor: acknowledge an escalation with the response', 161, 'POST', N''),
    ('MED_RECON',           N'Medication reconciliation (admission / discharge)', 162, 'POST', N'SaveMedRecon'),
    ('TRANSFUSION',         N'Blood transfusion: order, bedside check, start, vitals, complete / reaction', 163, 'POST', N'SaveTransfusion'),
    ('RESTRAINT',           N'Restraint: order, 2-hourly checks, renew, release', 164, 'POST', N'SaveRestraint'),
    ('NEWBORN',             N'Link a newborn''s admission to the mother''s', 165, 'POST', N'LinkNewborn');
DECLARE @cc VARCHAR(30), @ct NVARCHAR(150), @cs INT, @cm VARCHAR(6), @ca NVARCHAR(300), @one NVARCHAR(60);
DECLARE k CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Sort, Method, Acts FROM @c;
OPEN k; FETCH NEXT FROM k INTO @cc, @ct, @cs, @cm, @ca;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @pp, @Control_Code = @cc, @Title = @ct, @Sort_Order = @cs, @Control_ID = @ctl OUTPUT;
    DECLARE e CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(@ca, ',') WHERE value <> N'';
    OPEN e; FETCH NEXT FROM e INTO @one;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @ctl, @App = 'WEB', @Http_Method = @cm, @Controller = N'IpdGaps', @Action = @one, @Source = 'SEED';
        FETCH NEXT FROM e INTO @one;
    END
    CLOSE e; DEALLOCATE e;
    FETCH NEXT FROM k INTO @cc, @ct, @cs, @cm, @ca;
END
CLOSE k; DEALLOCATE k;
GO

-- ── 2. IPD > Credit Dues and IPD > Medicine Verification ────────────────────────────────────────────────────
DECLARE @co INT = 1, @nav INT, @page INT, @view INT, @a NVARCHAR(60), @ver INT;
SELECT @nav = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = N'IPD' AND CompanyId = 1;
IF @nav IS NULL THROW 51501, 'Menu IPD is missing (SQLScripts/2424).', 1;
EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @nav, @Page_Code = N'IPD.CREDITDUES', @Title = N'Credit Dues', @Controller = N'IpdGaps', @Action = N'CreditDues',
     @Show_In_Menu = 1, @Sort_Order = 31, @Icon = N'bi bi-hourglass-split me-2', @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
IF @view IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'VIEW', @Title = N'Open page', @Sort_Order = 10, @Control_ID = @view OUTPUT;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdGaps', @Action = N'CreditDues', @Source = 'SEED';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdGaps', @Action = N'CreditDuesData', @Source = 'SEED';

SET @page = NULL; SET @view = NULL;
EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @nav, @Page_Code = N'IPD.MEDVERIFY', @Title = N'Medicine Verification', @Controller = N'IpdGaps', @Action = N'VerifyQueue',
     @Show_In_Menu = 1, @Sort_Order = 27, @Icon = N'bi bi-patch-check me-2', @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
IF @view IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'VIEW', @Title = N'Open page', @Sort_Order = 10, @Control_ID = @view OUTPUT;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdGaps', @Action = N'VerifyQueue', @Source = 'SEED';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdGaps', @Action = N'VerifyQueueData', @Source = 'SEED';
EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'VERIFY', @Title = N'Verify / query medicine orders', @Sort_Order = 20, @Control_ID = @ver OUTPUT;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ver, @App = 'WEB', @Http_Method = 'POST', @Controller = N'IpdGaps', @Action = N'QueueVerify', @Source = 'SEED';

-- the open escalations of the branch on IPD > Nursing Station
DECLARE @ns INT = (SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'IPD.NURSINGSTATION' AND CompanyId = 1), @nsv INT;
SELECT @nsv = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @ns AND Control_Code = 'VIEW';
IF @nsv IS NOT NULL
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @ns, @Control_ID = @nsv, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdGaps', @Action = N'OpenEscalations', @Source = 'SEED';
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT '2576 IPD flow-gap pages and controls - done.';
GO
