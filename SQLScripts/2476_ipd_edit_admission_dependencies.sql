-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2476  IPD Edit Admission - the dependencies of a change (application database)
--   Edit Admission saved only the admission row; what depends on it now follows the change in the same transaction:
--   Tariff category  posted SERVICE / PROCEDURE / DOCTOR charges still at their master rate are re-priced from the new
--                    tariff (rate on the charge date); a hand-edited rate, or no rate in the new tariff, is kept (counted).
--                    Bed days already follow the tariff live (fn_Ipd_BillLines).
--   Payer            the pharmacy price type (IPD_CASH / IPD_CORPORATE / IPD_INSURANCE) changes: issued medicines and
--                    consumables still on the bill are re-priced by the Price Rule (never above MRP), as a new issue would be.
--   Package          needs the Package permission (+ reason when a package is replaced / removed) and re-flags the charges
--                    inside / outside the package exactly as the Package button (usp_Ipd_ApplyPackageFlags, shared).
--   Department       refused when the bed is in a ward of another department (as at admission): use Transfer Bed.
--   The admission row is locked during the save; the log names every change. Charge amounts: usp_Ipd_ChargeRecalc.
--   Needs 2434, 2437. Safe to re-run. Replaces usp_Api_IpdAdmission_Update (2423) and usp_Api_IpdBill_SetPackage (2434).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- amounts of the posted charges of an admission from their rate / quantity (package items stay at 0; the item discount is capped)
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_ChargeRecalc @AdmissionId INT, @ChargeIds NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE c SET Gross = CASE WHEN c.IsPackageItem = 1 THEN 0 ELSE ROUND(c.Qty * c.Rate, 2) END,
                 Discount = CASE WHEN c.IsPackageItem = 1 THEN 0 WHEN ISNULL(c.ListDiscount, 0) > ROUND(c.Qty * c.Rate, 2) THEN ROUND(c.Qty * c.Rate, 2) ELSE ISNULL(c.ListDiscount, 0) END
    FROM dbo.IpdCharge c
    WHERE c.AdmissionId = @AdmissionId AND c.Status = 'POSTED'
      AND (@ChargeIds IS NULL OR c.ChargeId IN (SELECT TRY_CAST(value AS BIGINT) FROM STRING_SPLIT(@ChargeIds, ',')));
    UPDATE dbo.IpdCharge SET GstAmount = ROUND((Gross - Discount) * GstPercent / 100, 2) WHERE AdmissionId = @AdmissionId AND Status = 'POSTED';
    UPDATE dbo.IpdCharge SET Net = Gross - Discount + GstAmount WHERE AdmissionId = @AdmissionId AND Status = 'POSTED';
END;
GO

-- inside / outside the package for every posted IPD charge (Package button and Edit Admission)
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_ApplyPackageFlags @AdmissionId INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE c SET IsPackageItem = x.Pkg,
           Gross = CASE WHEN x.Pkg = 1 THEN 0 ELSE ROUND(c.Qty * c.Rate, 2) END,
           Discount = CASE WHEN x.Pkg = 1 THEN 0 ELSE ISNULL(c.ListDiscount, 0) END,
           GstPercent = CASE WHEN x.Pkg = 1 THEN 0 ELSE ISNULL(c.GstPercent, 0) END
    FROM dbo.IpdCharge c CROSS APPLY (SELECT CASE WHEN c.ExcludePackage = 0 THEN dbo.fn_Ipd_InPackage(c.AdmissionId, c.Head) ELSE 0 END AS Pkg) x
    WHERE c.AdmissionId = @AdmissionId AND c.Status = 'POSTED' AND ISNULL(c.SourceModule, 'IPD') = 'IPD';
    -- GST % of a charge that left the package comes back from its master
    UPDATE c SET GstPercent = ISNULL(s.TaxPercentage, 0)
    FROM dbo.IpdCharge c JOIN dbo.HospitalServiceMaster s ON s.HospitalServiceId = c.RefId
    WHERE c.AdmissionId = @AdmissionId AND c.Status = 'POSTED' AND c.RefKind = 'SERVICE' AND c.IsPackageItem = 0;
    UPDATE dbo.IpdCharge SET GstAmount = ROUND((Gross - Discount) * GstPercent / 100, 2) WHERE AdmissionId = @AdmissionId AND Status = 'POSTED';
    UPDATE dbo.IpdCharge SET Net = Gross - Discount + GstAmount WHERE AdmissionId = @AdmissionId AND Status = 'POSTED';
