-- ============================================================================
-- Migration: 2197_users_user_type_reference.sql
-- Description: Every login (Users row) says what it is and, for a login created from another master, which record
--   it belongs to:
--     User_Type        'U' general user, created in User Master        ReferenceUserID NULL
--                      'D' doctor login, created from Doctor Master     ReferenceUserID = DoctorMaster.DoctorId
--                      'F' franchise login (reserved)                   ReferenceUserID = LabFranchiseMaster.Franchise_ID
--                      'C' company / corporate login (reserved)         ReferenceUserID = CorporateMaster.Corporate_ID
--   * Backfill: logins linked from Doctor Master (DoctorMaster.LinkedUserId) become 'D' with their DoctorId; all
--     other users become 'U'.
--   * User_Type defaults to 'U' and is required; only U / D / F / C are allowed; D / F / C must name their record,
--     U must not; one login per record (unique User_Type + ReferenceUserID).
--   * DoctorMaster.LinkedUserId is kept, in step with Users, for the screens that read it.
--   Run after 2196. Safe to re-run.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- a doctor's login can belong to only one doctor: stop if the existing links say otherwise
IF EXISTS (SELECT LinkedUserId FROM dbo.DoctorMaster WHERE LinkedUserId IS NOT NULL GROUP BY LinkedUserId HAVING COUNT(*) > 1)
    THROW 50001, 'A user is linked to more than one doctor in DoctorMaster.LinkedUserId - fix these links first.', 1;
GO

-- ── 1. backfill ──────────────────────────────────────────────────────────────
UPDATE u SET User_Type = 'D', ReferenceUserID = d.DoctorId
FROM dbo.Users u
INNER JOIN dbo.DoctorMaster d ON d.LinkedUserId = u.Id
WHERE ISNULL(u.User_Type, '') <> 'D' OR ISNULL(u.ReferenceUserID, 0) <> d.DoctorId;

UPDATE dbo.Users SET User_Type = 'U' WHERE User_Type IS NULL OR LTRIM(RTRIM(User_Type)) = '';
UPDATE dbo.Users SET ReferenceUserID = NULL WHERE User_Type = 'U' AND ReferenceUserID IS NOT NULL;
GO

-- ── 2. rules ─────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = 'DF_Users_User_Type')
    ALTER TABLE dbo.Users ADD CONSTRAINT DF_Users_User_Type DEFAULT ('U') FOR User_Type;
GO
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Users') AND name = 'User_Type' AND is_nullable = 1)
    ALTER TABLE dbo.Users ALTER COLUMN User_Type CHAR(1) NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_Users_User_Type')
    ALTER TABLE dbo.Users ADD CONSTRAINT CK_Users_User_Type CHECK (User_Type IN ('U', 'D', 'F', 'C'));
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_Users_ReferenceUserID')
    ALTER TABLE dbo.Users ADD CONSTRAINT CK_Users_ReferenceUserID CHECK (
        (User_Type = 'U' AND ReferenceUserID IS NULL) OR (User_Type IN ('D', 'F', 'C') AND ReferenceUserID IS NOT NULL));
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_Users_UserType_Reference' AND object_id = OBJECT_ID('dbo.Users'))
    CREATE UNIQUE INDEX UX_Users_UserType_Reference ON dbo.Users (User_Type, ReferenceUserID) WHERE ReferenceUserID IS NOT NULL;
GO

SELECT User_Type, COUNT(*) AS Users, SUM(CASE WHEN ReferenceUserID IS NULL THEN 0 ELSE 1 END) AS WithReference
FROM dbo.Users GROUP BY User_Type;
GO
