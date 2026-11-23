-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2426  Master > IPD > Bed Category: standard names, descriptions and the missing standard classes
--   Room classes (tariff tiers): General Ward, Semi Private (twin sharing), Private, Deluxe, Suite
--   Critical care: ICU, HDU, CCU / ICCU, NICU, PICU     Special: Isolation, Burns, Labour (LDR), Recovery (PACU)
--   Short stay: Day Care, Observation, Emergency        Newborn: Baby Cradle (with the mother, no separate room)
-- Codes and ids are kept, so beds and tariffs keep working. Company 1. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET NOCOUNT ON;
DECLARE @c TABLE (Code NVARCHAR(50), Name NVARCHAR(150), Descr NVARCHAR(500));
INSERT @c VALUES
 (N'GEN',    N'General Ward',          N'Multi-bed shared ward (economy class), common toilet; base tariff tier'),
 (N'SPRV',   N'Semi Private',          N'Twin-sharing room with partition and attached toilet'),
 (N'PRV',    N'Private',               N'Single-occupancy room with attached toilet and attendant bed'),
 (N'DLX',    N'Deluxe',                N'Larger private room with electric bed, attendant couch and amenities'),
 (N'SUT',    N'Suite',                 N'Executive suite with separate visitor lounge'),
 (N'ICU',    N'ICU',                   N'Intensive care bed with monitoring and life support (1:1 or 1:2 nursing)'),
 (N'HDU',    N'HDU (High Dependency)', N'Step-down critical care between ICU and ward (1:2 or 1:3 nursing)'),
 (N'CCU',    N'CCU / ICCU',            N'Cardiac care bed with continuous cardiac monitoring'),
 (N'NICU',   N'NICU',                  N'Neonatal intensive care incubator / warmer'),
 (N'PICU',   N'PICU',                  N'Paediatric intensive care bed'),
 (N'ISO',    N'Isolation',             N'Single room for infectious patients (negative pressure where available)'),
 (N'BURN',   N'Burns',                 N'Burns unit bed with barrier nursing'),
 (N'LDR',    N'Labour (LDR)',          N'Labour, delivery and recovery bed'),
 (N'PACU',   N'Recovery (PACU)',       N'Post-anaesthesia recovery bed after surgery (hours, not days)'),
 (N'DC',     N'Day Care',              N'Same-day procedure / chemotherapy / dialysis bed, discharged the same day'),
 (N'OBS',    N'Observation',           N'Short-stay observation bed (usually under 24 hours)'),
 (N'EMG',    N'Emergency',             N'Emergency / casualty triage and resuscitation bed'),
 (N'CRADLE', N'Baby Cradle',           N'Newborn cot beside the mother (no separate room charge)');

-- names and descriptions of the existing codes (the "Day Care e" typo and short names fixed)
UPDATE m SET CategoryName = c.Name, Description = c.Descr, ModifiedDate = GETDATE()
FROM dbo.BedCategoryMaster m JOIN @c c ON c.Code = m.CategoryCode
WHERE m.CompanyId = 1 AND (m.CategoryName <> c.Name OR ISNULL(m.Description, N'') <> c.Descr)
  AND NOT EXISTS (SELECT 1 FROM dbo.BedCategoryMaster x WHERE x.CompanyId = 1 AND x.CategoryName = c.Name AND x.BedCategoryId <> m.BedCategoryId);
PRINT CONCAT('2426 bed categories updated: ', @@ROWCOUNT);

INSERT dbo.BedCategoryMaster (CompanyId, CategoryCode, CategoryName, Description, IsActive, CreatedDate)
SELECT 1, c.Code, c.Name, c.Descr, 1, GETDATE() FROM @c c
WHERE NOT EXISTS (SELECT 1 FROM dbo.BedCategoryMaster x WHERE x.CompanyId = 1 AND (x.CategoryCode = c.Code OR x.CategoryName = c.Name));
PRINT CONCAT('2426 bed categories added: ', @@ROWCOUNT);
GO
