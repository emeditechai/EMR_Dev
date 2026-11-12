-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2453  LAB bill: LMP date (last menstrual period) for female patients - B2C and B2B booking
--   LabOrder.LmpDate (DATE, NULL): recorded per bill (it changes visit to visit), only for a Female patient.
--   usp_LabOrder_SetLmp: @ValidateOnly = 1 checks the date before the bill is created (the API calls it first, so a
--   wrong date never leaves a half-saved bill); @ValidateOnly = 0 stores it on the new bill. Rules: Female patient
--   only (otherwise not stored), not in the future, at most 365 days back, not before the date of birth.
--   Shown on: the bill view (B2C Order List / B2B Registration detail), the printed bill, Sample Collection and
--   Lab Report Entry - usp_LabOrder_GetDetail, usp_SampleCollection_GetDetail and usp_LabReporting_GetDetail return
--   LmpDate (a column added to their first result; nothing else changes). usp_CreateLabOrder is not changed.
--   Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO
IF COL_LENGTH('dbo.LabOrder', 'LmpDate') IS NULL
    ALTER TABLE dbo.LabOrder ADD LmpDate DATE NULL;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LabOrder_SetLmp
    @LabOrderId   INT = NULL,
    @PatientId    INT = NULL,     -- used with @ValidateOnly = 1 (no bill yet)
    @Gender       NVARCHAR(20) = NULL,   -- the gender on the booking form (a new patient has no record yet)
    @LmpDate      DATE = NULL,
    @ValidateOnly BIT = 0,
    @UserId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @msg NVARCHAR(300), @dob DATE;
    IF @LabOrderId IS NOT NULL AND @PatientId IS NULL SELECT @PatientId = PatientId FROM dbo.LabOrder WHERE LabOrderId = @LabOrderId;
    SELECT @Gender = COALESCE(NULLIF(LTRIM(RTRIM(@Gender)), N''), p.Gender), @dob = p.DateOfBirth FROM dbo.PatientMaster p WHERE p.PatientId = @PatientId;
    IF @LabOrderId IS NULL AND @ValidateOnly = 0 THROW 56401, 'The LAB bill was not found.', 1;

    -- only a female patient's bill carries an LMP date; for anyone else it is simply not stored
    IF @LmpDate IS NOT NULL AND ISNULL(@Gender, N'') = N'Female'
    BEGIN
        IF @LmpDate > CAST(GETDATE() AS DATE) THROW 56402, 'The LMP date cannot be in the future.', 1;
        IF @LmpDate < DATEADD(DAY, -365, CAST(GETDATE() AS DATE)) THROW 56403, 'The LMP date can be at most one year back.', 1;
        IF @dob IS NOT NULL AND @LmpDate <= @dob THROW 56404, 'The LMP date must be after the date of birth.', 1;
    END
    ELSE SET @LmpDate = NULL;

    IF @ValidateOnly = 1 RETURN;
    UPDATE dbo.LabOrder SET LmpDate = @LmpDate WHERE LabOrderId = @LabOrderId;
END;
GO

-- read side: LmpDate in the first result of the three detail procedures (patched in place; re-runnable)
CREATE OR ALTER PROCEDURE #Patch @Proc SYSNAME, @Old NVARCHAR(MAX), @New NVARCHAR(MAX), @Marker NVARCHAR(200)
AS
BEGIN
    DECLARE @d NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(@Proc));
    IF @d IS NULL THROW 51530, 'Procedure missing.', 1;
    IF CHARINDEX(@Marker, @d) > 0 BEGIN PRINT @Proc + ': already patched'; RETURN; END;
    IF (LEN(@d) - LEN(REPLACE(@d, @Old, N''))) / LEN(@Old) <> 1
    BEGIN DECLARE @m NVARCHAR(400) = @Proc + N': the expected code was not found exactly once - not patched.'; THROW 51531, @m, 1; END;
    SET @d = REPLACE(@d, @Old, @New);
    DECLARE @p INT = PATINDEX(N'%CREATE%PROC%', @d);
    SET @d = STUFF(@d, @p, CHARINDEX(N'PROC', @d, @p) - @p, N'CREATE OR ALTER ');
    EXEC sp_executesql @d;
    PRINT @Proc + ': patched';
END;
GO
EXEC #Patch N'dbo.usp_LabOrder_GetDetail',         N'        p.Gender,', N'        p.Gender, o.LmpDate /* 2453 */,',  N'LmpDate /* 2453 */';
EXEC #Patch N'dbo.usp_SampleCollection_GetDetail', N'        p.Gender,', N'        p.Gender, lo.LmpDate /* 2453 */,', N'LmpDate /* 2453 */';
EXEC #Patch N'dbo.usp_LabReporting_GetDetail',     N'        p.Gender,', N'        p.Gender, lo.LmpDate /* 2453 */,', N'LmpDate /* 2453 */';
GO
PRINT '2453 LAB bill LMP date - done.';
GO
