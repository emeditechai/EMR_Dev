-- ============================================================
-- 27_api_stored_procedures.sql
-- Stored Procedures used by EMR.Api REST API
-- Run once against the Dev_EMR database
-- All procedures are CREATE OR ALTER (safe to re-run)
-- ============================================================

-- ══════════════════════════════════════════════════════════
--  DOCTOR PROCEDURES
-- ══════════════════════════════════════════════════════════

-- ── 1. usp_Api_Doctor_GetList ─────────────────────────────
-- GET /api/doctors?branchId=X
-- Returns all active/inactive doctors for a branch (or all if branchId IS NULL)
GO
SET QUOTED_IDENTIFIER ON
SET ANSI_NULLS ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_Doctor_GetList
    @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        d.DoctorId,
        d.FullName,
        ps.SpecialityName                    AS PrimarySpecialityName,
        ISNULL(dep.DepartmentNames, '')       AS DepartmentNames,
        d.PhoneNumber,
        d.EmailId,
        d.IsActive,
        ISNULL(fees.ConsultingFeeNames, '')   AS ConsultingFeeNames,
        CAST(CASE WHEN EXISTS (
            SELECT 1
            FROM DoctorDepartmentMap ddm2
            INNER JOIN DepartmentMaster dm2 ON dm2.DeptId = ddm2.DeptId
            WHERE ddm2.DoctorId = d.DoctorId
              AND ddm2.IsActive = 1
              AND dm2.DeptType  = 'OPD'
        ) THEN 1 ELSE 0 END AS BIT)           AS HasOPDDept
    FROM DoctorMaster d
    INNER JOIN DoctorSpecialityMaster ps ON ps.SpecialityId = d.PrimarySpecialityId
    OUTER APPLY (
        SELECT STUFF((
            SELECT ', ' + dm.DeptName
            FROM DoctorDepartmentMap ddm
            INNER JOIN DepartmentMaster dm ON dm.DeptId = ddm.DeptId
            WHERE ddm.DoctorId = d.DoctorId AND ddm.IsActive = 1
            FOR XML PATH(''), TYPE
        ).value('.','NVARCHAR(MAX)'), 1, 2, '') AS DepartmentNames
    ) dep
    OUTER APPLY (
        SELECT STUFF((
            SELECT ', ' + s.ItemName
                   + ' (₹' + CAST(CAST(s.ItemCharges AS DECIMAL(18,0)) AS NVARCHAR) + ')'
            FROM DoctorConsultingFeeMap m
            INNER JOIN ServiceMaster s ON s.ServiceId = m.ServiceId
            WHERE m.DoctorId = d.DoctorId
              AND m.BranchId = ISNULL(@BranchId, m.BranchId)
              AND m.IsActive = 1
            FOR XML PATH(''), TYPE
        ).value('.','NVARCHAR(MAX)'), 1, 2, '') AS ConsultingFeeNames
    ) fees
    WHERE @BranchId IS NULL
       OR d.CreatedBranchId = @BranchId
       OR EXISTS (
            SELECT 1 FROM DoctorBranchMap dbm
            WHERE dbm.DoctorId = d.DoctorId
              AND dbm.BranchId = @BranchId
              AND dbm.IsActive = 1
       )
    ORDER BY d.FullName;
END
GO

