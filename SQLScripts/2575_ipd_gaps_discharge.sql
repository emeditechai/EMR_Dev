-- 2575: IPD flow-gap fixes - discharge, banner, bed board (2026-11-28). Needs 2570-2574. Run LAST of 2570-2576. Safe to re-run.
--   A2  the gate pass refuses a bill that stopped before bed days still running (Cancel and bill again, or "Gate pass on an old bill"
--       right with a reason)
--   B9  the gate pass stops running orders, infusions, devices, restraints; closes escalations and open cross-consultations
--   C1  the final bill needs the MLC police intimation (police station, time informed)
--   A8 / A10 / B5 / B6 / B11 / C2 / C4 / C5 / C6  banner alerts (usp_Api_IpdAdmission_Get) and the bed board (isolation, code status)
-- REPLACES fn_Ipd_FinalBillBlockers (2571), fn_Ipd_DischargeState, usp_Api_IpdDischarge_GatePass (2557), usp_Api_IpdAdmission_Get,
-- usp_Api_IpdBed_Board (2541): re-run 2575 after 2541 / 2557 / 2571. Errors 59680-59699.
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ── A3 + C1: what blocks the final bill ─────────────────────────────────────────────────────────────────────
CREATE OR ALTER FUNCTION dbo.fn_Ipd_FinalBillBlockers (@AdmissionId INT)
RETURNS TABLE
AS RETURN
(
    SELECT 5 AS Sort, 'MLC' AS Kind, CAST(N'Medico-legal case: record the police intimation (police station and the time informed) on Edit admission > MLC before the final bill.' AS NVARCHAR(400)) AS Message
    FROM dbo.IpdAdmission a LEFT JOIN dbo.IpdMlc m ON m.AdmissionId = a.AdmissionId
    WHERE a.AdmissionId = @AdmissionId AND a.IsMlc = 1 AND (NULLIF(LTRIM(RTRIM(m.PoliceStation)), N'') IS NULL OR m.InformedAt IS NULL)
    UNION ALL
    SELECT 10, 'OT', CAST(CONCAT(N'Surgery ', o.BookingNo, N' is completed but its OT charges are not posted: post them on the OT tab.') AS NVARCHAR(400))
    FROM dbo.IpdOtBooking o
    WHERE o.AdmissionId = @AdmissionId AND o.Status = 'COMPLETED'
      AND NOT EXISTS (SELECT 1 FROM dbo.IpdCharge c WHERE c.RefKind = 'OTB' AND c.RefId = o.OtBookingId AND c.Status = 'POSTED')
    UNION ALL
    SELECT 20, 'OT', CAST(CONCAT(N'Surgery ', o.BookingNo, N' is scheduled or in progress: complete or cancel it first.') AS NVARCHAR(400))
    FROM dbo.IpdOtBooking o WHERE o.AdmissionId = @AdmissionId AND o.Status IN ('SCHEDULED', 'IN_OT')
    UNION ALL
    SELECT 30, 'INDENT', CAST(CONCAT(N'Medicine indent ', i.IndentNo, N' is still open: issue or cancel it on the Medicines tab.') AS NVARCHAR(400))
    FROM dbo.IpdPhIndent i WHERE i.AdmissionId = @AdmissionId AND i.Status IN ('PENDING', 'PARTIAL')
    UNION ALL
    SELECT 40, 'DEVICE', CAST(CONCAT(N'ICU device ', d.HeadName, N' is still running: stop it on the ICU tab (device days are billed up to the stop).') AS NVARCHAR(400))
    FROM dbo.IpdIcuDevice d WHERE d.AdmissionId = @AdmissionId AND d.Status = 'ACTIVE' AND d.StopAt IS NULL
    UNION ALL
    SELECT 50, 'ORDER', CAST(CONCAT(N'"', o.ServiceName, N'" is ordered and not marked done: mark it done (it is charged then) or cancel it on the Clinical tab.') AS NVARCHAR(400))
    FROM dbo.IpdOrder o WHERE o.AdmissionId = @AdmissionId AND o.OrderType = 'SERVICE' AND o.Status = 'ACTIVE' AND o.DoneAt IS NULL
);
GO

