-- ==============================================================================
-- 66_company_stored_procedures.sql
-- Updates all Stored Procedures to include @CompanyId support
-- ==============================================================================

SET QUOTED_IDENTIFIER ON
SET ANSI_NULLS ON
GO

-- 1. usp_Api_Doctor_GetList
CREATE OR ALTER PROCEDURE dbo.usp_Api_Doctor_GetList
    @CompanyId INT = NULL,
    @BranchId INT = NULL,
    @SearchQuery NVARCHAR(100) = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 10
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        COUNT(*) OVER() AS TotalCount,
        d.DoctorId,
        ISNULL(d.NamePrefix + ' ', '') + d.FullName AS FullName,
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
    WHERE (@CompanyId IS NULL OR d.CompanyId = @CompanyId)
      AND (
        @BranchId IS NULL
        OR d.CreatedBranchId = @BranchId
        OR EXISTS (
            SELECT 1 FROM DoctorBranchMap dbm
            WHERE dbm.DoctorId = d.DoctorId
              AND dbm.BranchId = @BranchId
              AND dbm.IsActive = 1
        )
    )
    AND (
        @SearchQuery IS NULL 
        OR d.FullName LIKE '%' + @SearchQuery + '%'
        OR d.PhoneNumber LIKE '%' + @SearchQuery + '%'
        OR d.EmailId LIKE '%' + @SearchQuery + '%'
        OR ps.SpecialityName LIKE '%' + @SearchQuery + '%'
    )
    ORDER BY d.IsActive DESC, ISNULL(d.NamePrefix + ' ', '') + d.FullName ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- 2. usp_Api_Doctor_GetById
CREATE OR ALTER PROCEDURE dbo.usp_Api_Doctor_GetById
    @DoctorId INT,
    @CompanyId INT = NULL,
    @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- RS1: Doctor detail
    SELECT
        d.DoctorId,
        d.CompanyId,
        d.NamePrefix,
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
      AND (@CompanyId IS NULL OR d.CompanyId = @CompanyId)
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

-- 3. usp_Api_Doctor_Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_Doctor_Create
    @CompanyId INT = 1,
    @NamePrefix NVARCHAR(10) = NULL,
    @FullName NVARCHAR(150),
    @Gender NVARCHAR(20),
    @DateOfBirth DATE = NULL,
    @EmailId NVARCHAR(150),
    @PhoneNumber NVARCHAR(20),
    @MedicalLicenseNo NVARCHAR(80) = NULL,
    @PrimarySpecialityId INT,
    @SecondarySpecialityId INT = NULL,
    @JoiningDate DATE = NULL,
    @IsActive BIT = 1,
    @CreatedBranchId INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF (@CompanyId IS NULL OR @CompanyId = 0)
    BEGIN
        SELECT @CompanyId = CompanyId FROM dbo.Branchmaster WHERE BranchID = @CreatedBranchId;
        IF (@CompanyId IS NULL) SET @CompanyId = 1;
    END

    INSERT INTO DoctorMaster
        (CompanyId, NamePrefix, FullName, Gender, DateOfBirth, EmailId, PhoneNumber,
         MedicalLicenseNo, PrimarySpecialityId, SecondarySpecialityId,
         JoiningDate, IsActive, CreatedBranchId, CreatedBy, CreatedDate)
    VALUES
        (@CompanyId, @NamePrefix, @FullName, @Gender, @DateOfBirth, @EmailId, @PhoneNumber,
         @MedicalLicenseNo, @PrimarySpecialityId, @SecondarySpecialityId,
         @JoiningDate, @IsActive, @CreatedBranchId, @UserId, GETDATE());

    SELECT CAST(SCOPE_IDENTITY() AS INT);
END
GO

