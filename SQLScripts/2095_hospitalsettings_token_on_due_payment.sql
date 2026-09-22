-- ==============================================================================
-- Migration Script: 2095_hospitalsettings_token_on_due_payment.sql
-- Description: Add TokenGenerateOnDuePayment to dbo.HospitalSettings (LAB tab):
--              "Token No generate in Due payment" (Yes / No).
--
--   NO  (default) - a B2C Lab bill gets its Token No only when it becomes fully paid (today's behaviour).
--   YES           - the Token No is also generated when the bill still has a due (partial / unpaid) payment.
--
--   Per branch, like the other LAB parameters. Existing rows get 0 (No), so nothing changes until it is switched on.
-- ==============================================================================

SET NOCOUNT ON;

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE Name = N'TokenGenerateOnDuePayment'
      AND Object_ID = Object_ID(N'[dbo].[HospitalSettings]')
)
BEGIN
    ALTER TABLE [dbo].[HospitalSettings]
        ADD [TokenGenerateOnDuePayment] BIT NOT NULL CONSTRAINT DF_HospitalSettings_TokenGenerateOnDuePayment DEFAULT 0;
    PRINT 'Added TokenGenerateOnDuePayment column to dbo.HospitalSettings with default value 0 (No).';
END
ELSE
BEGIN
    PRINT 'TokenGenerateOnDuePayment column already exists in dbo.HospitalSettings table.';
END
GO