-- ── discharge state (live + 2575) ──
-- ── 2. the state of one admission's discharge (read by the tab, the board and the gate pass) ─────────────────
CREATE OR ALTER FUNCTION dbo.fn_Ipd_DischargeState (@AdmissionId INT)
RETURNS TABLE
AS RETURN
(
    SELECT a.AdmissionId, d.DischargeId, d.DischargeType, d.Status AS DischargeStatus, d.AdvisedAt, d.PlannedAt, d.ClearedAt, d.GatePassAt,
           b.BillId, b.BillNo, b.BillAt,
           CAST(CASE WHEN b.BillId IS NULL THEN NULL ELSE (b.Net - b.PayerShare + b.PayerToPatient) + (SELECT AdjNet FROM dbo.fn_Ipd_PostBillAdj(a.AdmissionId)) - mo.NetAdvance END AS DECIMAL(18,2)) AS PatientBalance,
           (SELECT COUNT(*) FROM dbo.IpdPhIndent i WHERE i.AdmissionId = a.AdmissionId AND i.Status IN ('PENDING', 'PARTIAL')) AS OpenIndents,
           lab.LabNotCollected, lab.LabPending,
           (SELECT TOP 1 pa.Status FROM dbo.IpdPreAuth pa WHERE pa.AdmissionId = a.AdmissionId AND pa.IsLive = 1
              AND pa.Status IN ('REQUESTED', 'QUERY', 'ENHANCE_REQUESTED', 'FINAL_REQUESTED') ORDER BY pa.PreAuthId DESC) AS TpaWaiting,
           (SELECT COUNT(*) FROM dbo.IpdOtBooking o WHERE o.AdmissionId = a.AdmissionId AND o.Status IN ('SCHEDULED', 'IN_OT')) AS OpenOt,
           (SELECT COUNT(*) FROM dbo.IpdDischargeClearance c WHERE c.DischargeId = d.DischargeId AND c.Status = 'PENDING') AS ClearancesPending,
           s.SummaryId AS SignedSummaryId, s.SignedAt AS SummarySignedAt,
           (SELECT TOP 1 1 FROM dbo.IpdDischargeSummary x WHERE x.AdmissionId = a.AdmissionId AND x.Status = 'DRAFT') AS HasDraft,
           (SELECT TOP 1 l.LamaId FROM dbo.IpdLamaRecord l WHERE l.DischargeId = d.DischargeId AND l.IsActive = 1) AS LamaId,
           (SELECT TOP 1 r.DeathId FROM dbo.IpdDeathRecord r WHERE r.AdmissionId = a.AdmissionId AND r.IsActive = 1) AS DeathId,
           (SELECT MAX(v.CreatedDate) FROM dbo.IpdAdvance v WHERE v.AdmissionId = a.AdmissionId AND v.IsActive = 1 AND b.BillAt IS NOT NULL AND v.CreatedDate >= b.BillAt) AS LastPaymentAfterBill,
           (SELECT TOP 1 ISNULL(k.CompletedAt, k.RequestedAt) FROM dbo.IpdBedCleaning k WHERE k.AdmissionId = a.AdmissionId AND k.Reason = 'DISCHARGE' ORDER BY k.CleaningTaskId DESC) AS BedCleaningAt,
           (SELECT TOP 1 k.CompletedAt FROM dbo.IpdBedCleaning k WHERE k.AdmissionId = a.AdmissionId AND k.Reason = 'DISCHARGE' ORDER BY k.CleaningTaskId DESC) AS BedReadyAt,
           ISNULL((SELECT TOP 1 hs.IpdDischargeTatTargetMinutes FROM dbo.HospitalSettings hs WHERE hs.BranchID = a.BranchId ORDER BY hs.Id DESC), 180) AS TatTargetMinutes,
           a.BillUpToAt,   -- 2575 (A2) bed days run since the bill time; (B8) record gaps
           CAST(CASE WHEN b.BillId IS NOT NULL AND a.IsOpen = 1 AND a.BillUpToAt IS NOT NULL
                     THEN (SELECT COUNT(*) FROM dbo.fn_Ipd_BedDays(a.AdmissionId, GETDATE())) - (SELECT COUNT(*) FROM dbo.fn_Ipd_BedDays(a.AdmissionId, a.BillUpToAt)) ELSE 0 END AS INT) AS StaleBillDays,
           (SELECT COUNT(*) FROM dbo.fn_Ipd_RecordGaps(a.AdmissionId) g WHERE g.Owner = 'DOCTOR') AS DoctorGaps,
           (SELECT COUNT(*) FROM dbo.fn_Ipd_RecordGaps(a.AdmissionId) g WHERE g.Owner = 'NURSING') AS NursingGaps
    FROM dbo.IpdAdmission a
    OUTER APPLY (SELECT TOP 1 * FROM dbo.IpdDischarge x WHERE x.AdmissionId = a.AdmissionId AND x.Status <> 'CANCELLED' ORDER BY x.DischargeId DESC) d
    LEFT JOIN dbo.IpdBill b ON b.BillId = a.BillId AND b.Status = 'FINAL'
    OUTER APPLY dbo.fn_Ipd_Money(a.AdmissionId) mo
    OUTER APPLY (SELECT TOP 1 x.SummaryId, x.SignedAt FROM dbo.IpdDischargeSummary x WHERE x.AdmissionId = a.AdmissionId AND x.Status = 'SIGNED') s
    OUTER APPLY (SELECT SUM(CASE WHEN ISNULL(st.Collected, 0) = 0 AND ISNULL(st.Entered, 0) = 0 THEN 1 ELSE 0 END) AS LabNotCollected,
                        SUM(CASE WHEN ISNULL(st.ReportLevel, 0) < 3 THEN 1 ELSE 0 END) AS LabPending
                 FROM dbo.LabOrder lo JOIN dbo.LabOrderItem li ON li.LabOrderId = lo.LabOrderId AND li.IsActive = 1
                 OUTER APPLY dbo.fn_Ipd_LabItemStatus(li.LabOrderItemId) st
                 WHERE lo.AdmissionId = a.AdmissionId) lab
    WHERE a.AdmissionId = @AdmissionId
);
GO