-- ── 2. usp_Api_Doctor_GetById ─────────────────────────────
-- GET /api/doctors/{id}
-- Returns 3 result sets:
--   RS1: DoctorDetail row
--   RS2: BranchIds  (INT list)
--   RS3: DepartmentIds (INT list)
GO
SET QUOTED_IDENTIFIER ON
SET ANSI_NULLS ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_Doctor_GetById
    @DoctorId INT,
    @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- RS1: Doctor detail
    SELECT
        d.DoctorId,
        d.FullName,
        d.Gender,
        d.DateOfBirth,
        d.EmailId,
        d.PhoneNumber,
        d.MedicalLicenseNo,
        d.PrimarySpecialityId,
        ps.SpecialityName  AS PrimarySpeciality,
        d.SecondarySpecialityId,
        ss.SpecialityName  AS SecondarySpeciality,
        d.JoiningDate,
        d.IsActive,
        d.CreatedBranchId,
        d.CreatedDate,
        d.ModifiedDate
    FROM DoctorMaster d
    INNER JOIN DoctorSpecialityMaster ps ON ps.SpecialityId = d.PrimarySpecialityId
    LEFT  JOIN DoctorSpecialityMaster ss ON ss.SpecialityId = d.SecondarySpecialityId
    WHERE d.DoctorId = @DoctorId
      AND (@BranchId IS NULL
           OR d.CreatedBranchId = @BranchId
           OR EXISTS (SELECT 1 FROM DoctorBranchMap dbm
                      WHERE dbm.DoctorId = d.DoctorId AND dbm.BranchId = @BranchId AND dbm.IsActive = 1));

    -- RS2: Branch IDs
    SELECT BranchId FROM DoctorBranchMap
    WHERE DoctorId = @DoctorId AND IsActive = 1;

    -- RS3: Department IDs
    SELECT DeptId FROM DoctorDepartmentMap
    WHERE DoctorId = @DoctorId AND IsActive = 1;
END
GO

-- ── 3. usp_Api_Doctor_Create ──────────────────────────────
-- POST /api/doctors
-- Inserts DoctorMaster, returns new DoctorId
GO
SET QUOTED_IDENTIFIER ON
SET ANSI_NULLS ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_Doctor_Create
    @FullName              NVARCHAR(150),
    @Gender                NVARCHAR(20),
    @DateOfBirth           DATE         = NULL,
    @EmailId               NVARCHAR(150),
    @PhoneNumber           NVARCHAR(20),
    @MedicalLicenseNo      NVARCHAR(80) = NULL,
    @PrimarySpecialityId   INT,
    @SecondarySpecialityId INT          = NULL,
    @JoiningDate           DATE         = NULL,
    @IsActive              BIT          = 1,
    @CreatedBranchId       INT,
    @UserId                INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO DoctorMaster
        (FullName, Gender, DateOfBirth, EmailId, PhoneNumber,
         MedicalLicenseNo, PrimarySpecialityId, SecondarySpecialityId,
         JoiningDate, IsActive, CreatedBranchId, CreatedBy, CreatedDate)
    VALUES
        (@FullName, @Gender, @DateOfBirth, @EmailId, @PhoneNumber,
         @MedicalLicenseNo, @PrimarySpecialityId, @SecondarySpecialityId,
         @JoiningDate, @IsActive, @CreatedBranchId, @UserId, GETDATE());

    SELECT CAST(SCOPE_IDENTITY() AS INT);
END
GO

-- ── 4. usp_Api_Doctor_Update ──────────────────────────────
-- PUT /api/doctors/{id}
-- Updates DoctorMaster, returns rows affected
GO
SET QUOTED_IDENTIFIER ON
SET ANSI_NULLS ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_Doctor_Update
    @DoctorId              INT,
    @FullName              NVARCHAR(150),
    @Gender                NVARCHAR(20),
    @DateOfBirth           DATE         = NULL,
    @EmailId               NVARCHAR(150),
    @PhoneNumber           NVARCHAR(20),
    @MedicalLicenseNo      NVARCHAR(80) = NULL,
    @PrimarySpecialityId   INT,
    @SecondarySpecialityId INT          = NULL,
    @JoiningDate           DATE         = NULL,
    @IsActive              BIT          = 1,
    @UserId                INT          = NULL
AS
BEGIN
    SET NOCOUNT OFF;   -- @@ROWCOUNT / rows-affected must flow back

    UPDATE DoctorMaster SET
        FullName              = @FullName,
        Gender                = @Gender,
        DateOfBirth           = @DateOfBirth,
        EmailId               = @EmailId,
        PhoneNumber           = @PhoneNumber,
        MedicalLicenseNo      = @MedicalLicenseNo,
        PrimarySpecialityId   = @PrimarySpecialityId,
        SecondarySpecialityId = @SecondarySpecialityId,
        JoiningDate           = @JoiningDate,
        IsActive              = @IsActive,
        ModifiedBy            = @UserId,
        ModifiedDate          = GETDATE()
    WHERE DoctorId = @DoctorId;
