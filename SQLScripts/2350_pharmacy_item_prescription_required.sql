-- ============================================================================================================
-- 2350  Pharmacy: "Prescription Required" per item (Item / Drug Master), after 2349.
--   Yes = the counter must enter the doctor and the prescription no. when the item is billed; No = not asked.
--   Existing items start from their schedule (H / H1 / X / NDPS = Yes, OTC / G = No).
--   Schedule H1 / X / NDPS items always need it (they go to the statutory register) - the Item Master keeps it Yes.
-- Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO
IF COL_LENGTH('dbo.PhItem', 'PrescriptionRequired') IS NULL
BEGIN
    ALTER TABLE dbo.PhItem ADD PrescriptionRequired BIT NOT NULL CONSTRAINT DF_PhItem_RxRequired DEFAULT (0);
    EXEC ('UPDATE i SET PrescriptionRequired = s.RxRequired FROM dbo.PhItem i JOIN dbo.PhDrugSchedule s ON s.ScheduleCode = i.ScheduleCode;');
END
GO
UPDATE i SET PrescriptionRequired = 1 FROM dbo.PhItem i JOIN dbo.PhDrugSchedule s ON s.ScheduleCode = i.ScheduleCode WHERE s.RegisterRequired = 1 AND i.PrescriptionRequired = 0;
GO
-- the seed procedure gives its sample items the same default (only the items it has just created)
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Pharmacy_EnsureMasters'));
IF @def NOT LIKE '%PrescriptionRequired%'
BEGIN
    SET @def = REPLACE(@def, 'CREATE PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    SET @def = REPLACE(@def, 'CREATE   PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    SET @def = REPLACE(@def, 'LEFT JOIN dbo.PhDosageForm f   ON f.CompanyId = @CompanyId AND f.DosageFormName = v.form;',
                             'LEFT JOIN dbo.PhDosageForm f   ON f.CompanyId = @CompanyId AND f.DosageFormName = v.form;
        UPDATE i SET PrescriptionRequired = s.RxRequired FROM dbo.PhItem i JOIN dbo.PhDrugSchedule s ON s.ScheduleCode = i.ScheduleCode WHERE i.CompanyId = @CompanyId;   -- 2350');
    IF @def NOT LIKE '%PrescriptionRequired%' THROW 51390, 'Could not add the prescription default to usp_Pharmacy_EnsureMasters.', 1;
    EXEC (@def);
END
GO
PRINT 'Script 2350 applied: Prescription Required per pharmacy item.';
GO
