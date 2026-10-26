-- 2327 Master scope
--   Doctor Sub-Speciality Master: global - every company and branch uses the same list; a code is unique across all
--     companies. CompanyId / BranchId only record where a row was created.
--   Clinical Unit Master: company-wise - each company sees and keeps its own units; a code is unique within a company.
-- Web: DoctorSubSpecialitiesController / ClinicalUnitsController (+ services); API: usp_Api_DoctorSubSpeciality_GetList.

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

-- ── Doctor Sub-Speciality: one code for all companies ──
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UQ_DoctorSubSpecialityMaster_Code' AND object_id = OBJECT_ID('dbo.DoctorSubSpecialityMaster'))
BEGIN
    IF EXISTS (SELECT SubSpecialityCode FROM dbo.DoctorSubSpecialityMaster GROUP BY SubSpecialityCode HAVING COUNT(*) > 1)
        RAISERROR('Script 2327: the same Sub-Speciality code exists in more than one company - rename the duplicates first.', 16, 1);
    ELSE
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'UQ_DoctorSubSpecialityMaster_Code')
            ALTER TABLE dbo.DoctorSubSpecialityMaster DROP CONSTRAINT UQ_DoctorSubSpecialityMaster_Code;
        ELSE
            DROP INDEX UQ_DoctorSubSpecialityMaster_Code ON dbo.DoctorSubSpecialityMaster;
    END
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UQ_DoctorSubSpecialityMaster_Code' AND object_id = OBJECT_ID('dbo.DoctorSubSpecialityMaster'))
   AND NOT EXISTS (SELECT SubSpecialityCode FROM dbo.DoctorSubSpecialityMaster GROUP BY SubSpecialityCode HAVING COUNT(*) > 1)
    CREATE UNIQUE INDEX UQ_DoctorSubSpecialityMaster_Code ON dbo.DoctorSubSpecialityMaster (SubSpecialityCode);
GO

-- the list ignores company and branch (parameters kept for callers)
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
    ORDER BY s.SpecialityName, sub.SubSpecialityName;
END;
GO

-- ── Clinical Unit: a code is unique within a company ──
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UQ_ClinicalUnitMaster_Code' AND object_id = OBJECT_ID('dbo.ClinicalUnitMaster'))
BEGIN
    IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'UQ_ClinicalUnitMaster_Code')
        ALTER TABLE dbo.ClinicalUnitMaster DROP CONSTRAINT UQ_ClinicalUnitMaster_Code;
    ELSE
        DROP INDEX UQ_ClinicalUnitMaster_Code ON dbo.ClinicalUnitMaster;
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UQ_ClinicalUnitMaster_CompanyCode' AND object_id = OBJECT_ID('dbo.ClinicalUnitMaster'))
    CREATE UNIQUE INDEX UQ_ClinicalUnitMaster_CompanyCode ON dbo.ClinicalUnitMaster (CompanyId, UnitCode);
GO
-- the list per company (script 2186 had made it global; the web passes the user's company)
CREATE OR ALTER PROCEDURE dbo.usp_Api_ClinicalUnit_GetList
    @DepartmentId INT = NULL,
    @SpecialityId INT = NULL,
    @CompanyId INT = NULL,
    @BranchId INT = NULL        -- not used: units are shared by the company's branches
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
    ORDER BY dept.DeptName, s.SpecialityName, u.UnitName;
END;
GO

PRINT 'Script 2327 applied: Doctor Sub-Speciality global, Clinical Unit company-wise.';
GO
