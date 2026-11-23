-- ============================================================================================================
-- Migration: 2314_user_master_server_paging.sql
-- Settings > User Master: the list is paged and filtered on the server (it used to load every user and filter in
-- the browser). usp_Api_Users_GetPaged returns, for the users this login may see:
--   RS1  the KPI cards (whole scope, not the filter): total, active, inactive, pathologists (+ with signature), lab techs
--   RS2  the number of users matching the filter
--   RS3  one page of users, ordered by user name, with the same columns the page showed before
-- Scope is unchanged: Super Admin = every company (@CompanyId NULL), else the login's company; signed in to a branch
-- that is not the head office = only users of the branches in @VisibleBranchIds. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_Users_GetPaged
    @CompanyId        INT            = NULL,   -- NULL = Super Admin: every company
    @VisibleBranchIds NVARCHAR(MAX)  = NULL,   -- comma list; NULL = no branch limit (head office)
    @CurrentBranchId  INT            = NULL,   -- employee code shown for this branch
    @Search           NVARCHAR(200)  = NULL,
    @UserType         VARCHAR(1)     = NULL,   -- U / D / F / C
    @Status           VARCHAR(10)    = NULL,   -- active / inactive
    @Role             VARCHAR(20)    = NULL,   -- nurse / phlebotomist / pathologist / labtech / logistics
    @PageNumber       INT            = 1,
    @PageSize         INT            = 25
