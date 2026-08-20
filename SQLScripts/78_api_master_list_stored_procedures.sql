-- ==============================================================================
-- Migration Script: 78_api_master_list_stored_procedures.sql
-- Description: Stored Procedures for API Master List endpoints (General, OPD, IPD)
-- ==============================================================================

-- ==============================================================================
-- 1. GENERAL MASTERS
-- ==============================================================================

-- 1.1 Referral Doctor Master List
CREATE OR ALTER PROCEDURE usp_Api_ReferralDoctor_GetList
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM ReferralDoctorMaster ORDER BY CreatedDate DESC;
END;
GO

-- 1.2 Doctor Speciality Master List
CREATE OR ALTER PROCEDURE usp_Api_DoctorSpeciality_GetList
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM DoctorSpecialityMaster ORDER BY SpecialityName;
END;
GO

-- 1.3 Doctor Sub-Speciality Master List
CREATE OR ALTER PROCEDURE usp_Api_DoctorSubSpeciality_GetList
    @SpecialityId INT = NULL,
    @CompanyId INT = NULL,
    @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        sub.SubSpecialityId,
        sub.SpecialityId,
        s.SpecialityName,
        s.SpecialityCode,
        sub.SubSpecialityCode,
        sub.SubSpecialityName,
        sub.Description,
        sub.IsActive,
        sub.CreatedDate
    FROM DoctorSubSpecialityMaster sub
    INNER JOIN DoctorSpecialityMaster s ON sub.SpecialityId = s.SpecialityId
    WHERE (@SpecialityId IS NULL OR sub.SpecialityId = @SpecialityId)
      AND (@CompanyId IS NULL OR sub.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR sub.BranchId = @BranchId OR sub.BranchId IS NULL)
    ORDER BY s.SpecialityName, sub.SubSpecialityName;
END;
GO

-- 1.4 Department Master List
CREATE OR ALTER PROCEDURE usp_Api_Department_GetList
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM DepartmentMaster ORDER BY DeptType, DeptCode;
END;
GO

-- 1.5 Clinical Unit Master List
CREATE OR ALTER PROCEDURE usp_Api_ClinicalUnit_GetList
    @DepartmentId INT = NULL,
    @SpecialityId INT = NULL,
    @CompanyId INT = NULL,
    @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        u.UnitId,
        u.UnitCode,
        u.UnitName,
        u.DepartmentId,
        dept.DeptName AS DepartmentName,
        dept.DeptCode AS DepartmentCode,
        u.SpecialityId,
        s.SpecialityName,
        s.SpecialityCode,
        u.ConsultantInChargeDoctorId,
        ISNULL(d.NamePrefix + ' ', '') + d.FullName AS ConsultantName,
        u.Description,
        u.IsActive,
        u.CreatedDate
    FROM ClinicalUnitMaster u
    INNER JOIN DepartmentMaster dept ON u.DepartmentId = dept.DeptId
    INNER JOIN DoctorSpecialityMaster s ON u.SpecialityId = s.SpecialityId
    LEFT JOIN DoctorMaster d ON u.ConsultantInChargeDoctorId = d.DoctorId
    WHERE (@DepartmentId IS NULL OR u.DepartmentId = @DepartmentId)
      AND (@SpecialityId IS NULL OR u.SpecialityId = @SpecialityId)
      AND (@CompanyId IS NULL OR u.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR u.BranchId = @BranchId OR u.BranchId IS NULL)
    ORDER BY dept.DeptName, s.SpecialityName, u.UnitName;
END;
GO

-- 1.6 Building Master List
CREATE OR ALTER PROCEDURE usp_Api_Building_GetList
    @CompanyId INT = NULL,
    @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        b.BuildingId,
        b.BuildingCode,
        b.BuildingName,
        b.Description,
        b.NumberOfFloors,
        (SELECT COUNT(1) FROM FloorMaster f WHERE f.BuildingId = b.BuildingId) AS TotalFloorsConfigured,
        b.IsActive,
        b.CreatedDate
    FROM BuildingMaster b
    WHERE (@CompanyId IS NULL OR b.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR b.BranchId = @BranchId OR b.BranchId IS NULL)
    ORDER BY b.BuildingCode;
END;
GO

