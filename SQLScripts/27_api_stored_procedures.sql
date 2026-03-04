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
    @BranchId   INT           = NULL,
    @Search     NVARCHAR(100) = NULL,
    @PageNumber INT           = 1,
    @PageSize   INT           = 20
AS
BEGIN
    SET NOCOUNT ON;

    -- Normalise inputs
    SET @PageNumber = ISNULL(@PageNumber, 1);
    SET @PageSize   = ISNULL(@PageSize,   20);
    IF @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize   < 1 SET @PageSize   = 20;
    IF @Search = '' SET @Search = NULL;

    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;

    SELECT
        p.PatientId,
        p.PatientCode,
        LTRIM(RTRIM(
            ISNULL(p.Salutation + ' ', '') +
            p.FirstName + ' ' +
            ISNULL(p.MiddleName + ' ', '') +
            p.LastName
        ))                       AS FullName,
        p.PhoneNumber,
        p.Gender,
        p.DateOfBirth,
        p.BloodGroup,
        p.Address,
        p.BranchId,
        p.IsActive,
        p.CreatedDate,
        d.FullName               AS ConsultingDoctorName,
        COUNT(*) OVER()          AS TotalCount
    FROM PatientMaster p
    OUTER APPLY (
        SELECT TOP 1 ConsultingDoctorId
        FROM PatientOPDService
        WHERE PatientId = p.PatientId AND IsActive = 1
        ORDER BY OPDServiceId DESC
    ) latest
    LEFT JOIN DoctorMaster d ON d.DoctorId = latest.ConsultingDoctorId
    WHERE p.IsActive = 1
      AND (@BranchId IS NULL OR p.BranchId = @BranchId)
      AND (
            @Search IS NULL
            OR p.PatientCode LIKE '%' + @Search + '%'
            OR p.FirstName   LIKE '%' + @Search + '%'
            OR p.LastName    LIKE '%' + @Search + '%'
            OR p.PhoneNumber LIKE '%' + @Search + '%'
            OR LTRIM(RTRIM(p.FirstName + ' ' + ISNULL(p.MiddleName+' ','') + p.LastName)) LIKE '%' + @Search + '%'
          )
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


-- ══════════════════════════════════════════════════════════
--  SERVICE BOOKING PROCEDURES
-- ══════════════════════════════════════════════════════════

-- ── 9. usp_Api_ServiceBooking_GetByBranch ─────────────────
-- GET /api/servicebookings?branchId=&fromDate=&toDate=&page=&pageSize=&search=
-- Paged list + aggregate stat columns (TotalCount, TotalFeesAll,
-- RegisteredCount, CompletedCount) — mirrors usp_GetServiceBookingsPaged
GO
SET QUOTED_IDENTIFIER ON
SET ANSI_NULLS ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_ServiceBooking_GetByBranch
    @BranchId   INT            = NULL,
    @FromDate   DATE           = NULL,
    @ToDate     DATE           = NULL,
    @PageNumber INT            = 1,
    @PageSize   INT            = 10,
    @Search     NVARCHAR(100)  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Normalise inputs
    SET @PageNumber = ISNULL(@PageNumber, 1);
    SET @PageSize   = ISNULL(@PageSize,  10);
    IF @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize   < 1 SET @PageSize   = 10;
    IF @Search = '' SET @Search = NULL;

    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;

    SELECT
        s.OPDServiceId,
        s.VisitDate,
        s.OPDBillNo,
        s.TokenNo,
        p.PatientCode,
        p.PatientId,
        LTRIM(RTRIM(
            ISNULL(p.Salutation + ' ', '') +
            p.FirstName + ' ' +
            ISNULL(p.MiddleName + ' ', '') +
            p.LastName
        ))                           AS PatientName,
        p.Gender,
        CASE
            WHEN p.DateOfBirth IS NULL THEN NULL
            ELSE DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
                 - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END
        END                          AS Age,
        d.FullName                   AS ConsultingDoctorName,
        ISNULL(s.TotalAmount, 0)     AS TotalAmount,
        s.Status,
        ISNULL(
            STUFF((
                SELECT DISTINCT ', ' + ISNULL(si.ServiceType, '')
                FROM PatientOPDServiceItem si
                WHERE si.OPDServiceId = s.OPDServiceId AND si.IsActive = 1
                FOR XML PATH(''), TYPE
            ).value('.','NVARCHAR(MAX)'), 1, 2, ''), ''
        )                            AS ServiceTypesSummary,
        -- ── Aggregate window columns ─────────────────────────────────
        COUNT(*)                     OVER() AS TotalCount,
        SUM(ISNULL(s.TotalAmount,0)) OVER() AS TotalFeesAll,
        SUM(CASE WHEN s.Status = 'Registered' THEN 1 ELSE 0 END) OVER() AS RegisteredCount,
        SUM(CASE WHEN s.Status = 'Completed'  THEN 1 ELSE 0 END) OVER() AS CompletedCount
    FROM PatientOPDService s
    INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
    LEFT  JOIN DoctorMaster  d ON d.DoctorId  = s.ConsultingDoctorId
    WHERE s.IsActive = 1
      AND p.IsActive = 1
      AND (@BranchId IS NULL OR s.BranchId = @BranchId)
      AND (@FromDate IS NULL OR CAST(s.VisitDate AS DATE) >= @FromDate)
      AND (@ToDate   IS NULL OR CAST(s.VisitDate AS DATE) <= @ToDate)
      AND (
            @Search IS NULL
            OR p.PatientCode LIKE '%' + @Search + '%'
            OR p.FirstName   LIKE '%' + @Search + '%'
            OR p.LastName    LIKE '%' + @Search + '%'
            OR p.PhoneNumber LIKE '%' + @Search + '%'
            OR s.OPDBillNo   LIKE '%' + @Search + '%'
          )
    ORDER BY s.OPDServiceId DESC
    OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- ── 10. usp_Api_ServiceBooking_GetById ────────────────────