AS
BEGIN
    SET NOCOUNT ON;

    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SET @UserType = NULLIF(LTRIM(RTRIM(@UserType)), '');
    SET @Status = NULLIF(LOWER(LTRIM(RTRIM(@Status))), '');
    SET @Role = NULLIF(LOWER(LTRIM(RTRIM(@Role))), '');
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 25;
    IF @PageSize > 200 SET @PageSize = 200;

    DECLARE @Branches TABLE (BranchId INT PRIMARY KEY);
    IF @VisibleBranchIds IS NOT NULL
        INSERT INTO @Branches (BranchId)
        SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS INT) FROM STRING_SPLIT(@VisibleBranchIds, ',')
        WHERE TRY_CAST(LTRIM(RTRIM(value)) AS INT) IS NOT NULL;

    -- the users this login may see, with everything the list shows and searches
    SELECT
        u.Id,
        u.Username,
        ISNULL(COALESCE(
            (SELECT TOP 1 ub.EmployeeCode FROM dbo.UserBranches ub
              WHERE ub.UserId = u.Id AND ub.IsActive = 1 AND (@CurrentBranchId IS NULL OR ub.BranchID = @CurrentBranchId)
              ORDER BY ub.Id), N''), N'') AS EmployeeCode,
        ISNULL(u.FullName, CONCAT(u.FirstName, N' ', u.LastName)) AS FullName,
        ISNULL(u.Email, N'') AS Email,
        u.IsActive, u.IsNursingStaff, u.IsPhlebotomist, u.IsPathologist, u.IsLabTechnician, u.IsLogisticsBoy,
        u.ProfilePicturePath,
        CAST(CASE WHEN NULLIF(u.SignaturePath, N'') IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS HasSignature,
        ISNULL(NULLIF(u.User_Type, ''), 'U') AS UserType,
        u.ReferenceUserID AS ReferenceUserId,
        CASE ISNULL(NULLIF(u.User_Type, ''), 'U')
            WHEN 'D' THEN (SELECT TOP 1 CASE WHEN NULLIF(LTRIM(RTRIM(d.NamePrefix)), N'') IS NULL THEN d.FullName ELSE d.NamePrefix + N' ' + d.FullName END
                             FROM dbo.DoctorMaster d WHERE d.DoctorId = u.ReferenceUserID)
            WHEN 'C' THEN (SELECT TOP 1 c.Corporate_Name FROM dbo.CorporateMaster c WHERE c.Corporate_ID = u.ReferenceUserID)
            WHEN 'F' THEN (SELECT TOP 1 f.Franchise_Name FROM dbo.LabFranchiseMaster f WHERE f.Franchise_ID = u.ReferenceUserID)
        END AS ReferenceName,
        ISNULL((SELECT STRING_AGG(b.BranchName, N', ') FROM dbo.UserBranches ub
                 INNER JOIN dbo.Branchmaster b ON b.BranchID = ub.BranchID
                 WHERE ub.UserId = u.Id AND ub.IsActive = 1), N'') AS Branches,
        -- department names in the order the ids are stored (Users.DepartmentIds is a comma list)
        ISNULL((SELECT STRING_AGG(dm.DeptName, N', ') WITHIN GROUP (ORDER BY CAST(j.[key] AS INT))
                 FROM OPENJSON(N'["' + REPLACE(REPLACE(ISNULL(u.DepartmentIds, N''), N' ', N''), N',', N'","') + N'"]') j
                 INNER JOIN dbo.DepartmentMaster dm ON dm.DeptId = TRY_CAST(j.[value] AS INT)), N'') AS DepartmentNames
    INTO #U
    FROM dbo.Users u
    WHERE (@CompanyId IS NULL OR u.CompanyId = @CompanyId)
      AND (@VisibleBranchIds IS NULL
           OR EXISTS (SELECT 1 FROM dbo.UserBranches ub INNER JOIN @Branches vb ON vb.BranchId = ub.BranchID
                       WHERE ub.UserId = u.Id AND ub.IsActive = 1));

    -- RS1: KPI cards over the whole scope
    SELECT COUNT(*) AS TotalUsers,
           ISNULL(SUM(CASE WHEN IsActive = 1 THEN 1 ELSE 0 END), 0) AS ActiveUsers,
           ISNULL(SUM(CASE WHEN IsActive = 0 THEN 1 ELSE 0 END), 0) AS InactiveUsers,
           ISNULL(SUM(CASE WHEN IsPathologist = 1 THEN 1 ELSE 0 END), 0) AS Pathologists,
           ISNULL(SUM(CASE WHEN IsPathologist = 1 AND HasSignature = 1 THEN 1 ELSE 0 END), 0) AS PathologistsSigned,
           ISNULL(SUM(CASE WHEN IsLabTechnician = 1 THEN 1 ELSE 0 END), 0) AS LabTechnicians
    FROM #U;

    -- the filter
    SELECT * INTO #F FROM #U x
    WHERE (@Search IS NULL
           OR x.Username LIKE N'%' + @Search + N'%' OR x.FullName LIKE N'%' + @Search + N'%'
           OR x.Email LIKE N'%' + @Search + N'%' OR x.EmployeeCode LIKE N'%' + @Search + N'%'
           OR x.DepartmentNames LIKE N'%' + @Search + N'%' OR x.Branches LIKE N'%' + @Search + N'%'
           OR ISNULL(x.ReferenceName, N'') LIKE N'%' + @Search + N'%')
      AND (@UserType IS NULL OR x.UserType = @UserType)
      AND (@Status IS NULL OR (@Status = 'active' AND x.IsActive = 1) OR (@Status = 'inactive' AND x.IsActive = 0))
      AND (@Role IS NULL
           OR (@Role = 'nurse' AND x.IsNursingStaff = 1)
           OR (@Role = 'phlebotomist' AND x.IsPhlebotomist = 1)
           OR (@Role = 'pathologist' AND x.IsPathologist = 1)
           OR (@Role = 'labtech' AND x.IsLabTechnician = 1)
           OR (@Role = 'logistics' AND x.IsLogisticsBoy = 1));

    -- RS2: matching users
    SELECT COUNT(*) AS FilteredCount FROM #F;

    -- RS3: the page
    SELECT Id, Username, EmployeeCode, FullName, Email, IsActive, IsNursingStaff, IsPhlebotomist, IsPathologist,
           IsLabTechnician, IsLogisticsBoy, ProfilePicturePath, HasSignature, UserType, ReferenceUserId, ReferenceName,
           Branches, DepartmentNames
    FROM #F
    ORDER BY Username, Id
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;

    DROP TABLE #F;
    DROP TABLE #U;
END
GO

-- EMR.Api api/users-list: mapped to the User Master page
DECLARE @page INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'SETTINGS.USERS';
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = 'GET', @Controller = N'UserList', @Action = N'GetPaged', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO

PRINT 'Script 2314 applied: User Master server-side paging.';
GO