-- 1.7 Floor Master List
CREATE OR ALTER PROCEDURE usp_Api_Floor_GetList
    @BuildingId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        f.FloorId,
        f.FloorCode,
        f.FloorName,
        f.BuildingId,
        b.BuildingName,
        b.BuildingCode,
        f.IsActive,
        f.CreatedBy,
        f.CreatedDate,
        f.ModifiedBy,
        f.ModifiedDate
    FROM FloorMaster f
    LEFT JOIN BuildingMaster b ON f.BuildingId = b.BuildingId
    WHERE (@BuildingId IS NULL OR f.BuildingId = @BuildingId)
    ORDER BY b.BuildingCode, f.FloorCode;
END;
GO

-- 1.8 Country Master List
CREATE OR ALTER PROCEDURE usp_Api_Country_GetList
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM CountryMaster ORDER BY CountryName;
END;
GO

-- 1.9 State Master List
CREATE OR ALTER PROCEDURE usp_Api_State_GetList
    @CountryId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        s.StateId, s.StateCode, s.StateName, s.CountryId, s.IsActive, s.CreatedBy, s.CreatedDate, s.ModifiedBy, s.ModifiedDate,
        c.CountryId, c.CountryName, c.CountryCode
    FROM StateMaster s
    INNER JOIN CountryMaster c ON s.CountryId = c.CountryId
    WHERE (@CountryId IS NULL OR s.CountryId = @CountryId)
    ORDER BY s.StateName;
END;
GO

-- 1.10 District Master List
CREATE OR ALTER PROCEDURE usp_Api_District_GetList
    @CountryId INT = NULL,
    @StateId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        d.DistrictId, d.DistrictCode, d.DistrictName, d.StateId, d.IsActive, d.CreatedBy, d.CreatedDate, d.ModifiedBy, d.ModifiedDate,
        s.StateId, s.StateName, s.StateCode, s.CountryId
    FROM DistrictMaster d
    INNER JOIN StateMaster s ON d.StateId = s.StateId
    WHERE (@StateId IS NULL OR d.StateId = @StateId)
      AND (@CountryId IS NULL OR s.CountryId = @CountryId)
    ORDER BY d.DistrictName;
END;
GO

-- 1.11 City Master List
CREATE OR ALTER PROCEDURE usp_Api_City_GetList
    @CountryId INT = NULL,
    @StateId INT = NULL,
    @DistrictId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        c.CityId, c.CityCode, c.CityName, c.DistrictId, c.IsActive, c.CreatedBy, c.CreatedDate, c.ModifiedBy, c.ModifiedDate,
        d.DistrictId, d.DistrictName, d.DistrictCode, d.StateId
    FROM CityMaster c
    INNER JOIN DistrictMaster d ON c.DistrictId = d.DistrictId
    INNER JOIN StateMaster s ON d.StateId = s.StateId
    WHERE (@DistrictId IS NULL OR c.DistrictId = @DistrictId)
      AND (@StateId IS NULL OR d.StateId = @StateId)
      AND (@CountryId IS NULL OR s.CountryId = @CountryId)
    ORDER BY c.CityName;
END;
GO

-- 1.12 Area Master List
CREATE OR ALTER PROCEDURE usp_Api_Area_GetList
    @CountryId INT = NULL,
    @StateId INT = NULL,
    @DistrictId INT = NULL,
    @CityId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        a.AreaId, a.AreaCode, a.AreaName, a.CityId, a.IsActive, a.CreatedBy, a.CreatedDate, a.ModifiedBy, a.ModifiedDate,
        c.CityId, c.CityName, c.CityCode, c.DistrictId
    FROM AreaMaster a
    INNER JOIN CityMaster c ON a.CityId = c.CityId
    INNER JOIN DistrictMaster d ON c.DistrictId = d.DistrictId
    INNER JOIN StateMaster s ON d.StateId = s.StateId
    WHERE (@CityId IS NULL OR a.CityId = @CityId)
      AND (@DistrictId IS NULL OR c.DistrictId = @DistrictId)
      AND (@StateId IS NULL OR d.StateId = @StateId)
      AND (@CountryId IS NULL OR s.CountryId = @CountryId)
    ORDER BY a.AreaName;
END;
GO

-- ==============================================================================
-- 2. OPD MASTERS
-- ==============================================================================

-- 2.1 Service Master List
CREATE OR ALTER PROCEDURE usp_Api_Service_GetList
    @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM ServiceMaster
    WHERE BranchId = @BranchId
    ORDER BY ServiceType, ItemCode;