END
GO


-- ══════════════════════════════════════════════════════════
--  PATIENT PROCEDURES
-- ══════════════════════════════════════════════════════════

-- ── 5. usp_Api_Patient_GetByBranch ───────────────────────
-- GET /api/patients?branchId=X&page=1&pageSize=20&search=
-- Returns paged patient list with TotalCount for X-Pagination header
GO
SET QUOTED_IDENTIFIER ON
SET ANSI_NULLS ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_Patient_GetByBranch
    @BranchId   INT          = NULL,
    @Search     NVARCHAR(100) = NULL,
    @PageNumber INT           = 1,
    @PageSize   INT           = 20
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;
    DECLARE @SearchPat NVARCHAR(102) = '%' + ISNULL(@Search,'') + '%';

    SELECT
        p.PatientId,
        p.PatientCode,
        LTRIM(RTRIM(
            ISNULL(p.Salutation + ' ','') +
            p.FirstName + ' ' +
            ISNULL(p.MiddleName + ' ','') +
            p.LastName
        ))                    AS FullName,
        p.PhoneNumber,
        p.Gender,
        p.DateOfBirth,
        p.BloodGroup,
        p.Address,
        p.BranchId,
        p.IsActive,
        p.CreatedDate,
        COUNT(*) OVER()       AS TotalCount
    FROM PatientMaster p
    WHERE p.IsActive = 1
      AND (@BranchId IS NULL OR p.BranchId = @BranchId)
      AND (@Search   IS NULL OR @Search = ''
           OR p.PhoneNumber LIKE @SearchPat
           OR p.PatientCode LIKE @SearchPat
           OR p.FirstName   LIKE @SearchPat
           OR p.LastName     LIKE @SearchPat
           OR LTRIM(RTRIM(p.FirstName + ' ' + ISNULL(p.MiddleName+' ','') + p.LastName)) LIKE @SearchPat)
    ORDER BY p.CreatedDate DESC
    OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- ── 6. usp_Api_Patient_GetById ────────────────────────────
-- GET /api/patients/{id}
-- Returns full patient detail including relation name + last OPD bill no
GO
SET QUOTED_IDENTIFIER ON
SET ANSI_NULLS ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_Patient_GetById
    @PatientId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        p.PatientId,
        p.PatientCode,
        LTRIM(RTRIM(
            ISNULL(p.Salutation + ' ','') +
            p.FirstName + ' ' +
            ISNULL(p.MiddleName + ' ','') +
            p.LastName
        ))                          AS FullName,
        p.Salutation,
        p.FirstName,
        p.MiddleName,
        p.LastName,
        p.PhoneNumber,
        p.SecondaryPhoneNumber,
        p.Gender,
        p.DateOfBirth,
        p.BloodGroup,
        p.EmailId,
        p.GuardianName,
        p.Address,
        p.BranchId,
        p.IsActive,
        p.RelationId,
        r.RelationName,
        p.KnownAllergies,
        p.Remarks,
        p.CreatedDate,
        (SELECT TOP 1 OPDBillNo
         FROM PatientOPDService
         WHERE PatientId = p.PatientId
         ORDER BY CreatedDate DESC)  AS LastOpdBillNo
    FROM PatientMaster p
    LEFT JOIN RelationMaster r ON r.RelationId = p.RelationId
    WHERE p.PatientId = @PatientId;
END
GO

