-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2438  IPD Phase 4 · OPD integration: admission advice from the OPD consultation
--   OPD > Doctor Dashboard > consultation > "Advise Admission" (control ADVISE_ADMISSION of OPD.DOCTORDASHBOARD):
--   reason, provisional diagnosis (ICD-10), urgency, expected admission, IPD department. The OPD registration and
--   consultation flows are not changed (one button and an IPD script on the consultation screen).
--   IPD Dashboard lists the pending advice; "Admit" opens New Admission filled from it (patient, OPD visit, source OPD,
--   doctor, department, diagnosis); the admission marks it ADMITTED (2423). Cancel with a reason.
--   usp_Api_IpdAdvice_Save, _List, _Get, _Cancel. Needs 2422-2437. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
IF OBJECT_ID('dbo.IpdAdmissionAdvice', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IpdAdmissionAdvice
    (
        AdviceId           INT IDENTITY(1,1) CONSTRAINT PK_IpdAdmissionAdvice PRIMARY KEY,
        CompanyId          INT            NOT NULL,
        BranchId           INT            NOT NULL,
        PatientId          INT            NOT NULL,
        OpdServiceId       INT            NULL,
        DoctorId           INT            NULL,
        DepartmentId       INT            NULL,
        Urgency            VARCHAR(10)    NOT NULL,   -- ROUTINE URGENT EMERGENCY
        ExpectedAt         DATETIME       NULL,
        Reason             NVARCHAR(500)  NOT NULL,
        Diagnosis          NVARCHAR(500)  NULL,
        DiagnosisCode      NVARCHAR(20)   NULL,
        Remarks            NVARCHAR(300)  NULL,
        Status             VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdAdvice_Status DEFAULT ('PENDING'),   -- PENDING ADMITTED CANCELLED
        AdmissionId        INT            NULL,
        CancelReason       NVARCHAR(300)  NULL,
        CreatedBy          INT            NULL,
        CreatedDate        DATETIME       NOT NULL CONSTRAINT DF_IpdAdvice_Created DEFAULT (GETDATE()),
        ModifiedBy         INT            NULL,
        ModifiedDate       DATETIME       NULL,
        CONSTRAINT CK_IpdAdvice_Urgency CHECK (Urgency IN ('ROUTINE', 'URGENT', 'EMERGENCY')),
        CONSTRAINT CK_IpdAdvice_Status CHECK (Status IN ('PENDING', 'ADMITTED', 'CANCELLED'))
    );
    -- one pending advice per patient
    CREATE UNIQUE INDEX UX_IpdAdvice_Pending ON dbo.IpdAdmissionAdvice (PatientId) WHERE Status = 'PENDING';
    CREATE INDEX IX_IpdAdvice_Branch ON dbo.IpdAdmissionAdvice (BranchId, Status, CreatedDate);
END
GO

-- from the OPD consultation: a new advice, or the patient's pending one updated
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdvice_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @OpdServiceId INT, @Reason NVARCHAR(500), @Diagnosis NVARCHAR(500) = NULL, @DiagnosisCode NVARCHAR(20) = NULL,
    @Urgency VARCHAR(10) = 'ROUTINE', @ExpectedAt DATETIME = NULL, @DepartmentId INT = NULL, @Remarks NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @msg NVARCHAR(400);
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 55201, 'Enter the reason for admission.', 1;
        SET @Urgency = ISNULL(NULLIF(UPPER(@Urgency), ''), 'ROUTINE');
        IF @Urgency NOT IN ('ROUTINE', 'URGENT', 'EMERGENCY') THROW 55202, 'Choose the urgency.', 1;
        DECLARE @patient INT, @doctor INT;
        SELECT @patient = PatientId, @doctor = ConsultingDoctorId FROM dbo.PatientOPDService WHERE OPDServiceId = @OpdServiceId AND BranchId = @BranchId;
        IF @patient IS NULL THROW 55203, 'The OPD visit was not found in this branch.', 1;
        IF @ExpectedAt IS NOT NULL AND @ExpectedAt < DATEADD(DAY, -1, GETDATE()) THROW 55204, 'The expected admission cannot be in the past.', 1;
        IF @DepartmentId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.DepartmentMaster WHERE DeptId = @DepartmentId AND IsActive = 1 AND DeptType = 'IPD')
            THROW 55205, 'Choose an IPD department.', 1;
        DECLARE @openIp NVARCHAR(40) = (SELECT TOP 1 IpNo FROM dbo.IpdAdmission WHERE PatientId = @patient AND IsOpen = 1);
        IF @openIp IS NOT NULL BEGIN SET @msg = N'The patient is already admitted (' + @openIp + N').'; THROW 55206, @msg, 1; END;
        DECLARE @id INT = (SELECT AdviceId FROM dbo.IpdAdmissionAdvice WITH (UPDLOCK) WHERE PatientId = @patient AND Status = 'PENDING');
        IF @id IS NULL
        BEGIN
            INSERT dbo.IpdAdmissionAdvice (CompanyId, BranchId, PatientId, OpdServiceId, DoctorId, DepartmentId, Urgency, ExpectedAt, Reason, Diagnosis, DiagnosisCode, Remarks, CreatedBy)
            VALUES (@CompanyId, @BranchId, @patient, @OpdServiceId, @doctor, @DepartmentId, @Urgency, @ExpectedAt, LTRIM(RTRIM(@Reason)), NULLIF(LTRIM(RTRIM(@Diagnosis)), N''),
                    NULLIF(UPPER(LTRIM(RTRIM(@DiagnosisCode))), N''), NULLIF(LTRIM(RTRIM(@Remarks)), N''), @UserId);
            SET @id = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
            UPDATE dbo.IpdAdmissionAdvice SET BranchId = @BranchId, OpdServiceId = @OpdServiceId, DoctorId = @doctor, DepartmentId = @DepartmentId, Urgency = @Urgency, ExpectedAt = @ExpectedAt,
                   Reason = LTRIM(RTRIM(@Reason)), Diagnosis = NULLIF(LTRIM(RTRIM(@Diagnosis)), N''), DiagnosisCode = NULLIF(UPPER(LTRIM(RTRIM(@DiagnosisCode))), N''),
                   Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N''), ModifiedBy = @UserId, ModifiedDate = GETDATE()
            WHERE AdviceId = @id;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @id AS AdviceId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdvice_List @CompanyId INT, @BranchId INT, @Status VARCHAR(10) = 'PENDING', @OpdServiceId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Status = NULLIF(@Status, '');
    SELECT v.AdviceId, v.PatientId, p.PatientCode, LTRIM(RTRIM(CONCAT(NULLIF(p.Salutation, '') + ' ', p.FirstName, ' ', p.LastName))) AS PatientName, p.Gender, p.PhoneNumber,
           dbo.fn_Ipd_AgeText(p.DateOfBirth, CAST(GETDATE() AS DATE)) AS AgeText, v.OpdServiceId, o.OPDBillNo AS OpdBillNo, v.DoctorId, d.FullName AS DoctorName,
           v.DepartmentId, dep.DeptName AS DepartmentName, v.Urgency, v.ExpectedAt, v.Reason, v.Diagnosis, v.DiagnosisCode, v.Remarks, v.Status, v.AdmissionId, a.IpNo,
           v.CancelReason, v.CreatedDate, u.FullName AS AdvisedBy
    FROM dbo.IpdAdmissionAdvice v
    JOIN dbo.PatientMaster p ON p.PatientId = v.PatientId
    LEFT JOIN dbo.PatientOPDService o ON o.OPDServiceId = v.OpdServiceId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = v.DoctorId
    LEFT JOIN dbo.DepartmentMaster dep ON dep.DeptId = v.DepartmentId
    LEFT JOIN dbo.IpdAdmission a ON a.AdmissionId = v.AdmissionId
    LEFT JOIN dbo.Users u ON u.Id = v.CreatedBy
    WHERE v.CompanyId = @CompanyId AND v.BranchId = @BranchId AND (@Status IS NULL OR v.Status = @Status) AND (@OpdServiceId IS NULL OR v.OpdServiceId = @OpdServiceId)
    ORDER BY CASE v.Urgency WHEN 'EMERGENCY' THEN 0 WHEN 'URGENT' THEN 1 ELSE 2 END, ISNULL(v.ExpectedAt, v.CreatedDate), v.AdviceId;
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdvice_Cancel @CompanyId INT, @BranchId INT, @UserId INT, @AdviceId INT, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON;
    IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL BEGIN SELECT CAST(0 AS BIT) AS Success, CAST(N'Enter the reason.' AS NVARCHAR(600)) AS Error; RETURN; END
    UPDATE dbo.IpdAdmissionAdvice SET Status = 'CANCELLED', CancelReason = LTRIM(RTRIM(@Reason)), ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE AdviceId = @AdviceId AND CompanyId = @CompanyId AND BranchId = @BranchId AND Status = 'PENDING';
    IF @@ROWCOUNT = 0 SELECT CAST(0 AS BIT) AS Success, CAST(N'The advice was not found or is no longer pending.' AS NVARCHAR(600)) AS Error;
    ELSE SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdvice_Departments @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DeptId, DeptName FROM dbo.DepartmentMaster WHERE IsActive = 1 AND DeptType = 'IPD' AND (CompanyId = @CompanyId OR CompanyId IS NULL) ORDER BY DeptName;