END;
GO

-- 2.2 Doctor Room Master List
CREATE OR ALTER PROCEDURE usp_Api_DoctorRoom_GetList
    @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT r.RoomId, r.RoomName, r.FloorId, f.FloorName, r.BranchId, r.IsActive,
           r.CreatedBy, r.CreatedDate, r.ModifiedBy, r.ModifiedDate
    FROM DoctorRoomMaster r
    INNER JOIN FloorMaster f ON f.FloorId = r.FloorId
    WHERE r.BranchId = @BranchId
    ORDER BY f.FloorName, r.RoomName;
END;
GO

-- 2.3 Room Doctor Assignment Master List (Multi-Result Set)
CREATE OR ALTER PROCEDURE usp_Api_RoomDoctorAssignment_GetList
    @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    -- Result set 1: Active Doctor Rooms
    SELECT 
        r.RoomId, 
        r.RoomName, 
        f.FloorName
    FROM DoctorRoomMaster r
    INNER JOIN FloorMaster f ON f.FloorId = r.FloorId
    WHERE r.BranchId = @BranchId AND r.IsActive = 1
    ORDER BY f.FloorName, r.RoomName;

    -- Result set 2: Assigned Doctors
    SELECT 
        drm.RoomId, 
        d.DoctorId, 
        ISNULL(d.NamePrefix + ' ', '') + d.FullName AS FullName, 
        s.SpecialityName
    FROM DoctorRoomMapping drm
    INNER JOIN DoctorMaster d ON drm.DoctorId = d.DoctorId
    INNER JOIN DoctorSpecialityMaster s ON s.SpecialityId = d.PrimarySpecialityId
    INNER JOIN DoctorBranchMap dbm ON dbm.DoctorId = d.DoctorId
    WHERE dbm.BranchId = @BranchId AND d.IsActive = 1;
END;
GO

-- 2.4 OPD Doctor Master Options
CREATE OR ALTER PROCEDURE usp_Api_OPDDoctor_GetList
    @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DISTINCT 
        d.DoctorId, 
        ISNULL(d.NamePrefix + ' ', '') + d.FullName AS FullName, 
        s.SpecialityName
    FROM DoctorMaster d
    INNER JOIN DoctorBranchMap dbm ON dbm.DoctorId = d.DoctorId
    INNER JOIN DoctorDepartmentMap ddm ON ddm.DoctorId = d.DoctorId
    INNER JOIN DepartmentMaster dept ON dept.DeptId = ddm.DeptId
    INNER JOIN DoctorSpecialityMaster s ON s.SpecialityId = d.PrimarySpecialityId
    WHERE dbm.BranchId = @BranchId 
      AND d.IsActive = 1 
      AND dept.DeptType = 'OPD'
    ORDER BY FullName;
END;
GO

-- 2.5 EMR Investigation Master List
CREATE OR ALTER PROCEDURE usp_Api_EmrInvestigation_GetList
    @Search NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM EmrInvestigationMaster
    WHERE (@Search IS NULL OR InvestigationName LIKE '%' + @Search + '%' OR Category LIKE '%' + @Search + '%')
    ORDER BY Category, InvestigationName;
END;
GO

-- 2.6 EMR Medication Master List
CREATE OR ALTER PROCEDURE usp_Api_EmrMedication_GetList
    @Search NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM EmrMedicationMaster
    WHERE (@Search IS NULL OR MedicationName LIKE '%' + @Search + '%' OR GenericName LIKE '%' + @Search + '%' OR Category LIKE '%' + @Search + '%')
    ORDER BY Category, MedicationName;
END;
GO

-- ==============================================================================
-- 3. IPD MASTERS
-- ==============================================================================