-- ── 7. usp_Api_Patient_Create ─────────────────────────────
-- POST /api/patients
-- Inserts PatientMaster, returns new PatientId
GO
SET QUOTED_IDENTIFIER ON
SET ANSI_NULLS ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_Patient_Create
    @PhoneNumber            NVARCHAR(15),
    @SecondaryPhoneNumber   NVARCHAR(15)   = NULL,
    @Salutation             NVARCHAR(10)   = NULL,
    @FirstName              NVARCHAR(100),
    @MiddleName             NVARCHAR(100)  = NULL,
    @LastName               NVARCHAR(100),
    @Gender                 NVARCHAR(10),
    @DateOfBirth            DATE           = NULL,
    @EmailId                NVARCHAR(150)  = NULL,
    @GuardianName           NVARCHAR(200)  = NULL,
    @Address                NVARCHAR(500)  = NULL,
    @RelationId             INT            = NULL,
    @BloodGroup             NVARCHAR(10)   = NULL,
    @KnownAllergies         NVARCHAR(500)  = NULL,
    @Remarks                NVARCHAR(1000) = NULL,
    @BranchId               INT            = NULL,
    @UserId                 INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Auto-generate patient code: BR-YYYYMMDD-NNNN (simple sequential per branch)
    DECLARE @PatientCode NVARCHAR(30);
    DECLARE @Seq INT;

    SELECT @Seq = ISNULL(MAX(CAST(SUBSTRING(PatientCode, LEN(PatientCode)-3, 4) AS INT)), 0) + 1
    FROM PatientMaster
    WHERE BranchId = @BranchId
      AND PatientCode LIKE '%-%';

    SET @PatientCode = ISNULL(CAST(@BranchId AS NVARCHAR), 'GEN')
                    + '-' + CONVERT(NVARCHAR, GETDATE(), 112)
                    + '-' + RIGHT('0000' + CAST(@Seq AS NVARCHAR), 4);

    INSERT INTO PatientMaster
        (PatientCode, PhoneNumber, SecondaryPhoneNumber, Salutation,
         FirstName, MiddleName, LastName, Gender, DateOfBirth,
         EmailId, GuardianName, Address, RelationId,
         BloodGroup, KnownAllergies, Remarks, BranchId,
         IsActive, CreatedBy, CreatedDate)
    VALUES
        (@PatientCode, @PhoneNumber, @SecondaryPhoneNumber, @Salutation,
         @FirstName, @MiddleName, @LastName, @Gender, @DateOfBirth,
         @EmailId, @GuardianName, @Address, @RelationId,
         @BloodGroup, @KnownAllergies, @Remarks, @BranchId,
         1, @UserId, GETDATE());

    SELECT CAST(SCOPE_IDENTITY() AS INT);
END
GO

-- ── 8. usp_Api_Patient_Update ─────────────────────────────
-- PUT /api/patients/{id}
-- Updates PatientMaster, returns rows affected
GO
SET QUOTED_IDENTIFIER ON
SET ANSI_NULLS ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_Patient_Update
    @PatientId              INT,
    @PhoneNumber            NVARCHAR(15),
    @SecondaryPhoneNumber   NVARCHAR(15)   = NULL,
    @Salutation             NVARCHAR(10)   = NULL,
    @FirstName              NVARCHAR(100),
    @MiddleName             NVARCHAR(100)  = NULL,
    @LastName               NVARCHAR(100),
    @Gender                 NVARCHAR(10),
    @DateOfBirth            DATE           = NULL,
    @EmailId                NVARCHAR(150)  = NULL,
    @GuardianName           NVARCHAR(200)  = NULL,
    @Address                NVARCHAR(500)  = NULL,
    @RelationId             INT            = NULL,
    @BloodGroup             NVARCHAR(10)   = NULL,
    @KnownAllergies         NVARCHAR(500)  = NULL,
    @Remarks                NVARCHAR(1000) = NULL,
    @UserId                 INT            = NULL
AS
BEGIN
    SET NOCOUNT OFF;

    UPDATE PatientMaster SET
        PhoneNumber          = @PhoneNumber,
        SecondaryPhoneNumber = @SecondaryPhoneNumber,
        Salutation           = @Salutation,
        FirstName            = @FirstName,
        MiddleName           = @MiddleName,
        LastName             = @LastName,
        Gender               = @Gender,
        DateOfBirth          = @DateOfBirth,
        EmailId              = @EmailId,
        GuardianName         = @GuardianName,
        Address              = @Address,
        RelationId           = @RelationId,
        BloodGroup           = @BloodGroup,
        KnownAllergies       = @KnownAllergies,
        Remarks              = @Remarks,
        ModifiedBy           = @UserId,
        ModifiedDate         = GETDATE()
    WHERE PatientId = @PatientId;
END
GO
