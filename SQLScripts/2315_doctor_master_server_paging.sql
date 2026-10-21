-- ============================================================================================================
-- Migration: 2315_doctor_master_server_paging.sql
-- Master > Doctor Master: the list is paged and filtered on the server (it used to load up to 5000 doctors and filter
-- in the browser). usp_Api_Doctor_GetPagedList (new; usp_Api_Doctor_GetList is left as it is for its other callers)
-- uses the same scope and columns and returns:
--   RS1  KPI cards over the whole scope: total, active, inactive, OPD doctors, fees configured
--   RS2  the number of doctors matching the filter
--   RS3  one page, ordered as before (active first, then name)
--   RS4  the specialities and RS5 the departments (+ type) of the scope, for the filter drop-downs
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_Doctor_GetPagedList
    @CompanyId   INT           = NULL,
    @BranchId    INT           = NULL,
    @Search      NVARCHAR(100) = NULL,
    @Status      VARCHAR(10)   = NULL,   -- active / inactive
    @Referral    VARCHAR(3)    = NULL,   -- yes / no
    @Speciality  NVARCHAR(200) = NULL,   -- speciality name
    @Department  NVARCHAR(200) = NULL,   -- department name
    @DoctorId    INT           = NULL,   -- one doctor (link from another screen)
    @PageNumber  INT           = 1,
    @PageSize    INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @Status = NULLIF(LOWER(LTRIM(RTRIM(@Status))), '');
    SET @Referral = NULLIF(LOWER(LTRIM(RTRIM(@Referral))), '');
    SET @Speciality = NULLIF(LTRIM(RTRIM(@Speciality)), N'');
    SET @Department = NULLIF(LTRIM(RTRIM(@Department)), N'');
    IF @DoctorId <= 0 SET @DoctorId = NULL;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 25;
    IF @PageSize > 200 SET @PageSize = 200;

    -- the scope, with the columns of usp_Api_Doctor_GetList
    SELECT
        d.DoctorId,
        ISNULL(d.NamePrefix + ' ', '') + d.FullName AS FullName,
        ps.SpecialityName                           AS PrimarySpecialityName,
        ISNULL(dep.DepartmentNames, '')             AS DepartmentNames,
        d.PhoneNumber,
        d.EmailId,
        d.IsActive,
        d.IsReferralDoctor,
        ISNULL(fees.ConsultingFeeNames, '')         AS ConsultingFeeNames,
        CAST(CASE WHEN EXISTS (
            SELECT 1 FROM DoctorDepartmentMap ddm2
            INNER JOIN DepartmentMaster dm2 ON dm2.DeptId = ddm2.DeptId
            WHERE ddm2.DoctorId = d.DoctorId AND ddm2.IsActive = 1 AND dm2.DeptType = 'OPD'
        ) THEN 1 ELSE 0 END AS BIT)                 AS HasOPDDept
    INTO #D
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
            SELECT N', ' + s.ItemName + N' (₹' + CAST(CAST(s.ItemCharges AS DECIMAL(18,0)) AS NVARCHAR) + N')'
            FROM DoctorConsultingFeeMap m
            INNER JOIN ServiceMaster s ON s.ServiceId = m.ServiceId
            WHERE m.DoctorId = d.DoctorId AND m.BranchId = ISNULL(@BranchId, m.BranchId) AND m.IsActive = 1
            FOR XML PATH(''), TYPE
        ).value('.','NVARCHAR(MAX)'), 1, 2, '') AS ConsultingFeeNames
    ) fees
    WHERE (@CompanyId IS NULL OR d.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR d.CreatedBranchId = @BranchId
           OR EXISTS (SELECT 1 FROM DoctorBranchMap dbm WHERE dbm.DoctorId = d.DoctorId AND dbm.BranchId = @BranchId AND dbm.IsActive = 1));

    -- RS1: KPI cards
    SELECT COUNT(*) AS TotalDoctors,
           ISNULL(SUM(CASE WHEN IsActive = 1 THEN 1 ELSE 0 END), 0) AS ActiveDoctors,
           ISNULL(SUM(CASE WHEN IsActive = 0 THEN 1 ELSE 0 END), 0) AS InactiveDoctors,
           ISNULL(SUM(CASE WHEN HasOPDDept = 1 THEN 1 ELSE 0 END), 0) AS OpdDoctors,
           ISNULL(SUM(CASE WHEN ConsultingFeeNames <> '' THEN 1 ELSE 0 END), 0) AS WithFees
    FROM #D;

    SELECT * INTO #F FROM #D x
    WHERE (@DoctorId IS NULL OR x.DoctorId = @DoctorId)
      AND (@Search IS NULL
           OR x.FullName LIKE N'%' + @Search + N'%' OR ISNULL(x.PhoneNumber, N'') LIKE N'%' + @Search + N'%'
           OR ISNULL(x.EmailId, N'') LIKE N'%' + @Search + N'%' OR x.PrimarySpecialityName LIKE N'%' + @Search + N'%'
           OR x.DepartmentNames LIKE N'%' + @Search + N'%')
      AND (@Status IS NULL OR (@Status = 'active' AND x.IsActive = 1) OR (@Status = 'inactive' AND x.IsActive = 0))
      AND (@Referral IS NULL OR (@Referral = 'yes' AND x.IsReferralDoctor = 1) OR (@Referral = 'no' AND ISNULL(x.IsReferralDoctor, 0) = 0))
      AND (@Speciality IS NULL OR x.PrimarySpecialityName = @Speciality)
      AND (@Department IS NULL OR N', ' + x.DepartmentNames + N',' LIKE N'%, ' + @Department + N',%');

    -- RS2 / RS3
    SELECT COUNT(*) AS FilteredCount FROM #F;
    SELECT DoctorId, FullName, PrimarySpecialityName, DepartmentNames, PhoneNumber, EmailId, IsActive, IsReferralDoctor,
           ConsultingFeeNames, HasOPDDept
    FROM #F
    ORDER BY IsActive DESC, FullName ASC, DoctorId
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;

    -- RS4: specialities of the scope
    SELECT DISTINCT PrimarySpecialityName AS Name FROM #D WHERE ISNULL(PrimarySpecialityName, '') <> '' ORDER BY PrimarySpecialityName;
    -- RS5: departments of the scope, with their type (for "Pathology (LAB)" labels)
    SELECT dm.DeptName AS Name, UPPER(LTRIM(RTRIM(ISNULL(MAX(dm.DeptType), '')))) AS Type
    FROM DoctorDepartmentMap ddm
    INNER JOIN #D d ON d.DoctorId = ddm.DoctorId
    INNER JOIN DepartmentMaster dm ON dm.DeptId = ddm.DeptId
    WHERE ddm.IsActive = 1
    GROUP BY dm.DeptName
    ORDER BY 2, 1;

    DROP TABLE #F;
    DROP TABLE #D;
END
GO

-- EMR.Api api/doctors/paged: mapped to the Doctor Master page
DECLARE @page INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'MASTER.DOCTORS';
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = 'GET', @Controller = N'Doctors', @Action = N'GetPagedList', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO

PRINT 'Script 2315 applied: Doctor Master server-side paging.';
GO