-- ── gate pass (live + 2575: A2 old bill, B9 close what runs) ──
-- ── 9. gate pass: the patient leaves, the admission closes and the bed goes to housekeeping ───────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdDischarge_GatePass
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @HandedOverTo NVARCHAR(150) = NULL, @HandedOverRelation NVARCHAR(50) = NULL,
    @HandedOverPhone NVARCHAR(20) = NULL, @TransportMode NVARCHAR(40) = NULL, @Remarks NVARCHAR(500) = NULL,
    @Credit BIT = 0, @CreditReason NVARCHAR(300) = NULL, @CanCredit BIT = 0,
    @CanStaleBill BIT = 0, @StaleBillReason NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @open BIT, @status VARCHAR(20), @bed INT;
        SELECT @open = IsOpen, @status = Status, @bed = CurrentBedId FROM dbo.IpdAdmission WITH (UPDLOCK)
        WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @open IS NULL THROW 58400, 'The admission was not found in this branch.', 1;
        IF @open = 0 THROW 58500, 'The patient is already discharged.', 1;
        DECLARE @id INT, @type VARCHAR(12);
        SELECT @id = DischargeId, @type = DischargeType FROM dbo.IpdDischarge WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND Status = 'ADVISED';
        IF @id IS NULL THROW 58501, 'Advise the discharge first.', 1;
        IF @status <> 'BILL_FINAL' THROW 58502, 'Make the final bill (Billing tab) before the gate pass.', 1;
        DECLARE @bal DECIMAL(18,2), @clr INT, @ot INT, @sum INT, @lama INT, @death INT;
        SELECT @bal = ISNULL(PatientBalance, 0), @clr = ClearancesPending, @ot = OpenOt, @sum = SignedSummaryId, @lama = LamaId, @death = DeathId
        FROM dbo.fn_Ipd_DischargeState(@AdmissionId);
        IF @clr > 0 THROW 58503, 'Some clearances are pending (pharmacy, LAB, nursing, TPA).', 1;
        IF @ot > 0 THROW 58504, 'An OT booking is scheduled or in progress: complete or cancel it first.', 1;
        IF @type IN ('NORMAL', 'TRANSFER', 'DEATH') AND @sum IS NULL
            THROW 58505, 'The discharge summary must be signed by the consultant before the gate pass.', 1;
        IF @type IN ('LAMA', 'DAMA') AND @lama IS NULL THROW 58506, 'Record the LAMA / DAMA form with the signatures before the gate pass.', 1;
        IF @type = 'DEATH' AND @death IS NULL THROW 58507, 'Record the death (cause of death, certifying doctor) before the gate pass.', 1;
        -- 2575 (A2): bed days still ran after the bill time
        DECLARE @stale INT, @upTo DATETIME, @gpMsg NVARCHAR(600);
        SELECT @stale = StaleBillDays, @upTo = BillUpToAt FROM dbo.fn_Ipd_DischargeState(@AdmissionId);
        SET @StaleBillReason = NULLIF(LTRIM(RTRIM(@StaleBillReason)), N'');
        IF @stale > 0 AND (ISNULL(@CanStaleBill, 0) = 0 OR @StaleBillReason IS NULL)
        BEGIN
            SET @gpMsg = CONCAT(N'The final bill is up to ', FORMAT(@upTo, 'dd-MMM HH:mm'), N' and ', @stale, N' more bed day(s) have run since: cancel the bill and bill up to now',
                                CASE WHEN ISNULL(@CanStaleBill, 0) = 1 THEN N', or enter the reason to discharge without charging them.' ELSE N' (or ask a user allowed "Gate pass on an older bill").' END);
            THROW 59680, @gpMsg, 1;
        END
        IF @bal < -0.5 THROW 58508, 'Excess advance is held: refund it (Billing tab) before the gate pass.', 1;
        SET @CreditReason = NULLIF(LTRIM(RTRIM(@CreditReason)), N'');
        IF @bal > 0.5 AND ISNULL(@Credit, 0) = 0 THROW 58509, 'The patient''s balance is not paid: collect it (Billing tab), or make a credit discharge.', 1;
        IF @bal > 0.5 AND ISNULL(@CanCredit, 0) = 0 THROW 58510, 'You are not allowed to discharge with a balance due (credit discharge).', 1;
        IF @bal > 0.5 AND @CreditReason IS NULL THROW 58511, 'Enter the reason for the credit discharge.', 1;
        SET @HandedOverTo = NULLIF(LTRIM(RTRIM(@HandedOverTo)), N'');
        IF @type NOT IN ('ABSCONDED') AND @HandedOverTo IS NULL
            THROW 58512, 'Enter to whom the patient (or the body) is handed over.', 1;

        DECLARE @no NVARCHAR(40);
        EXEC dbo.usp_Ipd_NextNumber @BranchId = @BranchId, @DocType = 'GP', @DocDate = @now, @DocNo = @no OUTPUT;
        UPDATE dbo.IpdDischarge SET Status = 'DISCHARGED', GatePassNo = @no, GatePassAt = @now, GatePassBy = @UserId, HandedOverTo = @HandedOverTo,
               HandedOverRelation = NULLIF(LTRIM(RTRIM(@HandedOverRelation)), N''), HandedOverPhone = NULLIF(LTRIM(RTRIM(@HandedOverPhone)), N''),
               TransportMode = NULLIF(LTRIM(RTRIM(@TransportMode)), N''), GatePassRemarks = NULLIF(LTRIM(RTRIM(@Remarks)), N''),
               IsCreditDischarge = CASE WHEN @bal > 0.5 THEN 1 ELSE 0 END, CreditReason = CASE WHEN @bal > 0.5 THEN @CreditReason END,
               CreditAmount = CASE WHEN @bal > 0.5 THEN @bal END, ModifiedBy = @UserId, ModifiedDate = @now
        WHERE DischargeId = @id;
        -- bed: end the movement with DISCHARGE and release it (housekeeping job, or Available per Hospital Settings > IPD)
        DECLARE @mv INT, @mbed INT;
        SELECT @mv = MovementId, @mbed = BedId FROM dbo.IpdBedMovement WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND ToAt IS NULL;
        IF @mv IS NOT NULL
        BEGIN
            UPDATE dbo.IpdBedMovement SET ToAt = @now, EndType = 'DISCHARGE' WHERE MovementId = @mv;
            EXEC dbo.usp_Ipd_ReleaseBed @BedId = @mbed, @AdmissionId = @AdmissionId, @Reason = 'DISCHARGE', @UserId = @UserId;
        END
        -- 2575 (B9): what runs on the patient ends with the discharge
        UPDATE dbo.IpdOrder SET Status = 'STOPPED', StoppedAt = @now, StoppedBy = @UserId, StopReason = N'Patient discharged' WHERE AdmissionId = @AdmissionId AND Status = 'ACTIVE';
        UPDATE dbo.IpdIcuInfusion SET Status = 'STOPPED', StopAt = @now, StopReason = N'Patient discharged' WHERE AdmissionId = @AdmissionId AND Status = 'RUNNING';
        UPDATE dbo.IpdIcuDevice SET StopAt = @now, ModifiedBy = @UserId, ModifiedDate = @now WHERE AdmissionId = @AdmissionId AND Status = 'ACTIVE' AND StopAt IS NULL;
        UPDATE dbo.IpdCrossConsult SET Status = 'CANCELLED', CancelledBy = @UserId, CancelReason = N'Patient discharged' WHERE AdmissionId = @AdmissionId AND Status = 'REQUESTED';
        UPDATE dbo.IpdEscalation SET Status = 'CLOSED', ClosedBy = @UserId, ClosedAt = @now, CloseNote = N'Patient discharged' WHERE AdmissionId = @AdmissionId AND Status <> 'CLOSED';
        UPDATE dbo.IpdRestraint SET Status = 'ENDED', EndAt = @now, EndReason = N'Patient discharged', EndedBy = @UserId WHERE AdmissionId = @AdmissionId AND Status = 'ACTIVE';
        IF @stale > 0
            INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
            VALUES (@AdmissionId, 'GATEPASS_OLD_BILL', CONCAT(N'Gate pass on a bill up to ', FORMAT(@upTo, 'dd-MMM HH:mm'), N' (', @stale, N' bed day(s) not charged): ', @StaleBillReason), @UserId);
        UPDATE dbo.IpdAdmission SET Status = 'DISCHARGED', IsOpen = 0, DischargeAt = @now, ModifiedBy = @UserId, ModifiedDate = @now WHERE AdmissionId = @AdmissionId;
        UPDATE dbo.IpdDeathRecord SET BodyHandedTo = ISNULL(BodyHandedTo, @HandedOverTo), BodyHandedRelation = ISNULL(BodyHandedRelation, NULLIF(LTRIM(RTRIM(@HandedOverRelation)), N'')),
               BodyHandedAt = ISNULL(BodyHandedAt, @now) WHERE AdmissionId = @AdmissionId AND IsActive = 1;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, FromStatus, ToStatus, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'GATE_PASS', @status, 'DISCHARGED', CONCAT(N'Gate pass ', @no, N' (', @type, N')', CASE WHEN @HandedOverTo IS NOT NULL THEN N', handed over to ' + @HandedOverTo ELSE N'' END,
                CASE WHEN @bal > 0.5 THEN CONCAT(N', credit discharge ₹', FORMAT(@bal, 'N2', 'en-IN'), N': ', @CreditReason) ELSE N'' END), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @no AS GatePassNo;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── IPD Patient workspace (live + 2575: banner alerts) ──