END;
GO

-- new tariff category: master-rate charges re-priced (rate of the charge date); edited rates / no rate kept
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_RepriceTariff @AdmissionId INT, @Repriced INT = 0 OUTPUT, @Kept INT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @br INT, @tc INT;
    SELECT @br = BranchId, @tc = TariffCategoryId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId;
    DECLARE @R TABLE (ChargeId BIGINT PRIMARY KEY, NewRate DECIMAL(18,2));
    INSERT @R (ChargeId, NewRate)
    SELECT c.ChargeId, CASE c.RefKind WHEN 'SERVICE' THEN sr.Rate WHEN 'PROCEDURE' THEN pr.Rate WHEN 'DOCTOR' THEN df.Rate END
    FROM dbo.IpdCharge c
    OUTER APPLY (SELECT Rate FROM dbo.fn_Ipd_ServiceRate(@br, c.RefId, @tc, CAST(c.ChargeAt AS DATE)) WHERE c.RefKind = 'SERVICE') sr
    OUTER APPLY (SELECT Rate FROM dbo.fn_Ipd_ProcedureRate(@br, c.RefId, @tc, CAST(c.ChargeAt AS DATE)) WHERE c.RefKind = 'PROCEDURE') pr
    OUTER APPLY (SELECT Rate FROM dbo.fn_Ipd_DoctorFee(@br, c.RefId, c.ItemCode, @tc, CAST(c.ChargeAt AS DATE)) WHERE c.RefKind = 'DOCTOR') df
    WHERE c.AdmissionId = @AdmissionId AND c.Status = 'POSTED' AND ISNULL(c.SourceModule, 'IPD') = 'IPD' AND c.RefKind IN ('SERVICE', 'PROCEDURE', 'DOCTOR');
    -- only a charge still at its master rate follows the tariff (a hand-edited rate is the user's decision)
    SELECT @Kept = COUNT(*) FROM @R r JOIN dbo.IpdCharge c ON c.ChargeId = r.ChargeId
     WHERE c.MasterRate IS NULL OR c.Rate <> c.MasterRate OR ISNULL(r.NewRate, 0) <= 0;
    DELETE r FROM @R r JOIN dbo.IpdCharge c ON c.ChargeId = r.ChargeId
     WHERE c.MasterRate IS NULL OR c.Rate <> c.MasterRate OR ISNULL(r.NewRate, 0) <= 0 OR r.NewRate = c.Rate;
    SET @Repriced = (SELECT COUNT(*) FROM @R);
    IF @Repriced = 0 RETURN;
    UPDATE c SET Rate = r.NewRate, MasterRate = r.NewRate FROM dbo.IpdCharge c JOIN @R r ON r.ChargeId = c.ChargeId;
    DECLARE @ids NVARCHAR(MAX) = (SELECT STRING_AGG(CAST(ChargeId AS VARCHAR(20)), ',') FROM @R);
    EXEC dbo.usp_Ipd_ChargeRecalc @AdmissionId = @AdmissionId, @ChargeIds = @ids;
END;
GO

-- new payer: issued medicines / consumables still on the bill are re-priced with the new price type (Price Rule, never above MRP)
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_RepricePharmacy @AdmissionId INT, @CompanyId INT, @Repriced INT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Repriced = 0;
    IF OBJECT_ID('dbo.IpdPhIssue', 'U') IS NULL RETURN;
    DECLARE @pt VARCHAR(20) = (SELECT PriceType FROM dbo.fn_Ipd_PhPriceType(@AdmissionId));
    DECLARE @X TABLE (LineId INT PRIMARY KEY, IssueId INT, ChargeId BIGINT, Price DECIMAL(12,4), Gst DECIMAL(5,2));
    INSERT @X (LineId, IssueId, ChargeId, Price, Gst)
    SELECT l.LineId, l.IssueId, l.ChargeId, pr.UnitPrice, l.GstPercent
    FROM dbo.IpdPhIssue s JOIN dbo.IpdPhIssueLine l ON l.IssueId = s.IssueId
    CROSS APPLY dbo.fn_PhSaleUnitPrice(@CompanyId, l.ItemId, l.BatchId, @pt) pr
    WHERE s.AdmissionId = @AdmissionId AND s.Kind = 'ISSUE' AND s.PriceType <> @pt AND ISNULL(pr.UnitPrice, 0) > 0 AND pr.UnitPrice <> l.UnitPrice;
    UPDATE s SET PriceType = @pt FROM dbo.IpdPhIssue s WHERE s.AdmissionId = @AdmissionId AND s.Kind = 'ISSUE';
    SET @Repriced = (SELECT COUNT(*) FROM @X);
    IF @Repriced = 0 RETURN;
    UPDATE l SET UnitPrice = x.Price, Amount = ROUND(l.Qty * x.Price, 2) FROM dbo.IpdPhIssueLine l JOIN @X x ON x.LineId = l.LineId;
    UPDATE s SET Total = (SELECT SUM(Amount) FROM dbo.IpdPhIssueLine WHERE IssueId = s.IssueId) FROM dbo.IpdPhIssue s WHERE s.IssueId IN (SELECT IssueId FROM @X);
    -- the IP bill charge of what is kept: the price split into taxable + GST as at the issue
    UPDATE c SET Rate = ROUND(x.Price / (1 + x.Gst / 100), 2), MasterRate = ROUND(x.Price / (1 + x.Gst / 100), 2)
    FROM dbo.IpdCharge c JOIN @X x ON x.ChargeId = c.ChargeId WHERE c.Status = 'POSTED';
    DECLARE @ids NVARCHAR(MAX) = (SELECT STRING_AGG(CAST(ChargeId AS VARCHAR(20)), ',') FROM @X WHERE ChargeId IS NOT NULL);
    IF @ids IS NOT NULL EXEC dbo.usp_Ipd_ChargeRecalc @AdmissionId = @AdmissionId, @ChargeIds = @ids;
END;
GO

-- Package button (2434), the flags now in usp_Ipd_ApplyPackageFlags
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBill_SetPackage @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @PackageId INT = NULL, @Reason NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @open BIT, @bill INT, @old INT, @status VARCHAR(20);
        SELECT @open = IsOpen, @bill = BillId, @old = PackageId, @status = Status FROM dbo.IpdAdmission WITH (UPDLOCK)
        WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @open IS NULL THROW 54931, 'The admission was not found in this branch.', 1;
        IF @open = 0 OR @bill IS NOT NULL OR @status NOT IN ('ADMITTED', 'DISCHARGE_ADVISED') THROW 54932, 'The package can be changed only before the final bill.', 1;
        IF @PackageId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.HospitalPackageMaster WHERE HospitalPackage_ID = @PackageId AND Branch_ID = @BranchId AND Status = 1)
            THROW 54933, 'Choose an active package of this branch.', 1;
        IF @PackageId IS NOT NULL AND ISNULL((SELECT TotalPackageAmount FROM dbo.HospitalPackageMaster WHERE HospitalPackage_ID = @PackageId), 0) <= 0
            THROW 54936, 'This package has no amount (Master > Hospital Package): it cannot be applied.', 1;
        IF ISNULL(@old, 0) = ISNULL(@PackageId, 0) THROW 54934, 'The admission is already on this package.', 1;
        IF @old IS NOT NULL AND NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 54935, 'Enter the reason for changing the package.', 1;
        UPDATE dbo.IpdAdmission SET PackageId = @PackageId, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE AdmissionId = @AdmissionId;
        EXEC dbo.usp_Ipd_ApplyPackageFlags @AdmissionId = @AdmissionId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'PACKAGE', CONCAT(N'Package ', ISNULL((SELECT Package_Name FROM dbo.HospitalPackageMaster WHERE HospitalPackage_ID = @old), N'none'), N' → ',
                ISNULL((SELECT Package_Name FROM dbo.HospitalPackageMaster WHERE HospitalPackage_ID = @PackageId), N'none'), ISNULL(N': ' + NULLIF(LTRIM(RTRIM(@Reason)), N''), N'')), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── edit admission (2423) + the dependencies above ──────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdmission_Update
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT,
    @AdmissionType VARCHAR(20), @AdmissionSource VARCHAR(20), @ReferralDoctorId INT = NULL, @AdmittingDoctorId INT, @ConsultantDoctorId INT,
    @DepartmentId INT = NULL, @ProvisionalDiagnosis NVARCHAR(500) = NULL, @DiagnosisCode NVARCHAR(20) = NULL, @ReasonForAdmission NVARCHAR(500) = NULL,
    @ExpectedDischargeAt DATETIME = NULL, @TariffCategoryId INT, @PayerType VARCHAR(12), @PackageId INT = NULL, @Remarks NVARCHAR(1000) = NULL,
    @Payers NVARCHAR(MAX) = NULL, @Attendants NVARCHAR(MAX) = NULL, @IsMlc BIT = 0, @Mlc NVARCHAR(MAX) = NULL, @CanChangeTariff BIT = 0,
    @CanChangePackage BIT = 0, @PackageReason NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;   -- called inside another transaction: only this procedure's work is undone on a refusal
    DECLARE @msg NVARCHAR(600), @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @oldTc INT, @oldPayer VARCHAR(12), @open BIT, @admAt DATETIME, @oldTcName NVARCHAR(150), @newTcName NVARCHAR(150),
                @oldPkg INT, @oldDept INT, @oldCon INT, @oldAdm INT, @bed INT, @bill INT, @oldPt VARCHAR(20), @newPt VARCHAR(20);
        -- locked: a bill / transfer / charge cannot slip in between the checks and the save
        SELECT @oldTc = TariffCategoryId, @oldPayer = PayerType, @open = IsOpen, @admAt = AdmissionAt, @oldPkg = PackageId, @oldDept = DepartmentId,
               @oldCon = ConsultantDoctorId, @oldAdm = AdmittingDoctorId, @bed = CurrentBedId, @bill = BillId
        FROM dbo.IpdAdmission WITH (UPDLOCK, HOLDLOCK) WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @open IS NULL THROW 54201, 'The admission was not found in this branch.', 1;
        IF @open = 0 THROW 54202, 'The admission is closed and cannot be changed.', 1;
        IF @bill IS NOT NULL OR EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND Status = 'BILL_FINAL') THROW 54230, 'The final bill is made: cancel the bill to change the admission.', 1;
        SET @PackageId = NULLIF(@PackageId, 0);
        SET @AdmissionType = UPPER(@AdmissionType); SET @AdmissionSource = UPPER(@AdmissionSource); SET @PayerType = UPPER(@PayerType);
        IF @AdmissionType NOT IN ('ELECTIVE', 'EMERGENCY', 'DAYCARE', 'MATERNITY', 'TRANSFERIN') THROW 54203, 'Choose the admission type.', 1;
        IF @AdmissionSource NOT IN ('DIRECT', 'OPD', 'EMERGENCY', 'REFERRAL') THROW 54204, 'Choose the admission source.', 1;
        IF @PayerType NOT IN ('CASH', 'CORPORATE', 'INSURANCE', 'SCHEME') THROW 54205, 'Choose the payer.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @AdmittingDoctorId AND IsActive = 1 AND CompanyId = @CompanyId) THROW 54206, 'Choose the admitting doctor.', 1;
        IF @AdmittingDoctorId <> (SELECT AdmittingDoctorId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId)
           AND NOT EXISTS (SELECT 1 FROM dbo.DoctorDepartmentMap m JOIN dbo.DepartmentMaster x ON x.DeptId = m.DeptId AND x.IsActive = 1 AND x.DeptType = 'IPD'
                           WHERE m.DoctorId = @AdmittingDoctorId AND m.IsActive = 1)
            THROW 54215, 'The admitting doctor must belong to an IPD department (Master > Doctor > departments of type IPD).', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @ConsultantDoctorId AND IsActive = 1 AND CompanyId = @CompanyId) THROW 54207, 'Choose the consultant (treating doctor).', 1;
        IF @ConsultantDoctorId <> (SELECT ConsultantDoctorId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId)
           AND NOT EXISTS (SELECT 1 FROM dbo.DoctorDepartmentMap m JOIN dbo.DepartmentMaster x ON x.DeptId = m.DeptId AND x.IsActive = 1 AND x.DeptType = 'IPD'
                           WHERE m.DoctorId = @ConsultantDoctorId AND m.IsActive = 1)
            THROW 54216, 'The consultant (treating doctor) must belong to an IPD department (Master > Doctor > departments of type IPD).', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.TariffCategoryMaster WHERE TariffCategoryId = @TariffCategoryId AND IsActive = 1 AND CompanyId = @CompanyId AND (BranchId = @BranchId OR BranchId IS NULL))
            THROW 54208, 'Choose the tariff category.', 1;
        IF NULLIF(@DepartmentId, 0) IS NOT NULL AND ISNULL(@DepartmentId, 0) <> ISNULL((SELECT DepartmentId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId), 0)
           AND NOT EXISTS (SELECT 1 FROM dbo.DepartmentMaster WHERE DeptId = @DepartmentId AND IsActive = 1 AND DeptType = 'IPD')
            THROW 54217, 'Choose an IPD department (Master > Department, type IPD).', 1;
        -- the bed must stay in a ward of the department (as at admission): a change of ward is a bed transfer
        IF ISNULL(NULLIF(@DepartmentId, 0), 0) <> ISNULL(@oldDept, 0) AND NULLIF(@DepartmentId, 0) IS NOT NULL AND @bed IS NOT NULL
           AND EXISTS (SELECT 1 FROM dbo.BedMaster b JOIN dbo.WardMaster w ON w.WardId = b.WardId WHERE b.BedId = @bed AND w.DepartmentId IS NOT NULL AND w.DepartmentId <> @DepartmentId)
            THROW 54234, 'The patient''s bed is in a ward of another department. Use Transfer Bed (with "update department") to move the patient to a bed of the new department.', 1;
        -- a package change re-prices the charges: it needs the Package permission (and a reason when a package is replaced or removed), as the Package button
        IF ISNULL(@PackageId, 0) <> ISNULL(@oldPkg, 0)
        BEGIN
            IF ISNULL(@CanChangePackage, 0) = 0 THROW 54235, 'You are not allowed to change the package of an admission (Package permission).', 1;
            IF @oldPkg IS NOT NULL AND NULLIF(LTRIM(RTRIM(@PackageReason)), N'') IS NULL THROW 54236, 'Enter the reason for changing the package.', 1;
        END
        IF @PackageId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.HospitalPackageMaster WHERE HospitalPackage_ID = @PackageId AND Branch_ID = @BranchId AND Status = 1 AND ISNULL(TotalPackageAmount, 0) > 0)
            AND ISNULL(@PackageId, 0) <> ISNULL((SELECT PackageId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId), 0)
            THROW 54232, 'Choose an active package of this branch that has an amount.', 1;
        IF @TariffCategoryId <> @oldTc AND NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission a CROSS APPLY dbo.fn_Ipd_BedRate(@BranchId, a.CurrentBedId, @TariffCategoryId, CAST(GETDATE() AS DATE)) r
                                                         WHERE a.AdmissionId = @AdmissionId AND a.CurrentBedId IS NOT NULL)
            THROW 54231, 'The patient''s bed has no rate in the new tariff category (Master > IPD > Bed / Room Tariff): add the rate first.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.TariffCategoryMaster WHERE TariffCategoryId = @TariffCategoryId
                       AND CASE @PayerType WHEN 'CASH' THEN CASE WHEN PatientCategory LIKE N'%Cash%' OR PatientCategory LIKE N'%Self%' OR PatientCategory LIKE N'%Staff%' OR PatientCategory LIKE N'%Employee%' THEN 1 ELSE 0 END
                                           WHEN 'CORPORATE' THEN CASE WHEN PatientCategory LIKE N'%Corporate%' THEN 1 ELSE 0 END
                                           WHEN 'INSURANCE' THEN CASE WHEN PatientCategory LIKE N'%Insurance%' OR PatientCategory LIKE N'%TPA%' THEN 1 ELSE 0 END
                                           ELSE CASE WHEN PatientCategory LIKE N'%Government%' OR PatientCategory LIKE N'%Scheme%' THEN 1 ELSE 0 END END = 1)
            THROW 54233, 'The tariff category does not belong to the chosen payer (Master > Tariff Category > Patient Category).', 1;
        IF (@TariffCategoryId <> @oldTc OR @PayerType <> @oldPayer) AND ISNULL(@CanChangeTariff, 0) = 0
            THROW 54209, 'You are not allowed to change the payer or tariff category of an admission (it re-prices the whole stay).', 1;
        IF @ExpectedDischargeAt IS NOT NULL AND @ExpectedDischargeAt <= @admAt THROW 54210, 'The expected discharge must be after the admission time.', 1;

        DECLARE @P TABLE (Seq INT IDENTITY(1,1), PayerType VARCHAR(12), InsuranceTpaId INT, CorporateId INT, SchemeId INT, PolicyNo NVARCHAR(60), MemberId NVARCHAR(60),
                          CardHolderName NVARCHAR(150), RelationToHolder NVARCHAR(50), PolicyValidTo DATE, EmployeeId NVARCHAR(60), CardFilePath NVARCHAR(400), Remarks NVARCHAR(300));
        IF ISJSON(@Payers) = 1
            INSERT @P (PayerType, InsuranceTpaId, CorporateId, SchemeId, PolicyNo, MemberId, CardHolderName, RelationToHolder, PolicyValidTo, EmployeeId, CardFilePath, Remarks)
            SELECT UPPER(j.PayerType), j.InsuranceTpaId, j.CorporateId, j.SchemeId, LEFT(NULLIF(j.PolicyNo, N''), 60), LEFT(NULLIF(j.MemberId, N''), 60), LEFT(NULLIF(j.CardHolderName, N''), 150),
                   LEFT(NULLIF(j.RelationToHolder, N''), 50), j.PolicyValidTo, LEFT(NULLIF(j.EmployeeId, N''), 60), LEFT(NULLIF(j.CardFilePath, N''), 400), LEFT(NULLIF(j.Remarks, N''), 300)
            FROM OPENJSON(@Payers) WITH (PayerType VARCHAR(12), InsuranceTpaId INT, CorporateId INT, SchemeId INT, PolicyNo NVARCHAR(100), MemberId NVARCHAR(100), CardHolderName NVARCHAR(200),
                                         RelationToHolder NVARCHAR(100), PolicyValidTo DATE, EmployeeId NVARCHAR(100), CardFilePath NVARCHAR(500), Remarks NVARCHAR(500)) j
            WHERE j.PayerType IN ('CORPORATE', 'INSURANCE', 'SCHEME');
        IF @PayerType <> 'CASH' AND NOT EXISTS (SELECT 1 FROM @P WHERE Seq = 1 AND PayerType = @PayerType) THROW 54211, 'Enter the payer details (insurance / TPA, corporate or scheme).', 1;
        IF @PayerType = 'INSURANCE' AND EXISTS (SELECT 1 FROM @P WHERE Seq = 1 AND (InsuranceTpaId IS NULL OR PolicyNo IS NULL)) THROW 54212, 'Choose the insurance / TPA and enter the policy number.', 1;
        IF @PayerType = 'CORPORATE' AND EXISTS (SELECT 1 FROM @P WHERE Seq = 1 AND CorporateId IS NULL) THROW 54213, 'Choose the corporate.', 1;
        IF @PayerType = 'SCHEME' AND EXISTS (SELECT 1 FROM @P WHERE Seq = 1 AND SchemeId IS NULL) THROW 54214, 'Choose the government scheme.', 1;

        SELECT @oldPt = PriceType FROM dbo.fn_Ipd_PhPriceType(@AdmissionId);
        SELECT @oldTcName = Name FROM dbo.TariffCategoryMaster WHERE TariffCategoryId = @oldTc;
        SELECT @newTcName = Name FROM dbo.TariffCategoryMaster WHERE TariffCategoryId = @TariffCategoryId;
        UPDATE dbo.IpdAdmission SET AdmissionType = @AdmissionType, AdmissionSource = @AdmissionSource, ReferralDoctorId = NULLIF(@ReferralDoctorId, 0),
               AdmittingDoctorId = @AdmittingDoctorId, ConsultantDoctorId = @ConsultantDoctorId, DepartmentId = NULLIF(@DepartmentId, 0),
               ProvisionalDiagnosis = NULLIF(LTRIM(RTRIM(@ProvisionalDiagnosis)), N''), DiagnosisCode = NULLIF(LTRIM(RTRIM(@DiagnosisCode)), N''),
               ReasonForAdmission = NULLIF(LTRIM(RTRIM(@ReasonForAdmission)), N''), ExpectedDischargeAt = @ExpectedDischargeAt, TariffCategoryId = @TariffCategoryId,
               PayerType = @PayerType, PackageId = @PackageId, IsMlc = ISNULL(@IsMlc, 0), Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N''), ModifiedBy = @UserId, ModifiedDate = @now
        WHERE AdmissionId = @AdmissionId;

        DELETE dbo.IpdAdmissionPayer WHERE AdmissionId = @AdmissionId;
        INSERT dbo.IpdAdmissionPayer (AdmissionId, Seq, PayerType, InsuranceTpaId, CorporateId, SchemeId, PolicyNo, MemberId, CardHolderName, RelationToHolder, PolicyValidTo, EmployeeId, CardFilePath, Remarks)
        SELECT @AdmissionId, ROW_NUMBER() OVER (ORDER BY Seq), PayerType, InsuranceTpaId, CorporateId, SchemeId, PolicyNo, MemberId, CardHolderName, RelationToHolder, PolicyValidTo, EmployeeId, CardFilePath, Remarks
        FROM @P WHERE @PayerType <> 'CASH' OR Seq > 1;

        DELETE dbo.IpdAttendant WHERE AdmissionId = @AdmissionId;
        IF ISJSON(@Attendants) = 1
            INSERT dbo.IpdAttendant (AdmissionId, Name, Relation, Phone, Address, IdTypeId, IdNumber, IsPrimary, PassNo)
            SELECT @AdmissionId, LEFT(LTRIM(RTRIM(j.Name)), 150), LEFT(NULLIF(j.Relation, N''), 50), LEFT(NULLIF(j.Phone, N''), 20), LEFT(NULLIF(j.Address, N''), 400),
                   NULLIF(j.IdTypeId, 0), LEFT(NULLIF(j.IdNumber, N''), 60), ISNULL(j.IsPrimary, 0), LEFT(NULLIF(j.PassNo, N''), 30)
            FROM OPENJSON(@Attendants) WITH (Name NVARCHAR(200), Relation NVARCHAR(100), Phone NVARCHAR(40), Address NVARCHAR(500), IdTypeId INT, IdNumber NVARCHAR(100), IsPrimary BIT, PassNo NVARCHAR(60)) j
            WHERE NULLIF(LTRIM(RTRIM(j.Name)), N'') IS NOT NULL;

        IF ISNULL(@IsMlc, 0) = 1
        BEGIN
            DECLARE @mj NVARCHAR(MAX) = CASE WHEN ISJSON(@Mlc) = 1 THEN @Mlc ELSE N'{}' END;
            IF NOT EXISTS (SELECT 1 FROM dbo.IpdMlc WHERE AdmissionId = @AdmissionId) INSERT dbo.IpdMlc (AdmissionId) VALUES (@AdmissionId);
            UPDATE m SET MlcNo = LEFT(NULLIF(j.MlcNo, N''), 40), Nature = LEFT(NULLIF(j.Nature, N''), 40), IncidentAt = j.IncidentAt, IncidentPlace = LEFT(NULLIF(j.IncidentPlace, N''), 200),
                   BroughtBy = LEFT(NULLIF(j.BroughtBy, N''), 150), BroughtByPhone = LEFT(NULLIF(j.BroughtByPhone, N''), 20), PoliceStation = LEFT(NULLIF(j.PoliceStation, N''), 150),
                   OfficerName = LEFT(NULLIF(j.OfficerName, N''), 150), InformedAt = j.InformedAt, Remarks = LEFT(NULLIF(j.Remarks, N''), 500), ModifiedBy = @UserId, ModifiedDate = @now
            FROM dbo.IpdMlc m
            CROSS APPLY OPENJSON(@mj) WITH (MlcNo NVARCHAR(100), Nature NVARCHAR(100), IncidentAt DATETIME, IncidentPlace NVARCHAR(300), BroughtBy NVARCHAR(200), BroughtByPhone NVARCHAR(40),
                                           PoliceStation NVARCHAR(200), OfficerName NVARCHAR(200), InformedAt DATETIME, Remarks NVARCHAR(600)) j
            WHERE m.AdmissionId = @AdmissionId;
        END
        -- an MLC record is never deleted (medico-legal); un-ticking only clears the flag

        -- dependencies of the change (SQLScripts/2476)
        DECLARE @tariffRepriced INT = 0, @tariffKept INT = 0, @phRepriced INT = 0;
        IF ISNULL(@PackageId, 0) <> ISNULL(@oldPkg, 0) EXEC dbo.usp_Ipd_ApplyPackageFlags @AdmissionId = @AdmissionId;
        IF @TariffCategoryId <> @oldTc
            EXEC dbo.usp_Ipd_RepriceTariff @AdmissionId = @AdmissionId, @Repriced = @tariffRepriced OUTPUT, @Kept = @tariffKept OUTPUT;
        SELECT @newPt = PriceType FROM dbo.fn_Ipd_PhPriceType(@AdmissionId);
        IF @newPt <> @oldPt EXEC dbo.usp_Ipd_RepricePharmacy @AdmissionId = @AdmissionId, @CompanyId = @CompanyId, @Repriced = @phRepriced OUTPUT;
        IF ISNULL(@PackageId, 0) <> ISNULL(@oldPkg, 0)
            INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
            VALUES (@AdmissionId, 'PACKAGE', CONCAT(N'Package ', ISNULL((SELECT Package_Name FROM dbo.HospitalPackageMaster WHERE HospitalPackage_ID = @oldPkg), N'none'), N' → ',
                    ISNULL((SELECT Package_Name FROM dbo.HospitalPackageMaster WHERE HospitalPackage_ID = @PackageId), N'none'), N' (edit admission)',
                    ISNULL(N': ' + NULLIF(LTRIM(RTRIM(@PackageReason)), N''), N'')), @UserId);

        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'EDIT', CONCAT(N'Admission details updated',
                CASE WHEN @TariffCategoryId <> @oldTc THEN N'; tariff category ' + ISNULL(@oldTcName, N'?') + N' → ' + ISNULL(@newTcName, N'?') END,
                CASE WHEN @PayerType <> @oldPayer THEN N'; payer ' + @oldPayer + N' → ' + @PayerType END,
                CASE WHEN @ConsultantDoctorId <> @oldCon THEN N'; consultant ' + ISNULL((SELECT FullName FROM dbo.DoctorMaster WHERE DoctorId = @oldCon), N'?') + N' → ' + ISNULL((SELECT FullName FROM dbo.DoctorMaster WHERE DoctorId = @ConsultantDoctorId), N'?') END,
                CASE WHEN @AdmittingDoctorId <> @oldAdm THEN N'; admitting doctor ' + ISNULL((SELECT FullName FROM dbo.DoctorMaster WHERE DoctorId = @oldAdm), N'?') + N' → ' + ISNULL((SELECT FullName FROM dbo.DoctorMaster WHERE DoctorId = @AdmittingDoctorId), N'?') END,
                CASE WHEN ISNULL(NULLIF(@DepartmentId, 0), 0) <> ISNULL(@oldDept, 0) THEN N'; department ' + ISNULL((SELECT DeptName FROM dbo.DepartmentMaster WHERE DeptId = @oldDept), N'none') + N' → ' + ISNULL((SELECT DeptName FROM dbo.DepartmentMaster WHERE DeptId = NULLIF(@DepartmentId, 0)), N'none') END,
                CASE WHEN @tariffRepriced + @tariffKept > 0 THEN CONCAT(N'; ', @tariffRepriced, N' charge(s) re-priced to the new tariff', CASE WHEN @tariffKept > 0 THEN CONCAT(N', ', @tariffKept, N' kept (edited rate or no rate in the new tariff)') END) END,
                CASE WHEN @phRepriced > 0 THEN CONCAT(N'; ', @phRepriced, N' pharmacy line(s) re-priced for the new payer') END), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @AdmissionId AS AdmissionId,
               @tariffRepriced AS TariffRepriced, @tariffKept AS TariffKept, @phRepriced AS PharmacyRepriced,
               CAST(CASE WHEN ISNULL(@PackageId, 0) <> ISNULL(@oldPkg, 0) THEN 1 ELSE 0 END AS BIT) AS PackageChanged;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO
PRINT '2476 IPD edit admission dependencies - done.';
GO