-- 4. usp_Api_Doctor_Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_Doctor_Update
    @DoctorId INT,
    @CompanyId INT = NULL,
    @NamePrefix NVARCHAR(10) = NULL,
    @FullName NVARCHAR(150),
    @Gender NVARCHAR(20),
    @DateOfBirth DATE = NULL,
    @EmailId NVARCHAR(150),
    @PhoneNumber NVARCHAR(20),
    @MedicalLicenseNo NVARCHAR(80) = NULL,
    @PrimarySpecialityId INT,
    @SecondarySpecialityId INT = NULL,
    @JoiningDate DATE = NULL,
    @IsActive BIT = 1,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT OFF;

    UPDATE DoctorMaster SET
        NamePrefix = @NamePrefix,
        FullName = @FullName,
        Gender = @Gender,
        DateOfBirth = @DateOfBirth,
        EmailId = @EmailId,
        PhoneNumber = @PhoneNumber,
        MedicalLicenseNo = @MedicalLicenseNo,
        PrimarySpecialityId = @PrimarySpecialityId,
        SecondarySpecialityId = @SecondarySpecialityId,
        JoiningDate = @JoiningDate,
        IsActive = @IsActive,
        ModifiedBy = @UserId,
        ModifiedDate = GETDATE()
    WHERE DoctorId = @DoctorId
      AND (@CompanyId IS NULL OR CompanyId = @CompanyId);
END
GO

-- 5. usp_Api_Patient_GetByBranch
CREATE OR ALTER PROCEDURE dbo.usp_Api_Patient_GetByBranch
    @CompanyId INT = NULL,
    @BranchId INT = NULL,
    @PageNumber INT = 1,
    @PageSize INT = 10,
    @Search NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        COUNT(*) OVER() AS TotalCount,
        p.PatientId,
        p.PatientCode,
        p.Salutation,
        p.FirstName,
        p.MiddleName,
        p.LastName,
        ISNULL(p.FirstName + ' ', '') + ISNULL(p.MiddleName + ' ', '') + ISNULL(p.LastName, '') AS FullName,
        p.PhoneNumber,
        p.SecondaryPhoneNumber,
        p.Gender,
        p.DateOfBirth,
        p.EmailId,
        p.GuardianName,
        p.Address,
        p.RelationId,
        p.BloodGroup,
        p.KnownAllergies,
        p.Remarks,
        p.BranchId,
        p.CompanyId,
        p.PhotoPath,
        p.IsActive,
        p.CreatedDate,
        b.BranchName
    FROM PatientMaster p
    LEFT JOIN Branchmaster b ON b.BranchID = p.BranchId
    WHERE (@CompanyId IS NULL OR p.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR p.BranchId = @BranchId)
      AND (
        @Search IS NULL
        OR p.PatientCode LIKE '%' + @Search + '%'
        OR p.FirstName LIKE '%' + @Search + '%'
        OR p.LastName LIKE '%' + @Search + '%'
        OR p.PhoneNumber LIKE '%' + @Search + '%'
        OR p.EmailId LIKE '%' + @Search + '%'
      )
    ORDER BY p.PatientId DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- 6. usp_Api_Patient_GetById
CREATE OR ALTER PROCEDURE dbo.usp_Api_Patient_GetById
    @PatientId INT,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        p.PatientId,
        p.CompanyId,
        p.PatientCode,
        p.Salutation,
        p.FirstName,
        p.MiddleName,
        p.LastName,
        ISNULL(p.FirstName + ' ', '') + ISNULL(p.MiddleName + ' ', '') + ISNULL(p.LastName, '') AS FullName,
        p.PhoneNumber,
        p.SecondaryPhoneNumber,
        p.Gender,
        p.DateOfBirth,
        p.EmailId,
        p.GuardianName,
        p.Address,
        p.RelationId,
        p.BloodGroup,
        p.KnownAllergies,
        p.Remarks,
        p.BranchId,
        p.PhotoPath,
        p.IsActive,
        p.CreatedDate,
        p.Lastlogin,
        p.IsLoginGenerated,
        b.BranchName
    FROM PatientMaster p
    LEFT JOIN Branchmaster b ON b.BranchID = p.BranchId
    WHERE p.PatientId = @PatientId
      AND (@CompanyId IS NULL OR p.CompanyId = @CompanyId);
END
GO

