USE [Dev_EMR];
GO

-- ============================================================
-- 46_doctor_login_support.sql
-- Adds LinkedUserId FK column to DoctorMaster so each doctor
-- can optionally be linked to a system login User account.
-- ============================================================

-- 1. Add LinkedUserId column to DoctorMaster (nullable FK to Users)
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.DoctorMaster')
      AND name = 'LinkedUserId'
)
BEGIN
    ALTER TABLE dbo.DoctorMaster
    ADD LinkedUserId INT NULL;
    PRINT 'Column LinkedUserId added to DoctorMaster.';
END
ELSE
BEGIN
    PRINT 'Column LinkedUserId already exists in DoctorMaster. Skipped.';
END
GO

-- 2. Add foreign key constraint (optional, safe — no cascade delete)
IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys
    WHERE name = 'FK_DoctorMaster_LinkedUser'
      AND parent_object_id = OBJECT_ID('dbo.DoctorMaster')
)
BEGIN
    ALTER TABLE dbo.DoctorMaster
    ADD CONSTRAINT FK_DoctorMaster_LinkedUser
        FOREIGN KEY (LinkedUserId)
        REFERENCES dbo.Users(Id)
        ON DELETE SET NULL
        ON UPDATE NO ACTION;
    PRINT 'FK_DoctorMaster_LinkedUser constraint added.';
END
ELSE
BEGIN
    PRINT 'FK_DoctorMaster_LinkedUser constraint already exists. Skipped.';
END
GO