-- GET /api/servicebookings/{id}
-- Returns header + line items (2 result sets)
GO
SET QUOTED_IDENTIFIER ON
SET ANSI_NULLS ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_ServiceBooking_GetById
    @OPDServiceId INT
AS
BEGIN
    SET NOCOUNT ON;

    -- RS1: Header
    SELECT
        s.OPDServiceId,
        s.OPDBillNo,
        s.TokenNo,
        p.PatientCode,
        LTRIM(RTRIM(
            ISNULL(p.Salutation + ' ', '') +
            p.FirstName + ' ' +
            ISNULL(p.MiddleName + ' ', '') +
            p.LastName
        ))                        AS PatientName,
        p.PhoneNumber,
        p.Gender,
        p.DateOfBirth,
        d.FullName                AS ConsultingDoctorName,
        s.VisitDate,
        ISNULL(s.TotalAmount, 0)  AS TotalAmount,
        s.Status
    FROM PatientOPDService s
    INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
    LEFT  JOIN DoctorMaster  d ON d.DoctorId  = s.ConsultingDoctorId
    WHERE s.OPDServiceId = @OPDServiceId;

    -- RS2: Line items
    SELECT
        si.ServiceType,
        ISNULL(sm.ItemName, '(Unknown)') AS ItemName,
        ISNULL(si.ServiceCharges, 0)     AS ServiceCharges
    FROM PatientOPDServiceItem si
    LEFT JOIN ServiceMaster sm ON sm.ServiceId = si.ServiceId
    WHERE si.OPDServiceId = @OPDServiceId AND si.IsActive = 1
    ORDER BY si.ItemId;
END
GO


-- ══════════════════════════════════════════════════════════
--  PAYMENT SUMMARY PROCEDURE
-- ══════════════════════════════════════════════════════════

-- ── 11. usp_Api_PaymentSummary_GetByBill ──────────────────
-- GET /api/paymentsummary?moduleCode=OPD&moduleRefId={id}
-- Returns 3 result sets:
--   RS1: Bill header + patient info
--   RS2: Line items
--   RS3: Existing payment header (if any)
GO
SET QUOTED_IDENTIFIER ON
SET ANSI_NULLS ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_PaymentSummary_GetByBill
    @ModuleCode  NVARCHAR(20),
    @ModuleRefId INT
AS
BEGIN
    SET NOCOUNT ON;

    -- RS1: Bill header + patient info
    SELECT
        s.OPDServiceId          AS ModuleRefId,
        'OPD'                   AS ModuleCode,
        s.OPDServiceId,
        s.OPDBillNo,
        s.TokenNo,
        p.PatientId,
        p.PatientCode,
        (p.FirstName + ' ' + ISNULL(p.LastName, '')) AS PatientName,
        p.PhoneNumber           AS PatientPhone,
        ISNULL(s.BranchId, 0)  AS BranchId,
        ISNULL(s.TotalAmount, 0) AS SubTotal
    FROM PatientOPDService s
    INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
    WHERE s.OPDServiceId = @ModuleRefId;

    -- RS2: Line items
    SELECT
        si.ItemId               AS LineRefId,
        si.ServiceType,
        ISNULL(sm.ItemName, '(Unknown)') AS ItemName,
        ISNULL(si.ServiceCharges, 0)     AS OriginalAmount,
        0                                AS LineDiscountAmount,
        ISNULL(si.ServiceCharges, 0)     AS NetLineAmount
    FROM PatientOPDServiceItem si
    LEFT JOIN ServiceMaster sm ON sm.ServiceId = si.ServiceId
    WHERE si.OPDServiceId = @ModuleRefId AND si.IsActive = 1
    ORDER BY si.ItemId;

    -- RS3: Existing payment header (if any)
    SELECT
        PaymentHeaderId,
        ISNULL(LineDiscountTotal, 0)      AS LineDiscountTotal,
        HeaderDiscountType,
        HeaderDiscountValue,
        ISNULL(HeaderDiscountAmount, 0)   AS HeaderDiscountAmount,
        ISNULL(NetAmount, 0)              AS NetAmount,
        ISNULL(TotalPaid, 0)              AS TotalPaid,
        ISNULL(BalanceDue, 0)             AS BalanceDue,
        ISNULL(PaymentStatus, 'U')        AS PaymentStatus
    FROM PaymentHeader
    WHERE ModuleCode = @ModuleCode
      AND ModuleRefId = @ModuleRefId
      AND IsActive = 1;
END
GO