-- 7. usp_Api_Patient_Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_Patient_Create
    @CompanyId INT = 1,
    @PhoneNumber NVARCHAR(15),
    @SecondaryPhoneNumber NVARCHAR(15) = NULL,
    @Salutation NVARCHAR(10) = NULL,
    @FirstName NVARCHAR(100),
    @MiddleName NVARCHAR(100) = NULL,
    @LastName NVARCHAR(100),
    @Gender NVARCHAR(10),
    @DateOfBirth DATE = NULL,
    @EmailId NVARCHAR(150) = NULL,
    @GuardianName NVARCHAR(200) = NULL,
    @Address NVARCHAR(500) = NULL,
    @RelationId INT = NULL,
    @BloodGroup NVARCHAR(10) = NULL,
    @KnownAllergies NVARCHAR(500) = NULL,
    @Remarks NVARCHAR(1000) = NULL,
    @BranchId INT = NULL,
    @PhotoPath NVARCHAR(500) = NULL,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF (@CompanyId IS NULL OR @CompanyId = 0)
    BEGIN
        IF @BranchId IS NOT NULL
            SELECT @CompanyId = CompanyId FROM dbo.Branchmaster WHERE BranchID = @BranchId;
        IF (@CompanyId IS NULL) SET @CompanyId = 1;
    END

    -- Generate Patient Code
    DECLARE @FY NVARCHAR(4) = CAST(YEAR(GETDATE()) AS NVARCHAR(4));
    DECLARE @NextSeq INT = 1;

    UPDATE PatientCodeCounter
    SET @NextSeq = LastSeq = LastSeq + 1
    WHERE BranchId = ISNULL(@BranchId, 1) AND FinancialYear = @FY;

    IF @@ROWCOUNT = 0
    BEGIN
        INSERT INTO PatientCodeCounter (CompanyId, BranchId, FinancialYear, LastSeq)
        VALUES (@CompanyId, ISNULL(@BranchId, 1), @FY, 1);
        SET @NextSeq = 1;
    END

    DECLARE @BranchCode NVARCHAR(10) = 'HO';
    IF @BranchId IS NOT NULL
        SELECT @BranchCode = BranchCode FROM Branchmaster WHERE BranchID = @BranchId;

    DECLARE @PatientCode NVARCHAR(30) = @BranchCode + '/' + @FY + '/' + RIGHT('00000' + CAST(@NextSeq AS NVARCHAR(10)), 5);

    INSERT INTO PatientMaster (
        CompanyId, PatientCode, PhoneNumber, SecondaryPhoneNumber, Salutation,
        FirstName, MiddleName, LastName, Gender, DateOfBirth,
        EmailId, GuardianName, Address, RelationId, BloodGroup,
        KnownAllergies, Remarks, BranchId, PhotoPath,
        IsActive, CreatedBy, CreatedDate
    ) VALUES (
        @CompanyId, @PatientCode, @PhoneNumber, @SecondaryPhoneNumber, @Salutation,
        @FirstName, @MiddleName, @LastName, @Gender, @DateOfBirth,
        @EmailId, @GuardianName, @Address, @RelationId, @BloodGroup,
        @KnownAllergies, @Remarks, @BranchId, @PhotoPath,
        1, @UserId, SYSUTCDATETIME()
    );

    SELECT SCOPE_IDENTITY() AS PatientId;
END
GO