-- 3.1 Ward Master List
CREATE OR ALTER PROCEDURE usp_Api_Ward_GetList
    @FloorId INT = NULL,
    @DepartmentId INT = NULL,
    @WardType NVARCHAR(50) = NULL,
    @CompanyId INT = NULL,
    @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        w.WardId,
        w.WardCode,
        w.WardName,
        w.FloorId,
        f.FloorName,
        b.BuildingName,
        w.DepartmentId,
        d.DeptName AS DepartmentName,
        w.WardType,
        w.Gender,
        w.Capacity,
        w.IsIsolationWard,
        w.IsActive,
        w.CreatedDate,
        (SELECT COUNT(1) FROM NursingStationMaster ns WHERE ns.WardId = w.WardId) AS TotalNursingStations
    FROM WardMaster w
    INNER JOIN FloorMaster f ON w.FloorId = f.FloorId
    LEFT JOIN BuildingMaster b ON f.BuildingId = b.BuildingId
    INNER JOIN DepartmentMaster d ON w.DepartmentId = d.DeptId
    WHERE (@FloorId IS NULL OR w.FloorId = @FloorId)
      AND (@DepartmentId IS NULL OR w.DepartmentId = @DepartmentId)
      AND (@WardType IS NULL OR w.WardType = @WardType)
      AND (@CompanyId IS NULL OR w.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR w.BranchId = @BranchId OR w.BranchId IS NULL)
    ORDER BY b.BuildingCode, f.FloorCode, w.WardName;
END;
GO

-- 3.2 Nursing Station Master List
CREATE OR ALTER PROCEDURE usp_Api_NursingStation_GetList
    @WardId INT = NULL,
    @CompanyId INT = NULL,
    @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        ns.NursingStationId,
        ns.StationCode,
        ns.StationName,
        ns.WardId,
        w.WardName,
        w.WardCode,
        w.WardType,
        f.FloorName,
        ns.ResponsibleNurse,
        ns.Description,
        ns.IsActive,
        ns.CreatedDate
    FROM NursingStationMaster ns
    INNER JOIN WardMaster w ON ns.WardId = w.WardId
    LEFT JOIN FloorMaster f ON w.FloorId = f.FloorId
    WHERE (@WardId IS NULL OR ns.WardId = @WardId)
      AND (@CompanyId IS NULL OR ns.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR ns.BranchId = @BranchId OR ns.BranchId IS NULL)
    ORDER BY w.WardCode, ns.StationCode;
END;
GO

-- 3.3 IPD Room Master List
CREATE OR ALTER PROCEDURE usp_Api_Room_GetList
    @BuildingId INT = NULL,
    @FloorId INT = NULL,
    @WardId INT = NULL,
    @RoomCategory NVARCHAR(50) = NULL,
    @RoomType NVARCHAR(50) = NULL,
    @CompanyId INT = NULL,
    @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        r.RoomId,
        r.RoomNumber,
        r.BuildingId,
        b.BuildingName,
        b.BuildingCode,
        r.FloorId,
        f.FloorName,
        f.FloorCode,
        r.WardId,
        w.WardName,
        w.WardCode,
        w.WardType,
        r.RoomType,
        r.RoomCategory,
        r.IsIsolation,
        r.BedCapacity,
        r.IsActive,
        r.CreatedDate
    FROM RoomMaster r
    INNER JOIN BuildingMaster b ON r.BuildingId = b.BuildingId
    INNER JOIN FloorMaster f ON r.FloorId = f.FloorId
    INNER JOIN WardMaster w ON r.WardId = w.WardId
    WHERE (@BuildingId IS NULL OR r.BuildingId = @BuildingId)
      AND (@FloorId IS NULL OR r.FloorId = @FloorId)
      AND (@WardId IS NULL OR r.WardId = @WardId)
      AND (@RoomCategory IS NULL OR r.RoomCategory = @RoomCategory)
      AND (@RoomType IS NULL OR r.RoomType = @RoomType)
      AND (@CompanyId IS NULL OR r.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR r.BranchId = @BranchId OR r.BranchId IS NULL)
    ORDER BY b.BuildingCode, f.FloorCode, w.WardCode, r.RoomNumber;
END;
GO

-- 3.4 Bed Category Master List
CREATE OR ALTER PROCEDURE usp_Api_BedCategory_GetList
    @CompanyId INT = NULL,
    @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        bc.BedCategoryId,
        bc.CategoryCode,
        bc.CategoryName,
        bc.Description,
        bc.IsActive,
        bc.CreatedDate
    FROM BedCategoryMaster bc
    WHERE (@CompanyId IS NULL OR bc.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR bc.BranchId = @BranchId OR bc.BranchId IS NULL)
    ORDER BY bc.CategoryName;
END;
GO

