-- ============================================================================================================
-- Migration: 2484_doctor_is_suspended.sql   (application database)
-- Master > Doctor: "Is Suspended" flag (toggle on the Edit page; shown on the list and the View page). A suspended doctor
-- stays active in the master; what suspension stops is decided separately (step 2).
--   DoctorMaster.IsSuspended BIT NOT NULL DEFAULT 0; SuspendReason (required when suspending - checked by the server),
--   SuspendedBy / SuspendedAt (who and when; cleared when the suspension is lifted - both kept in the audit log)
--   usp_Api_Doctor_GetPagedList: returns IsSuspended; Status filter 'suspended'
-- Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
IF COL_LENGTH('dbo.DoctorMaster', 'IsSuspended') IS NULL
    ALTER TABLE dbo.DoctorMaster ADD IsSuspended BIT NOT NULL CONSTRAINT DF_DoctorMaster_IsSuspended DEFAULT (0);
GO
IF COL_LENGTH('dbo.DoctorMaster', 'SuspendReason') IS NULL
    ALTER TABLE dbo.DoctorMaster ADD SuspendReason NVARCHAR(500) NULL, SuspendedBy INT NULL, SuspendedAt DATETIME NULL;
GO
-- a suspended doctor always has a reason
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_DoctorMaster_SuspendReason')
    ALTER TABLE dbo.DoctorMaster ADD CONSTRAINT CK_DoctorMaster_SuspendReason CHECK (IsSuspended = 0 OR NULLIF(LTRIM(RTRIM(SuspendReason)), N'') IS NOT NULL);
GO

DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Api_Doctor_GetPagedList'));
IF @def NOT LIKE '%SuspendReason%'
BEGIN
    IF CHARINDEX(N'        d.IsReferralDoctor,', @def) = 0
       OR (CHARINDEX(N'(@Status = ''inactive'' AND x.IsActive = 0))', @def) = 0 AND @def NOT LIKE N'%''suspended''%')
       OR CHARINDEX(N'IsActive, IsReferralDoctor,', @def) = 0
        THROW 51484, 'usp_Api_Doctor_GetPagedList has changed: add IsSuspended by hand.', 1;
    -- (re-run after the first version of this script: the IsSuspended column was already added - start from it)
    SET @def = REPLACE(@def, N'        d.IsSuspended,
', N'');
    SET @def = REPLACE(@def, N'IsActive, IsReferralDoctor, IsSuspended,', N'IsActive, IsReferralDoctor,');
    SET @def = REPLACE(@def, N'        d.IsReferralDoctor,', N'        d.IsReferralDoctor,
        d.IsSuspended, d.SuspendReason,');
    IF @def NOT LIKE N'%''suspended''%'
        SET @def = REPLACE(@def, N'(@Status = ''inactive'' AND x.IsActive = 0))', N'(@Status = ''inactive'' AND x.IsActive = 0) OR (@Status = ''suspended'' AND x.IsSuspended = 1))');
    SET @def = REPLACE(@def, N'IsActive, IsReferralDoctor,', N'IsActive, IsReferralDoctor, IsSuspended, SuspendReason,');
    SET @def = REPLACE(@def, 'CREATE   PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    SET @def = REPLACE(@def, 'CREATE PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    EXEC (@def);
END
GO
PRINT 'Script 2484 applied: DoctorMaster.IsSuspended.';
GO

-- ── the booking screens ask when a doctor is chosen (Doctors/SuspensionStatus): LAB B2C / B2B and OPD booking pages ──
DECLARE @pg INT, @vw INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR
    SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code IN (N'LAB.LABORDERBOOKING.B2CBOOKING', N'LAB.LABORDERBOOKING.B2BBOOKING', N'OPD.PATIENTREGISTRATION',
                                                             N'OPD.SERVICEBOOKING', N'OPD.DOCTORROSTER', N'OPD.DOCTORDASHBOARD');   -- roster slots (own roster on the dashboard)
OPEN pc; FETCH NEXT FROM pc INTO @pg;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @vw = (SELECT Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @pg AND Control_Code = 'VIEW');
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pg, @Control_ID = @vw, @App = 'WEB', @Http_Method = 'GET', @Controller = N'Doctors', @Action = N'SuspensionStatus', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @pg;
END
CLOSE pc; DEALLOCATE pc;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