-- 8. usp_Api_Patient_Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_Patient_Update
    @PatientId INT,
    @CompanyId INT = NULL,
    @PhoneNumber NVARCHAR(15),
    @SecondaryPhoneNumber NVARCHAR(15) = NULL,
    @Salutation NVARCHAR(10) = NULL,
    @FirstName NVARCHAR(100),
    @MiddleName NVARCHAR(100) = NULL,
    @LastName NVARCHAR(100),
    @Gender NVARCHAR(10),
    @DateOfBirth DATE = NULL,
    @EmailId NVARCHAR(150) = NULL,
    @GuardianName NVARCHAR(200) = NULL,
    @Address NVARCHAR(500) = NULL,
    @RelationId INT = NULL,
    @BloodGroup NVARCHAR(10) = NULL,
    @KnownAllergies NVARCHAR(500) = NULL,
    @Remarks NVARCHAR(1000) = NULL,
    @PhotoPath NVARCHAR(500) = NULL,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE PatientMaster SET
        PhoneNumber = @PhoneNumber,
        SecondaryPhoneNumber = @SecondaryPhoneNumber,
        Salutation = @Salutation,
        FirstName = @FirstName,
        MiddleName = @MiddleName,
        LastName = @LastName,
        Gender = @Gender,
        DateOfBirth = @DateOfBirth,
        EmailId = @EmailId,
        GuardianName = @GuardianName,
        Address = @Address,
        RelationId = @RelationId,
        BloodGroup = @BloodGroup,
        KnownAllergies = @KnownAllergies,
        Remarks = @Remarks,
        PhotoPath = ISNULL(@PhotoPath, PhotoPath),
        ModifiedBy = @UserId,
        ModifiedDate = SYSUTCDATETIME()
    WHERE PatientId = @PatientId
      AND (@CompanyId IS NULL OR CompanyId = @CompanyId);

    SELECT @@ROWCOUNT AS RowsAffected;
END
GO

-- 9. usp_Api_OPD_Dashboard_GetStats
CREATE OR ALTER PROCEDURE dbo.usp_Api_OPD_Dashboard_GetStats
    @CompanyId INT = NULL,
    @BranchId INT,
    @Date DATE
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. Summary Stats
    SELECT
        COUNT(*) AS TotalBookings,
        COUNT(DISTINCT p.PatientId) AS TotalPatients,
        ISNULL(SUM(CASE WHEN pos.Status = 'Completed' THEN 1 ELSE 0 END), 0) AS CompletedCount,
        ISNULL(SUM(CASE WHEN pos.Status = 'Pending' OR pos.Status = 'Booked' THEN 1 ELSE 0 END), 0) AS PendingCount,
        ISNULL(SUM(CASE WHEN pos.Status = 'Cancelled' THEN 1 ELSE 0 END), 0) AS CancelledCount,
        ISNULL(SUM(pos.TotalAmount), 0) AS TotalRevenue
    FROM PatientOPDService pos
    INNER JOIN PatientMaster p ON p.PatientId = pos.PatientId
    WHERE pos.BranchId = @BranchId
      AND CAST(pos.VisitDate AS DATE) = @Date
      AND (@CompanyId IS NULL OR pos.CompanyId = @CompanyId);

    -- 2. Bookings by Status
    SELECT
        pos.Status,
        COUNT(*) AS Count
    FROM PatientOPDService pos
    WHERE pos.BranchId = @BranchId
      AND CAST(pos.VisitDate AS DATE) = @Date
      AND (@CompanyId IS NULL OR pos.CompanyId = @CompanyId)
    GROUP BY pos.Status;

    -- 3. Bookings by Service Type
    SELECT
        ISNULL(pos.ServiceType, 'Consultation') AS ServiceType,
        COUNT(*) AS Count
    FROM PatientOPDService pos
    WHERE pos.BranchId = @BranchId
      AND CAST(pos.VisitDate AS DATE) = @Date
      AND (@CompanyId IS NULL OR pos.CompanyId = @CompanyId)
    GROUP BY pos.ServiceType;

    -- 4. Today Doctor Roster
    SELECT
        d.DoctorId,
        ISNULL(d.NamePrefix + ' ', '') + d.FullName AS DoctorName,
        ps.SpecialityName,
        COUNT(pos.OPDServiceId) AS TotalAssigned,
        SUM(CASE WHEN pos.Status = 'Completed' THEN 1 ELSE 0 END) AS CompletedCount
    FROM DoctorMaster d
    INNER JOIN DoctorSpecialityMaster ps ON ps.SpecialityId = d.PrimarySpecialityId
    LEFT JOIN PatientOPDService pos ON pos.ConsultingDoctorId = d.DoctorId 
        AND pos.BranchId = @BranchId 
        AND CAST(pos.VisitDate AS DATE) = @Date
    WHERE (@CompanyId IS NULL OR d.CompanyId = @CompanyId)
      AND (d.CreatedBranchId = @BranchId OR EXISTS (
          SELECT 1 FROM DoctorBranchMap dbm WHERE dbm.DoctorId = d.DoctorId AND dbm.BranchId = @BranchId AND dbm.IsActive = 1
      ))
      AND d.IsActive = 1
    GROUP BY d.DoctorId, d.NamePrefix, d.FullName, ps.SpecialityName;

    -- 5. Recent Bookings
    SELECT TOP 10
        pos.OPDServiceId,
        pos.OPDBillNo,
        pos.TokenNo,
        p.PatientCode,
        ISNULL(p.FirstName + ' ', '') + ISNULL(p.LastName, '') AS PatientName,
        p.PhoneNumber,
        ISNULL(d.NamePrefix + ' ', '') + d.FullName AS DoctorName,
        pos.ServiceType,
        pos.TotalAmount,
        pos.Status,
        pos.VisitDate
    FROM PatientOPDService pos
    INNER JOIN PatientMaster p ON p.PatientId = pos.PatientId
    LEFT JOIN DoctorMaster d ON d.DoctorId = pos.ConsultingDoctorId
    WHERE pos.BranchId = @BranchId
      AND CAST(pos.VisitDate AS DATE) = @Date
      AND (@CompanyId IS NULL OR pos.CompanyId = @CompanyId)
    ORDER BY pos.OPDServiceId DESC;

    -- 6. Appointments
    SELECT TOP 10
        pos.OPDServiceId,
        pos.OPDBillNo,
        pos.TokenNo,
        p.PatientCode,
        ISNULL(p.FirstName + ' ', '') + ISNULL(p.LastName, '') AS PatientName,
        p.PhoneNumber,
        ISNULL(d.NamePrefix + ' ', '') + d.FullName AS DoctorName,
        pos.ServiceType,
        pos.TotalAmount,
        pos.Status,
        pos.VisitDate
    FROM PatientOPDService pos
    INNER JOIN PatientMaster p ON p.PatientId = pos.PatientId
    LEFT JOIN DoctorMaster d ON d.DoctorId = pos.ConsultingDoctorId
    WHERE pos.BranchId = @BranchId
      AND CAST(pos.VisitDate AS DATE) >= @Date
      AND (@CompanyId IS NULL OR pos.CompanyId = @CompanyId)
    ORDER BY pos.VisitDate ASC;
