-- =============================================================================
-- eMediEMR — HospitalSettings Deployment Script
-- Database : Dev_EMR
-- Generated: 26 Feb 2026
-- Run this ONCE against Dev_EMR to create the HospitalSettings table
-- and register both EF migrations so "dotnet ef database update" stays clean.
-- =============================================================================

USE [Dev_EMR];
GO

-- -----------------------------------------------------------------------------
-- 1.  Ensure __EFMigrationsHistory table exists (EF creates it, but just in case)
-- -----------------------------------------------------------------------------
IF NOT EXISTS (
    SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[__EFMigrationsHistory]') AND type = 'U'
)
BEGIN
    CREATE TABLE [dbo].[__EFMigrationsHistory] (
        [MigrationId]    nvarchar(150) NOT NULL,
        [ProductVersion] nvarchar(32)  NOT NULL,
        CONSTRAINT [PK___EFMigrationsHistory] PRIMARY KEY ([MigrationId])
    );
END
GO

-- -----------------------------------------------------------------------------
-- 2.  Mark the initial migration as applied (tables already existed in DB)
-- -----------------------------------------------------------------------------
IF NOT EXISTS (
    SELECT 1 FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = '20260226044919_InitialCreateWithAudit'
)
BEGIN
    INSERT INTO [__EFMigrationsHistory] ([MigrationId], [ProductVersion])
    VALUES ('20260226044919_InitialCreateWithAudit', '9.0.2');
    PRINT 'Migration 20260226044919_InitialCreateWithAudit marked as applied.';
END
ELSE
    PRINT 'Migration 20260226044919_InitialCreateWithAudit already registered — skipped.';
GO

-- -----------------------------------------------------------------------------
-- 3.  Create HospitalSettings table
-- -----------------------------------------------------------------------------
IF NOT EXISTS (
    SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[HospitalSettings]') AND type = 'U'
)
BEGIN
    CREATE TABLE [dbo].[HospitalSettings] (
        [Id]                                  INT              NOT NULL IDENTITY(1,1),
        [BranchID]                            INT              NOT NULL,
        [HotelName]                           NVARCHAR(200)    NULL,
        [Address]                             NVARCHAR(500)    NULL,
        [ContactNumber1]                      NVARCHAR(20)     NULL,
        [ContactNumber2]                      NVARCHAR(20)     NULL,
        [EmailAddress]                        NVARCHAR(150)    NULL,
        [Website]                             NVARCHAR(200)    NULL,
        [GSTCode]                             NVARCHAR(50)     NULL,
        [LogoPath]                            NVARCHAR(500)    NULL,
        [CheckInTime]                         TIME             NULL,
        [CheckOutTime]                        TIME             NULL,
        [IsActive]                            BIT              NOT NULL DEFAULT(1),
        [CreatedDate]                         DATETIME2        NOT NULL DEFAULT(GETUTCDATE()),
        [CreatedBy]                           INT              NULL,
        [LastModifiedDate]                    DATETIME2        NULL,
        [LastModifiedBy]                      INT              NULL,
        [ByPassActualDayRate]                 BIT              NOT NULL DEFAULT(0),
        [DiscountApprovalRequired]            BIT              NOT NULL DEFAULT(0),
        [MinimumBookingAmountRequired]        BIT              NOT NULL DEFAULT(0),
        [MinimumBookingAmount]                DECIMAL(18,2)    NOT NULL DEFAULT(0),
        [NoShowGraceHours]                    INT              NOT NULL DEFAULT(0),
        [CancellationRefundApprovalThreshold] DECIMAL(18,2)    NULL,

        CONSTRAINT [PK_HospitalSettings] PRIMARY KEY ([Id]),

        CONSTRAINT [FK_HospitalSettings_Branchmaster_BranchID]
            FOREIGN KEY ([BranchID])
            REFERENCES [dbo].[Branchmaster] ([BranchID])
            ON DELETE NO ACTION
    );

    CREATE INDEX [IX_HospitalSettings_BranchID]
        ON [dbo].[HospitalSettings] ([BranchID]);

    PRINT 'Table HospitalSettings created successfully.';
END
ELSE
    PRINT 'Table HospitalSettings already exists — skipped.';
GO

-- -----------------------------------------------------------------------------
-- 4.  Mark the AddHospitalSettings migration as applied
-- -----------------------------------------------------------------------------
IF NOT EXISTS (
    SELECT 1 FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = '20260226063722_AddHospitalSettings'
)
BEGIN
    INSERT INTO [__EFMigrationsHistory] ([MigrationId], [ProductVersion])
    VALUES ('20260226063722_AddHospitalSettings', '9.0.2');
    PRINT 'Migration 20260226063722_AddHospitalSettings marked as applied.';
END
ELSE
    PRINT 'Migration 20260226063722_AddHospitalSettings already registered — skipped.';
GO

PRINT '=== Deployment complete ===';
GO

-- -----------------------------------------------------------------------------
-- 5.  Seed default HospitalSettings for any existing branches that have none
--     (New branches created going forward will get auto-seeded by the app)
-- -----------------------------------------------------------------------------
INSERT INTO [dbo].[HospitalSettings] (
    [BranchID], [HotelName], [IsActive], [CreatedDate], [CreatedBy],
    [ByPassActualDayRate], [DiscountApprovalRequired],
    [MinimumBookingAmountRequired], [MinimumBookingAmount], [NoShowGraceHours]
)
SELECT
    b.[BranchID],
    b.[BranchName],
    1,
    GETUTCDATE(),
    0,
    0, 0, 0, 0, 0
FROM [dbo].[Branchmaster] b
WHERE NOT EXISTS (
    SELECT 1 FROM [dbo].[HospitalSettings] hs WHERE hs.[BranchID] = b.[BranchID]
);

PRINT CAST(@@ROWCOUNT AS VARCHAR) + ' default HospitalSettings record(s) inserted for existing branches.';
GO
