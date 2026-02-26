-- ============================================================
-- 08_user_master_profile_empcode.sql
-- Add EmployeeCode (branch-wise unique) + ProfilePicturePath
-- ============================================================

IF COL_LENGTH('UserBranches', 'EmployeeCode') IS NULL
BEGIN
    ALTER TABLE UserBranches
    ADD EmployeeCode NVARCHAR(50) NULL;

    PRINT 'UserBranches.EmployeeCode added.';
END
ELSE
BEGIN
    PRINT 'UserBranches.EmployeeCode already exists.';
END
GO

IF COL_LENGTH('Users', 'ProfilePicturePath') IS NULL
BEGIN
    ALTER TABLE Users
    ADD ProfilePicturePath NVARCHAR(300) NULL;

    PRINT 'Users.ProfilePicturePath added.';
END
ELSE
BEGIN
    PRINT 'Users.ProfilePicturePath already exists.';
END
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = 'UX_UserBranches_Branch_EmployeeCode'
      AND object_id = OBJECT_ID('UserBranches')
)
BEGIN
    CREATE UNIQUE INDEX UX_UserBranches_Branch_EmployeeCode
    ON UserBranches(BranchID, EmployeeCode)
    WHERE EmployeeCode IS NOT NULL;

    PRINT 'Unique index UX_UserBranches_Branch_EmployeeCode created.';
END
ELSE
BEGIN
    PRINT 'Unique index UX_UserBranches_Branch_EmployeeCode already exists.';
END
GO