END
GO

-- 10. usp_Api_Report_DailyCollectionRegister
CREATE OR ALTER PROCEDURE dbo.usp_Api_Report_DailyCollectionRegister
    @CompanyId INT = NULL,
    @BranchId INT,
    @FromDate DATETIME,
    @ToDate DATETIME,
    @IsDetailed BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        ph.PaymentHeaderId,
        ph.CreatedDate AS PaymentDate,
        ph.ModuleCode,
        ph.ModuleRefId,
        pos.OPDBillNo,
        pos.TokenNo,
        p.PatientCode,
        ISNULL(p.FirstName + ' ', '') + ISNULL(p.LastName, '') AS PatientName,
        p.PhoneNumber,
        ISNULL(d.NamePrefix + ' ', '') + d.FullName AS DoctorName,
        ph.SubTotal,
        ph.LineDiscountTotal + ph.HeaderDiscountAmount AS TotalDiscount,
        ph.TotalCgstAmount + ph.TotalSgstAmount + ph.TotalIgstAmount AS TotalTax,
        ph.NetAmount,
        ph.TotalPaid,
        ph.BalanceDue,
        ph.PaymentStatus,
        pd.ReceiptNo,
        pm.MethodName AS PaymentMethod,
        pd.PaidAmount,
        pd.TransactionRef,
        pd.CreatedDate AS DetailPaymentDate,
        u.Username AS CollectedByUser
    FROM PaymentHeader ph
    INNER JOIN PatientMaster p ON p.PatientId = ph.PatientId
    LEFT JOIN PatientOPDService pos ON pos.OPDServiceId = ph.OPDServiceId
    LEFT JOIN DoctorMaster d ON d.DoctorId = pos.ConsultingDoctorId
    LEFT JOIN PaymentDetail pd ON pd.PaymentHeaderId = ph.PaymentHeaderId AND pd.IsActive = 1
    LEFT JOIN PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    LEFT JOIN Users u ON u.Id = pd.CreatedBy
    WHERE ph.BranchId = @BranchId
      AND ph.CreatedDate >= @FromDate AND ph.CreatedDate <= @ToDate
      AND (@CompanyId IS NULL OR ph.CompanyId = @CompanyId)
      AND ph.IsActive = 1
    ORDER BY ph.PaymentHeaderId DESC, pd.PaymentDetailId ASC;
