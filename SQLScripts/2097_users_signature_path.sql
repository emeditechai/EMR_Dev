-- ==============================================================================
-- Migration Script: 2097_users_signature_path.sql
-- Description: Pathologist signature image (User Master > Pathologist Configuration).
--   dbo.Users.SignaturePath  - file name of the uploaded signature (.png / .jpg / .jpeg), NULL when none.
--   The image itself is stored on the web server OUTSIDE the public web root (App_Data/signatures)
--   and is served only through an authorised action, never as a public static file.
-- ==============================================================================

SET NOCOUNT ON;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE Name = N'SignaturePath' AND Object_ID = Object_ID(N'[dbo].[Users]'))
BEGIN
    ALTER TABLE [dbo].[Users] ADD [SignaturePath] NVARCHAR(300) NULL;
    PRINT 'Added SignaturePath to dbo.Users.';
END
ELSE PRINT 'SignaturePath already exists on dbo.Users.';
GO