END;
GO

-- ── pages: OPD consultation button, IPD dashboard list ────────────────────────────────────────────────────────
SET NOCOUNT ON;
DECLARE @op INT = (SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'OPD.DOCTORDASHBOARD' AND CompanyId = 1),
        @ip INT = (SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'IPD.INDEX' AND CompanyId = 1),
        @ad INT = (SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'IPD.ADMISSION' AND CompanyId = 1), @v INT, @ctl INT;
SET @ctl = NULL;
EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @op, @Control_Code = 'ADVISE_ADMISSION', @Title = N'Advise admission (IPD) from the consultation', @Sort_Order = 90, @Control_ID = @ctl OUTPUT;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @op, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'IpdAdvice', @Action = N'Save', @Source = 'SEED';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @op, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdAdvice', @Action = N'ForVisit', @Source = 'SEED';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @op, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdAdvice', @Action = N'Departments', @Source = 'SEED';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @op, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdAdvice', @Action = N'Icd', @Source = 'SEED';
SELECT @v = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @ip AND Control_Code = 'VIEW';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @ip, @Control_ID = @v, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdAdvice', @Action = N'List', @Source = 'SEED';
SET @ctl = NULL;
EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @ad, @Control_Code = 'ADVICE_CANCEL', @Title = N'Cancel an OPD admission advice', @Sort_Order = 50, @Control_ID = @ctl OUTPUT;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @ad, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'IpdAdvice', @Action = N'Cancel', @Source = 'SEED';
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT '2438 IPD admission advice - done.';
GO