END
GO

-- 11. usp_Api_Report_PatientRegister
CREATE OR ALTER PROCEDURE dbo.usp_Api_Report_PatientRegister
    @CompanyId INT = NULL,
    @BranchId INT,
    @FromDate DATETIME,
    @ToDate DATETIME,
    @DependentOnly BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        p.PatientId,
        p.PatientCode,
        p.CreatedDate AS RegistrationDate,
        p.Salutation,
        p.FirstName,
        p.MiddleName,
        p.LastName,
        ISNULL(p.FirstName + ' ', '') + ISNULL(p.MiddleName + ' ', '') + ISNULL(p.LastName, '') AS FullName,
        p.Gender,
        p.DateOfBirth,
        p.PhoneNumber,
        p.SecondaryPhoneNumber,
        p.EmailId,
        p.GuardianName,
        p.Address,
        rel.RelationName,
        p.BloodGroup,
        p.KnownAllergies,
        p.Remarks,
        b.BranchName,
        u.Username AS RegisteredByUser
    FROM PatientMaster p
    LEFT JOIN Branchmaster b ON b.BranchID = p.BranchId
    LEFT JOIN RelationMaster rel ON rel.RelationId = p.RelationId
    LEFT JOIN Users u ON u.Id = p.CreatedBy
    WHERE (@BranchId = 0 OR p.BranchId = @BranchId)
      AND p.CreatedDate >= @FromDate AND p.CreatedDate <= @ToDate
      AND (@CompanyId IS NULL OR p.CompanyId = @CompanyId)
      AND (@DependentOnly = 0 OR p.RelationId IS NOT NULL)
      AND p.IsActive = 1
    ORDER BY p.PatientId DESC;
END
GO

