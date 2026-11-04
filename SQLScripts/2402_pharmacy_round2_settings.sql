-- ============================================================================================================
-- 2402  Pharmacy round 2: parameters (Hospital Settings > MED, per branch) for auto reorder, supplier schemes, GS1
--       scanning, stock audit, ABC/VED analysis, counter sale (split payment, substitutes, OPD Rx), clinical checks,
--       refill reminders and loyalty. Every feature is off or harmless by default. Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyAutoReorderEnabled') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyAutoReorderEnabled BIT NOT NULL CONSTRAINT DF_HS_PhAutoReorderEnabled DEFAULT (0);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyReorderSalesDays') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyReorderSalesDays INT NOT NULL CONSTRAINT DF_HS_PhReorderSalesDays DEFAULT (30);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyReorderSafetyDays') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyReorderSafetyDays INT NOT NULL CONSTRAINT DF_HS_PhReorderSafetyDays DEFAULT (3);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyReorderCoverDays') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyReorderCoverDays INT NOT NULL CONSTRAINT DF_HS_PhReorderCoverDays DEFAULT (15);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacySchemeAutoApply') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacySchemeAutoApply BIT NOT NULL CONSTRAINT DF_HS_PhSchemeAutoApply DEFAULT (1);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyGs1ScanEnabled') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyGs1ScanEnabled BIT NOT NULL CONSTRAINT DF_HS_PhGs1ScanEnabled DEFAULT (1);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyCountBlind') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyCountBlind BIT NOT NULL CONSTRAINT DF_HS_PhCountBlind DEFAULT (1);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyCountRecountPercent') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyCountRecountPercent DECIMAL(5,2) NOT NULL CONSTRAINT DF_HS_PhCountRecountPercent DEFAULT (5);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyCycleCountDays') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyCycleCountDays INT NOT NULL CONSTRAINT DF_HS_PhCycleCountDays DEFAULT (30);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyAbcAPercent') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyAbcAPercent DECIMAL(5,2) NOT NULL CONSTRAINT DF_HS_PhAbcAPercent DEFAULT (70);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyAbcBPercent') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyAbcBPercent DECIMAL(5,2) NOT NULL CONSTRAINT DF_HS_PhAbcBPercent DEFAULT (90);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacySlowMovingDays') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacySlowMovingDays INT NOT NULL CONSTRAINT DF_HS_PhSlowMovingDays DEFAULT (60);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyDeadStockDays') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyDeadStockDays INT NOT NULL CONSTRAINT DF_HS_PhDeadStockDays DEFAULT (180);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacySplitPaymentEnabled') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacySplitPaymentEnabled BIT NOT NULL CONSTRAINT DF_HS_PhSplitPaymentEnabled DEFAULT (1);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacySubstituteSuggest') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacySubstituteSuggest BIT NOT NULL CONSTRAINT DF_HS_PhSubstituteSuggest DEFAULT (1);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyRxLinkEnabled') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyRxLinkEnabled BIT NOT NULL CONSTRAINT DF_HS_PhRxLinkEnabled DEFAULT (1);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyClinicalChecksEnabled') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyClinicalChecksEnabled BIT NOT NULL CONSTRAINT DF_HS_PhClinicalChecksEnabled DEFAULT (1);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyMajorInteractionBlock') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyMajorInteractionBlock BIT NOT NULL CONSTRAINT DF_HS_PhMajorInteractionBlock DEFAULT (0);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyRefillReminderEnabled') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyRefillReminderEnabled BIT NOT NULL CONSTRAINT DF_HS_PhRefillReminderEnabled DEFAULT (0);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyRefillReminderDaysBefore') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyRefillReminderDaysBefore INT NOT NULL CONSTRAINT DF_HS_PhRefillReminderDaysBefore DEFAULT (2);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyLoyaltyEnabled') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyLoyaltyEnabled BIT NOT NULL CONSTRAINT DF_HS_PhLoyaltyEnabled DEFAULT (0);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyLoyaltyEarnPer100') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyLoyaltyEarnPer100 DECIMAL(8,2) NOT NULL CONSTRAINT DF_HS_PhLoyaltyEarnPer100 DEFAULT (1);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyLoyaltyPointValue') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyLoyaltyPointValue DECIMAL(8,2) NOT NULL CONSTRAINT DF_HS_PhLoyaltyPointValue DEFAULT (1);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyLoyaltyMinRedeem') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyLoyaltyMinRedeem INT NOT NULL CONSTRAINT DF_HS_PhLoyaltyMinRedeem DEFAULT (100);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyLoyaltyMaxRedeemPercent') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyLoyaltyMaxRedeemPercent DECIMAL(5,2) NOT NULL CONSTRAINT DF_HS_PhLoyaltyMaxRedeemPercent DEFAULT (20);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyLoyaltyExpiryDays') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyLoyaltyExpiryDays INT NOT NULL CONSTRAINT DF_HS_PhLoyaltyExpiryDays DEFAULT (365);
GO
PRINT 'Script 2402 applied: Pharmacy round 2 parameters.';
GO