-- 3.5 Bed Master List
CREATE OR ALTER PROCEDURE usp_Api_Bed_GetList
    @BuildingId INT = NULL,
    @WardId INT = NULL,
    @RoomId INT = NULL,
    @BedCategoryId INT = NULL,
    @BedStatus NVARCHAR(50) = NULL,
    @CompanyId INT = NULL,
    @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        b.BedId,
        b.BedNumber,
        b.BuildingId,
        bld.BuildingName,
        bld.BuildingCode,
        b.WardId,
        w.WardName,
        w.WardCode,
        b.RoomId,
        r.RoomNumber,
        r.RoomType,
        b.BedCategoryId,
        bc.CategoryName AS BedCategoryName,
        bc.CategoryCode AS BedCategoryCode,
        b.BedStatus,
        b.IsIsolation,
        b.IsICU,
        b.IsVentilatorCapable,
        b.IsActive,
        b.CreatedDate
    FROM BedMaster b
    INNER JOIN BuildingMaster bld ON b.BuildingId = bld.BuildingId
    INNER JOIN WardMaster w ON b.WardId = w.WardId
    INNER JOIN RoomMaster r ON b.RoomId = r.RoomId
    INNER JOIN BedCategoryMaster bc ON b.BedCategoryId = bc.BedCategoryId
    WHERE (@BuildingId IS NULL OR b.BuildingId = @BuildingId)
      AND (@WardId IS NULL OR b.WardId = @WardId)
      AND (@RoomId IS NULL OR b.RoomId = @RoomId)
      AND (@BedCategoryId IS NULL OR b.BedCategoryId = @BedCategoryId)
      AND (@BedStatus IS NULL OR b.BedStatus = @BedStatus)
      AND (@CompanyId IS NULL OR b.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR b.BranchId = @BranchId OR b.BranchId IS NULL)
    ORDER BY bld.BuildingCode, w.WardCode, r.RoomNumber, b.BedNumber;
END;
GO

-- 3.6 Tariff Category Master List
CREATE OR ALTER PROCEDURE usp_Api_TariffCategory_GetList
    @PatientCategory NVARCHAR(50) = NULL,
    @CompanyId INT = NULL,
    @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        TariffCategoryId,
        Code,
        Name,
        PatientCategory,
        Description,
        IsActive,
        CreatedDate
    FROM TariffCategoryMaster
    WHERE (@PatientCategory IS NULL OR PatientCategory = @PatientCategory)
      AND (@CompanyId IS NULL OR CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR BranchId = @BranchId OR BranchId IS NULL)
    ORDER BY Code, Name;
END;
GO

-- 3.7 Bed/Room Tariff Master List
CREATE OR ALTER PROCEDURE usp_Api_BedRoomTariff_GetList
    @WardId INT = NULL,
    @RoomId INT = NULL,
    @BedCategoryId INT = NULL,
    @TariffCategoryId INT = NULL,
    @CompanyId INT = NULL,
    @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        t.BedRateId,
        t.WardId,
        w.WardName,
        w.WardCode,
        t.RoomId,
        r.RoomNumber,
        r.RoomType,
        t.BedCategoryId,
        bc.CategoryName AS BedCategoryName,
        t.TariffCategoryId,
        tc.Name AS TariffCategoryName,
        tc.Code AS TariffCategoryCode,
        tc.PatientCategory,
        t.EffectiveFrom,
        t.EffectiveTo,
        t.RoomCharge,
        t.BedCharge,
        t.NursingCharge,
        t.AttendantCharge,
        t.IsolationCharge,
        t.GstPercentage,
        t.IsActive
    FROM BedRoomTariffMaster t
    INNER JOIN WardMaster w ON t.WardId = w.WardId
    INNER JOIN RoomMaster r ON t.RoomId = r.RoomId
    INNER JOIN BedCategoryMaster bc ON t.BedCategoryId = bc.BedCategoryId
    INNER JOIN TariffCategoryMaster tc ON t.TariffCategoryId = tc.TariffCategoryId
    WHERE (@WardId IS NULL OR t.WardId = @WardId)
      AND (@RoomId IS NULL OR t.RoomId = @roomId)
      AND (@BedCategoryId IS NULL OR t.BedCategoryId = @bedCategoryId)
      AND (@TariffCategoryId IS NULL OR t.TariffCategoryId = @tariffCategoryId)
      AND (@CompanyId IS NULL OR t.CompanyId = @companyId)
      AND (@BranchId IS NULL OR t.BranchId = @branchId)
    ORDER BY w.WardName, r.RoomNumber, bc.CategoryName, tc.Name, t.EffectiveFrom DESC;
END;
GO