-- 12. usp_Api_DoctorDashboard_GetQueue
CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorDashboard_GetQueue
    @CompanyId INT = NULL,
    @BranchId INT,
    @DoctorId INT,
    @QueueDate DATE
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        pos.OPDServiceId,
        pos.PatientId,
        p.PatientCode,
        ISNULL(p.FirstName + ' ', '') + ISNULL(p.MiddleName + ' ', '') + ISNULL(p.LastName, '') AS PatientName,
        p.PhoneNumber,
        p.Gender,
        p.DateOfBirth,
        pos.TokenNo,
        pos.OPDBillNo,
        pos.VisitDate,
        pos.Status,
        pos.ServiceType,
        pos.AppointmentTime,
        v.PatientVitalId,
        v.BPSystolic,
        v.BPDiastolic,
        v.PulseRate,
        v.Temperature,
        v.SpO2,
        v.BMI,
        v.BMICategory,
        CAST(CASE WHEN c.ConsultationId IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsEmrDone,
        c.ConsultationId
    FROM PatientOPDService pos
    INNER JOIN PatientMaster p ON p.PatientId = pos.PatientId
    LEFT JOIN PatientVitals v ON v.PatientVitalId = (
        SELECT TOP 1 PatientVitalId FROM PatientVitals WHERE PatientId = pos.PatientId AND IsActive = 1 ORDER BY RecordedOn DESC
    )
    LEFT JOIN EmrPatientConsultation c ON c.OPDServiceId = pos.OPDServiceId
    WHERE pos.BranchId = @BranchId
      AND pos.ConsultingDoctorId = @DoctorId
      AND CAST(pos.VisitDate AS DATE) = @QueueDate
      AND (@CompanyId IS NULL OR pos.CompanyId = @CompanyId)
      AND pos.IsActive = 1
    ORDER BY 
        CASE 
            WHEN pos.Status = 'InConsultation' THEN 1
            WHEN pos.Status = 'Waiting' THEN 2
            WHEN pos.Status = 'Booked' THEN 3
            WHEN pos.Status = 'Completed' THEN 4
            ELSE 5
        END,
        pos.TokenNo ASC;
END
GO

-- 13. usp_PatientVital_Create
CREATE OR ALTER PROCEDURE dbo.usp_PatientVital_Create
    @CompanyId INT = 1,
    @PatientId INT,
    @Height DECIMAL(5,2) = NULL,
    @Weight DECIMAL(5,2) = NULL,
    @BMI DECIMAL(5,2) = NULL,
    @BMICategory NVARCHAR(30) = NULL,
    @BPSystolic INT = NULL,
    @BPDiastolic INT = NULL,
    @PulseRate INT = NULL,
    @SpO2 DECIMAL(5,2) = NULL,
    @Temperature DECIMAL(5,2) = NULL,
    @RespiratoryRate INT = NULL,
    @BloodGlucose DECIMAL(5,2) = NULL,
    @GlucoseType NVARCHAR(20) = NULL,
    @PainScore INT = NULL,
    @Notes NVARCHAR(500) = NULL,
    @RecordedOn DATETIME = NULL,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF (@CompanyId IS NULL OR @CompanyId = 0)
    BEGIN
        SELECT @CompanyId = CompanyId FROM PatientMaster WHERE PatientId = @PatientId;
        IF (@CompanyId IS NULL) SET @CompanyId = 1;
    END

    INSERT INTO PatientVitals (
        CompanyId, PatientId, Height, Weight, BMI, BMICategory,
        BPSystolic, BPDiastolic, PulseRate, SpO2, Temperature,
        RespiratoryRate, BloodGlucose, GlucoseType, PainScore, Notes,
        RecordedOn, RecordedByUserId, IsActive, CreatedOn, CreatedBy
    ) VALUES (
        @CompanyId, @PatientId, @Height, @Weight, @BMI, @BMICategory,
        @BPSystolic, @BPDiastolic, @PulseRate, @SpO2, @Temperature,
        @RespiratoryRate, @BloodGlucose, @GlucoseType, @PainScore, @Notes,
        ISNULL(@RecordedOn, GETDATE()), @UserId, 1, GETDATE(), @UserId
    );

    SELECT CAST(SCOPE_IDENTITY() AS INT) AS PatientVitalId;
END
GO

-- 14. usp_PatientVital_GetByPatient
CREATE OR ALTER PROCEDURE dbo.usp_PatientVital_GetByPatient
    @PatientId INT,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        pv.PatientVitalId,
        pv.CompanyId,
        pv.PatientId,
        pv.Height,
        pv.Weight,
        pv.BMI,
        pv.BMICategory,
        pv.BPSystolic,
        pv.BPDiastolic,
        pv.PulseRate,
        pv.SpO2,
        pv.Temperature,
        pv.RespiratoryRate,
        pv.BloodGlucose,
        pv.GlucoseType,
        pv.PainScore,
        pv.Notes,
        pv.RecordedOn,
        pv.RecordedByUserId,
        u.Username AS RecordedByUsername,
        pv.IsActive,
        pv.CreatedOn
    FROM PatientVitals pv
    LEFT JOIN Users u ON u.Id = pv.RecordedByUserId
    WHERE pv.PatientId = @PatientId
      AND (@CompanyId IS NULL OR pv.CompanyId = @CompanyId)
      AND pv.IsActive = 1
    ORDER BY pv.RecordedOn DESC;
END
GO