-- ── usp_Api_IpdAdmission_Get ──
-- ── one admission: banner and every block of the patient workspace ──────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdmission_Get @CompanyId INT, @AdmissionId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME = GETDATE();
    -- 1 header + live money
    SELECT h.*, lt.Net AS BillNow, lt.Days AS BedDays, lt.NoTariff, mo.AdvanceTotal, mo.RefundTotal, mo.NetAdvance,
           CAST(lt.Net - ps.PayerShare - mo.NetAdvance AS DECIMAL(18,2)) AS BalanceDue, ps.PayerShare AS PayerShareNow, ps.ApprovedAmount AS PayerApproved,
           CAST(CASE WHEN h.IsOpen = 1 AND h.PayerType = 'CASH' AND (lt.Net > mo.NetAdvance OR (mo.NetAdvance > 0 AND lt.Net >= mo.NetAdvance * h.DepositAlertPercent / 100.0)) THEN 1 ELSE 0 END AS BIT) AS DepositAlert,
           DATEDIFF(DAY, h.AdmissionAt, ISNULL(h.DischargeAt, @now)) + 1 AS DayCount,
           -- 2575: alerts of the banner
           pa.PreAuthAlert, pa.PreAuthUsedPercent, pa.PreAuthApproved, pa.PreAuthOverBy,
           x.CodeStatus, x.IsolationType, x.IsolationReason, x.IsolationSince, x.ReadmitDays, rd.IpNo AS ReadmitOfIpNo,
           CAST(CASE WHEN pd.PatientId IS NULL THEN 0 ELSE 1 END AS BIT) AS IsDeceased,
           CAST(CASE WHEN x.IsMlc = 1 AND (NULLIF(LTRIM(RTRIM(ml.PoliceStation)), N'') IS NULL OR ml.InformedAt IS NULL) THEN 1 ELSE 0 END AS BIT) AS MlcPoliceDue,
           CAST(CASE WHEN x.AdmissionType = 'DAYCARE' AND h.IsOpen = 1 AND DATEDIFF(HOUR, h.AdmissionAt, @now) > gs.DaycareMaxHours THEN 1 ELSE 0 END AS BIT) AS DaycareOverstay,
           CAST(CASE WHEN pkd.Days > 0 AND lt.Days > pkd.Days THEN lt.Days - pkd.Days ELSE 0 END AS INT) AS PackageOverstayDays, pkd.Days AS PackageDays,
           (SELECT COUNT(*) FROM dbo.IpdEscalation e WHERE e.AdmissionId = h.AdmissionId AND e.Status = 'OPEN') AS OpenEscalations,
           (SELECT COUNT(*) FROM dbo.IpdOrder o WHERE o.AdmissionId = h.AdmissionId AND o.OrderType = 'MED' AND o.Status = 'ACTIVE' AND ISNULL(o.VerifyStatus, '') <> 'VERIFIED') AS UnverifiedOrders,
           (SELECT COUNT(*) FROM dbo.IpdOrder o WHERE o.AdmissionId = h.AdmissionId AND o.OrderType = 'MED' AND o.Status = 'ACTIVE' AND o.VerifyStatus = 'QUERY') AS PharmacistQueries,
           al.Recorded AS AllergyRecorded, mo2.IpNo AS MotherIpNo, adj.SuppNet, adj.CreditNet, gs.MarScanRequired, gs.MarNeedsVerify,
           CAST(lt.Net - ps.PayerShare - mo.NetAdvance + adj.AdjNet AS DECIMAL(18,2)) AS BalanceAfterAdjustments
    FROM dbo.fn_Ipd_AdmissionHeader(@CompanyId, @AdmissionId) h
    CROSS APPLY dbo.fn_Ipd_LiveTotal(h.AdmissionId, @now) lt
    CROSS APPLY dbo.fn_Ipd_Money(h.AdmissionId) mo
    CROSS APPLY dbo.fn_Ipd_PayerShare(h.AdmissionId, lt.Net) ps
    CROSS APPLY dbo.fn_Ipd_PreAuthAlert(h.AdmissionId, lt.Net) pa
    CROSS APPLY dbo.fn_Ipd_GapSettings(h.BranchId) gs
    CROSS APPLY dbo.fn_Ipd_PostBillAdj(h.AdmissionId) adj
    CROSS APPLY dbo.fn_Ipd_AllergyStatus(h.PatientId) al
    JOIN dbo.IpdAdmission x ON x.AdmissionId = h.AdmissionId
    LEFT JOIN dbo.IpdAdmission rd ON rd.AdmissionId = x.ReadmitOfAdmissionId
    LEFT JOIN dbo.IpdAdmission mo2 ON mo2.AdmissionId = x.MotherAdmissionId
    LEFT JOIN dbo.PatientDeceased pd ON pd.PatientId = h.PatientId
    LEFT JOIN dbo.IpdMlc ml ON ml.AdmissionId = h.AdmissionId
    OUTER APPLY (SELECT MAX(c.Days) AS Days FROM dbo.fn_Ipd_PackageCover(x.PackageId) c WHERE c.Head = 'BED') pkd;   -- 2541
    IF @@ROWCOUNT = 0 RETURN;
    -- 2 payers
    SELECT py.PayerId, py.Seq, py.PayerType, py.InsuranceTpaId, py.CorporateId, py.SchemeId, COALESCE(ins.Name, corp.Corporate_Name, sch.SchemeName) AS PayerName,
           py.PolicyNo, py.MemberId, py.CardHolderName, py.RelationToHolder, py.PolicyValidTo, py.EmployeeId, py.CardFilePath, py.Remarks
    FROM dbo.IpdAdmissionPayer py
    LEFT JOIN dbo.InsuranceTPAMaster ins ON ins.InsuranceTPA_ID = py.InsuranceTpaId
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = py.CorporateId
    LEFT JOIN dbo.GovernmentSchemeMaster sch ON sch.Scheme_ID = py.SchemeId
    WHERE py.AdmissionId = @AdmissionId ORDER BY py.Seq;
    -- 3 attendants
    SELECT a.AttendantId, a.Name, a.Relation, a.Phone, a.Address, a.IdTypeId, it.IdentificationTypeName AS IdTypeName, a.IdNumber, a.IsPrimary, a.PassNo
    FROM dbo.IpdAttendant a LEFT JOIN dbo.IdentificationTypeMaster it ON it.IdentificationTypeId = a.IdTypeId
    WHERE a.AdmissionId = @AdmissionId ORDER BY a.IsPrimary DESC, a.AttendantId;
    -- 4 MLC
    SELECT m.* FROM dbo.IpdMlc m WHERE m.AdmissionId = @AdmissionId;
    -- 5 consents (text read separately for print)
    SELECT c.AdmissionConsentId, c.ConsentId, c.ConsentType, c.Language, c.Version, c.SignedByName, c.SignedByRelation, c.WitnessName, c.SignaturePath,
           c.WitnessSignaturePath, c.SignedAt, u.FullName AS CapturedByName
    FROM dbo.IpdAdmissionConsent c LEFT JOIN dbo.Users u ON u.Id = c.CreatedBy
    WHERE c.AdmissionId = @AdmissionId ORDER BY c.SignedAt;
    -- 6 bed movements
    SELECT m.MovementId, m.MoveType, m.EndType, m.FromAt, m.ToAt, m.BedId, b.BedNumber, r.RoomNumber, w.WardName, bc.CategoryName AS BedCategoryName, m.Reason,
           u.FullName AS CreatedByName
    FROM dbo.IpdBedMovement m
    JOIN dbo.BedMaster b ON b.BedId = m.BedId
    LEFT JOIN dbo.RoomMaster r ON r.RoomId = m.RoomId
    LEFT JOIN dbo.WardMaster w ON w.WardId = m.WardId
    LEFT JOIN dbo.BedCategoryMaster bc ON bc.BedCategoryId = m.BedCategoryId
    LEFT JOIN dbo.Users u ON u.Id = m.CreatedBy
    WHERE m.AdmissionId = @AdmissionId ORDER BY m.FromAt, m.MovementId;
    -- 7 advances and refunds (with the modes of each receipt)
    SELECT v.AdvanceId, v.Kind, v.Amount, v.DocNo, v.Mode, v.RefNo, v.Remarks, v.CreatedDate, u.FullName AS CreatedByName,
           CASE WHEN v.Kind IN ('ADVANCE', 'SETTLE') THEN
                STUFF((SELECT N', ' + pm.MethodName + N' ₹' + FORMAT(pd.PaidAmount, 'N2', 'en-IN')
                       FROM dbo.PaymentDetail pd JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
                       WHERE pd.PaymentHeaderId = v.PaymentHeaderId AND pd.IsActive = 1 FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'')
                ELSE v.Mode END AS Modes
    FROM dbo.IpdAdvance v LEFT JOIN dbo.Users u ON u.Id = v.CreatedBy
    WHERE v.AdmissionId = @AdmissionId AND v.IsActive = 1 ORDER BY v.CreatedDate, v.AdvanceId;
    -- 8 documents
    SELECT d.DocumentId, d.DocType, d.Title, d.FilePath, d.Remarks, d.CreatedDate, u.FullName AS CreatedByName
    FROM dbo.IpdDocument d LEFT JOIN dbo.Users u ON u.Id = d.CreatedBy
    WHERE d.AdmissionId = @AdmissionId AND d.IsActive = 1 ORDER BY d.CreatedDate DESC;
    -- 9 activity log
    SELECT l.LogId, l.Action, l.FromStatus, l.ToStatus, l.Remarks, l.CreatedDate, u.FullName AS CreatedByName
    FROM dbo.IpdStatusLog l LEFT JOIN dbo.Users u ON u.Id = l.CreatedBy
    WHERE l.AdmissionId = @AdmissionId ORDER BY l.LogId DESC;
END;
GO

-- ── bed board (live + 2575: isolation, code status, escalations) ──
-- ── usp_Api_IpdBed_Board ──
-- ── the bed board ───────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBed_Board @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_Ipd_ExpireReservations @BranchId = @BranchId;
    DECLARE @now DATETIME = GETDATE();
    -- 1 every active bed with its occupant / reservation / cleaning job
    SELECT b.BedId, b.BedNumber, b.BedCategoryId, bc.CategoryName AS BedCategoryName, r.RoomId, r.RoomNumber, r.RoomType,
           w.WardId, w.WardName, w.WardType, w.Gender AS WardGender, dep.DeptName AS WardDepartment, f.FloorId, f.FloorName, bl.BuildingId, bl.BuildingName,
           CAST(ISNULL(b.IsICU, 0) AS BIT) AS IsIcu, CAST(CASE WHEN b.IsIsolation = 1 OR r.IsIsolation = 1 THEN 1 ELSE 0 END AS BIT) AS IsIsolation,
           CAST(ISNULL(b.IsVentilatorCapable, 0) AS BIT) AS IsVentilator,
           CASE WHEN occ.AdmissionId IS NOT NULL THEN N'Occupied' ELSE b.BedStatus END AS Status,
           lg.Reason AS StatusReason, lg.CreatedDate AS StatusSince,
           occ.AdmissionId, occ.IpNo, occ.PatientId, occ.PatientCode, occ.PatientName, occ.Gender, occ.AgeText, occ.AdmissionAt, occ.OccupiedSince,
           occ.ConsultantName, occ.PayerType, occ.ExpectedDischargeAt, occ.KnownAllergies, occ.IsMlc, occ.AdmStatus, occ.IsolationType, occ.CodeStatus, occ.OpenEscalations,
           CASE WHEN occ.AdmissionId IS NULL THEN NULL ELSE DATEDIFF(DAY, occ.AdmissionAt, @now) + 1 END AS DayCount,
           lt.Net AS BillNow, mo.NetAdvance, CAST(lt.Net - ISNULL(ps.PayerShare, 0) - mo.NetAdvance AS DECIMAL(18,2)) AS BalanceDue,
           res.ReservationId, res.PatientName AS ResPatientName, res.Phone AS ResPhone, res.PatientId AS ResPatientId, res.ExpectedAdmitAt, res.ReservedUntil,
           cl.CleaningTaskId, cl.Status AS CleaningStatus, cl.CleaningType, cl.RequestedAt AS CleaningRequestedAt, cl.StartedAt AS CleaningStartedAt,
           cl.SlaMinutes, cu.FullName AS CleaningStaff, DATEDIFF(MINUTE, cl.RequestedAt, @now) AS CleaningMinutes
    FROM dbo.BedMaster b
    JOIN dbo.RoomMaster r ON r.RoomId = b.RoomId
    JOIN dbo.WardMaster w ON w.WardId = b.WardId
    LEFT JOIN dbo.DepartmentMaster dep ON dep.DeptId = w.DepartmentId
    LEFT JOIN dbo.FloorMaster f ON f.FloorId = r.FloorId
    LEFT JOIN dbo.BuildingMaster bl ON bl.BuildingId = b.BuildingId
    LEFT JOIN dbo.BedCategoryMaster bc ON bc.BedCategoryId = b.BedCategoryId
    OUTER APPLY (SELECT TOP 1 a.AdmissionId, a.IpNo, a.PatientId, p.PatientCode, a.AdmissionAt, m.FromAt AS OccupiedSince, a.PayerType, a.ExpectedDischargeAt, a.IsMlc, a.Status AS AdmStatus, a.IsolationType, a.CodeStatus,
                        (SELECT COUNT(*) FROM dbo.IpdEscalation e WHERE e.AdmissionId = a.AdmissionId AND e.Status = 'OPEN') AS OpenEscalations,
                        LTRIM(RTRIM(CONCAT(NULLIF(p.Salutation, '') + ' ', p.FirstName, ' ', p.LastName))) AS PatientName, p.Gender, p.KnownAllergies,
                        dbo.fn_Ipd_AgeText(p.DateOfBirth, CAST(@now AS DATE)) AS AgeText, d.FullName AS ConsultantName
                 FROM dbo.IpdBedMovement m JOIN dbo.IpdAdmission a ON a.AdmissionId = m.AdmissionId JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
                 LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = a.ConsultantDoctorId
                 WHERE m.BedId = b.BedId AND m.ToAt IS NULL) occ
    OUTER APPLY (SELECT TOP 1 Reason, CreatedDate FROM dbo.IpdBedStatusLog WHERE BedId = b.BedId ORDER BY LogId DESC) lg
    OUTER APPLY (SELECT TOP 1 * FROM dbo.IpdBedReservation x WHERE x.BedId = b.BedId AND x.Status = 'ACTIVE') res
    OUTER APPLY (SELECT TOP 1 * FROM dbo.IpdBedCleaning x WHERE x.BedId = b.BedId AND x.IsOpen = 1) cl
    LEFT JOIN dbo.Users cu ON cu.Id = cl.AssignedUserId
    OUTER APPLY (SELECT Net FROM dbo.fn_Ipd_LiveTotal(occ.AdmissionId, @now) WHERE occ.AdmissionId IS NOT NULL) lt
    OUTER APPLY (SELECT NetAdvance FROM dbo.fn_Ipd_Money(occ.AdmissionId) WHERE occ.AdmissionId IS NOT NULL) mo
    OUTER APPLY (SELECT PayerShare FROM dbo.fn_Ipd_PayerShare(occ.AdmissionId, lt.Net) WHERE occ.AdmissionId IS NOT NULL) ps   -- 2541
    WHERE b.IsActive = 1 AND b.BranchId = @BranchId AND w.IsActive = 1 AND r.IsActive = 1
    ORDER BY bl.BuildingName, f.FloorName, w.WardName, r.RoomNumber, b.BedNumber;
    -- 2 housekeeping staff of the branch (Master > Housekeeping > Staff)
    SELECT DISTINCT u.Id AS UserId, COALESCE(u.FullName, u.Username) AS Name
    FROM dbo.HKStaffMaster s JOIN dbo.Users u ON u.Id = s.Staff_ID AND u.IsActive = 1
    WHERE s.Branch_ID = @BranchId AND s.Status = 1 ORDER BY Name;
    -- 3 reservations of the last 7 days and the coming ones
    SELECT x.ReservationId, x.BedId, b.BedNumber, w.WardName, x.PatientId, x.PatientName, x.Phone, x.ExpectedAdmitAt, x.ReservedUntil, x.Status, x.Remarks,
           x.CloseReason, a.IpNo, d.FullName AS DoctorName, u.FullName AS CreatedByName, x.CreatedDate
    FROM dbo.IpdBedReservation x JOIN dbo.BedMaster b ON b.BedId = x.BedId JOIN dbo.WardMaster w ON w.WardId = b.WardId
    LEFT JOIN dbo.IpdAdmission a ON a.AdmissionId = x.AdmissionId LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = x.DoctorId LEFT JOIN dbo.Users u ON u.Id = x.CreatedBy
    WHERE x.BranchId = @BranchId AND (x.Status = 'ACTIVE' OR x.CreatedDate >= DATEADD(DAY, -7, @now))
    ORDER BY CASE WHEN x.Status = 'ACTIVE' THEN 0 ELSE 1 END, x.ExpectedAdmitAt DESC;
    -- 4 cleaning jobs: open ones and those finished today
    SELECT c.CleaningTaskId, c.BedId, b.BedNumber, w.WardName, r.RoomNumber, c.Reason, c.CleaningType, c.SlaMinutes, c.RequestedAt, c.StartedAt, c.CompletedAt, c.Status,
           u.FullName AS StaffName, cb.FullName AS CompletedByName, DATEDIFF(MINUTE, c.RequestedAt, ISNULL(c.CompletedAt, @now)) AS Minutes,
           CAST(CASE WHEN DATEDIFF(MINUTE, c.RequestedAt, ISNULL(c.CompletedAt, @now)) > c.SlaMinutes THEN 1 ELSE 0 END AS BIT) AS Overdue
    FROM dbo.IpdBedCleaning c JOIN dbo.BedMaster b ON b.BedId = c.BedId JOIN dbo.WardMaster w ON w.WardId = b.WardId JOIN dbo.RoomMaster r ON r.RoomId = b.RoomId
    LEFT JOIN dbo.Users u ON u.Id = c.AssignedUserId LEFT JOIN dbo.Users cb ON cb.Id = c.CompletedBy
    WHERE c.BranchId = @BranchId AND (c.IsOpen = 1 OR c.CompletedAt >= CAST(@now AS DATE))
    ORDER BY c.IsOpen DESC, c.RequestedAt;
END;
GO


PRINT '2575 IPD flow-gap discharge / banner - done.';
GO
