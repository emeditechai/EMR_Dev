-- ============================================================================================================
-- Migration: 2320_login_retry_lockout_and_user_unlock.sql
-- 1. Hospital Settings > OPD Configuration: "Login Retry Count" (per branch, default 0).
--    0  = wrong passwords are not counted and never lock the account.
--    N  = after N wrong passwords in a row the account is locked for 10 minutes (Users.Lockout_Until); a correct
--         password after the lock ends (or an unlock) resets the count.
--    A user mapped to several branches gets the strictest one (smallest count above 0); a user with no branch (Super
--    Admin) gets the head office's.
-- 2. Settings > User Master: lock status in the list (+ "Locked" filter / KPI) and "Unlock" - its own permission
--    control SETTINGS.USERS:UNLOCK (no role is granted it here; Super Admin has every control).
-- Users.IsLockedOut (the administrator's permanent lock) is not touched. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.HospitalSettings', 'LoginRetryCount') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD LoginRetryCount INT NOT NULL
        CONSTRAINT DF_HospitalSettings_LoginRetryCount DEFAULT (0);
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_HospitalSettings_LoginRetryCount')
    ALTER TABLE dbo.HospitalSettings ADD CONSTRAINT CK_HospitalSettings_LoginRetryCount CHECK (LoginRetryCount BETWEEN 0 AND 20);
GO

-- The retry count that applies to a user (0 = no lockout).
CREATE OR ALTER FUNCTION dbo.fn_Auth_LoginRetryCount (@UserId INT)
RETURNS INT
AS
BEGIN
    DECLARE @n INT;
    ;WITH s AS (
        SELECT hs.BranchId, hs.LoginRetryCount,
               ROW_NUMBER() OVER (PARTITION BY hs.BranchId ORDER BY hs.IsActive DESC, hs.Id DESC) AS rn
        FROM dbo.HospitalSettings hs)
    SELECT @n = MIN(s.LoginRetryCount)
    FROM s
    WHERE s.rn = 1 AND s.LoginRetryCount > 0
      AND s.BranchId IN (SELECT ub.BranchID FROM dbo.UserBranches ub WHERE ub.UserId = @UserId AND ub.IsActive = 1);

    IF @n IS NULL AND NOT EXISTS (SELECT 1 FROM dbo.UserBranches ub WHERE ub.UserId = @UserId AND ub.IsActive = 1)
    BEGIN
        ;WITH s AS (
            SELECT hs.BranchId, hs.LoginRetryCount,
                   ROW_NUMBER() OVER (PARTITION BY hs.BranchId ORDER BY hs.IsActive DESC, hs.Id DESC) AS rn
            FROM dbo.HospitalSettings hs)
        SELECT @n = MIN(s.LoginRetryCount)
        FROM s INNER JOIN dbo.Branchmaster b ON b.BranchID = s.BranchId AND b.IsHOBranch = 1
        WHERE s.rn = 1 AND s.LoginRetryCount > 0;
    END
    RETURN ISNULL(@n, 0);
END
GO

-- Wrong password. @MaxAttempts / @LockMinutes are kept for older callers and ignored: Hospital Settings decides.
CREATE OR ALTER PROCEDURE dbo.usp_Auth_Login_RecordFailure
    @UserId INT, @MaxAttempts INT = NULL, @LockMinutes INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Retry INT = dbo.fn_Auth_LoginRetryCount(@UserId);

    IF @Retry > 0
        UPDATE dbo.Users
        SET FailedLoginAttempts = ISNULL(FailedLoginAttempts, 0) + 1,
            Lockout_Until = CASE WHEN ISNULL(FailedLoginAttempts, 0) + 1 >= @Retry
                                 THEN DATEADD(MINUTE, 10, SYSDATETIME()) ELSE Lockout_Until END
        WHERE Id = @UserId;

    SELECT FailedLoginAttempts, Lockout_Until, @Retry AS RetryCount FROM dbo.Users WHERE Id = @UserId;
END
GO

-- Settings > User Master > Unlock: clears the automatic lock and the wrong-password count. Returns 1 when it was locked.
CREATE OR ALTER PROCEDURE dbo.usp_Api_Users_Unlock
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @WasLocked BIT = CASE WHEN EXISTS (SELECT 1 FROM dbo.Users WHERE Id = @UserId AND Lockout_Until > SYSDATETIME()) THEN 1 ELSE 0 END;
    UPDATE dbo.Users SET FailedLoginAttempts = 0, Lockout_Until = NULL WHERE Id = @UserId;
    SELECT @@ROWCOUNT AS Found, @WasLocked AS WasLocked;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_Users_GetPaged
    @CompanyId        INT            = NULL,   -- NULL = Super Admin: every company
    @VisibleBranchIds NVARCHAR(MAX)  = NULL,   -- comma list; NULL = no branch limit (head office)
    @CurrentBranchId  INT            = NULL,   -- employee code shown for this branch
    @Search           NVARCHAR(200)  = NULL,
    @UserType         VARCHAR(1)     = NULL,   -- U / D / F / C
    @Status           VARCHAR(10)    = NULL,   -- active / inactive / locked
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
        u.FailedLoginAttempts,
        CASE WHEN u.Lockout_Until > SYSDATETIME() THEN u.Lockout_Until END AS LockedUntil,
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
           ISNULL(SUM(CASE WHEN IsLabTechnician = 1 THEN 1 ELSE 0 END), 0) AS LabTechnicians,
           ISNULL(SUM(CASE WHEN LockedUntil IS NOT NULL THEN 1 ELSE 0 END), 0) AS LockedUsers
    FROM #U;

    -- the filter
    SELECT * INTO #F FROM #U x
    WHERE (@Search IS NULL
           OR x.Username LIKE N'%' + @Search + N'%' OR x.FullName LIKE N'%' + @Search + N'%'
           OR x.Email LIKE N'%' + @Search + N'%' OR x.EmployeeCode LIKE N'%' + @Search + N'%'
           OR x.DepartmentNames LIKE N'%' + @Search + N'%' OR x.Branches LIKE N'%' + @Search + N'%'
           OR ISNULL(x.ReferenceName, N'') LIKE N'%' + @Search + N'%')
      AND (@UserType IS NULL OR x.UserType = @UserType)
      AND (@Status IS NULL OR (@Status = 'active' AND x.IsActive = 1) OR (@Status = 'inactive' AND x.IsActive = 0)
           OR (@Status = 'locked' AND x.LockedUntil IS NOT NULL))
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
           Branches, DepartmentNames, ISNULL(FailedLoginAttempts, 0) AS FailedLoginAttempts, LockedUntil
    FROM #F
    ORDER BY Username, Id
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;

    DROP TABLE #F;
    DROP TABLE #U;
END
GO

-- Permission: SETTINGS.USERS:UNLOCK (Web Users/Unlock + API users-list/Unlock). No role grants.
DECLARE @page INT, @ctl INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'SETTINGS.USERS';
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'UNLOCK', @Title = N'Unlock user (locked after wrong passwords)', @Sort_Order = 70, @Control_ID = @ctl OUTPUT;
    SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'UNLOCK';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'Users', @Action = N'Unlock', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'API', @Http_Method = 'POST', @Controller = N'UserList', @Action = N'Unlock', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO

PRINT 'Script 2320 applied: Login Retry Count (Hospital Settings) + User Master unlock.';
GO
