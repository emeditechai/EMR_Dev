-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2427  Master > IPD > Tariff Category: standard names / descriptions and the standard Indian payer tariffs
--   Cash: GEN General (rack rate), B2C Cash - Package / Discounted        Staff: EMP Staff & Dependants
--   Corporate: CORP, PSU, SPCL Special Contract                         Insurance: INS Insurance (direct), TPA
--   Government: GOVT State Scheme, CGHS, ECHS, PMJAY (AB-PMJAY), ESIC     Cash: INTL International Patient
-- Codes and ids are kept (tariffs, rate cards and admissions point at the id). Branch 1, company 1. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET NOCOUNT ON;
DECLARE @t TABLE (Code NVARCHAR(10), Name NVARCHAR(150), Cat NVARCHAR(100), Descr NVARCHAR(500));
INSERT @t VALUES
 (N'GEN',  N'General',                  N'Cash / Self Pay',            N'Standard rack rates for walk-in cash / self-paying patients (default tariff)'),
 (N'B2C',  N'Cash - Package / Discounted', N'Cash / Self Pay',         N'Cash patients on a published package or promotional discounted rate'),
 (N'INTL', N'International Patient',    N'Cash / Self Pay',            N'Foreign nationals / medical-value-travel patients (separate rate card, usually in INR equivalent)'),
 (N'EMP',  N'Staff & Dependants',       N'Staff / Employee',           N'Hospital employees, consultants and their dependent family members'),
 (N'CORP', N'Corporate',                N'Corporate',                  N'Private companies with a tie-up agreement and contracted rates / discounts'),
 (N'PSU',  N'PSU',                      N'Corporate',                  N'Public Sector Undertakings and statutory bodies with an agreement'),
 (N'SPCL', N'Special Contract',         N'Corporate',                  N'Individually negotiated institutional / VIP rate agreements'),
 (N'INS',  N'Insurance (Direct)',       N'Insurance / TPA',            N'Insurance company settled directly with the hospital (cashless or reimbursement)'),
 (N'TPA',  N'TPA',                      N'Insurance / TPA',            N'Cashless claims through a Third Party Administrator (network tariff)'),
 (N'GOVT', N'State Health Scheme',      N'Government / Public Scheme', N'State government health insurance schemes (e.g. Swasthya Sathi, MJPJAY, Aarogyasri)'),
 (N'CGHS', N'CGHS',                     N'Government / Public Scheme', N'Central Government Health Scheme package rates (empanelled hospitals)'),
 (N'ECHS', N'ECHS',                     N'Government / Public Scheme', N'Ex-Servicemen Contributory Health Scheme rates'),
 (N'PMJAY',N'AB-PMJAY',                 N'Government / Public Scheme', N'Ayushman Bharat PM-JAY health benefit package rates (HBP)'),
 (N'ESIC', N'ESIC',                     N'Government / Public Scheme', N'Employees'' State Insurance Corporation referral rates');

UPDATE m SET Name = t.Name, PatientCategory = t.Cat, Description = t.Descr, ModifiedDate = GETDATE()
FROM dbo.TariffCategoryMaster m JOIN @t t ON t.Code = m.Code
WHERE m.CompanyId = 1 AND (m.Name <> t.Name OR m.PatientCategory <> t.Cat OR ISNULL(m.Description, N'') <> t.Descr)
  AND NOT EXISTS (SELECT 1 FROM dbo.TariffCategoryMaster x WHERE x.CompanyId = 1 AND x.Name = t.Name AND x.TariffCategoryId <> m.TariffCategoryId);
PRINT CONCAT('2427 tariff categories updated: ', @@ROWCOUNT);

INSERT dbo.TariffCategoryMaster (CompanyId, BranchId, Code, Name, PatientCategory, Description, IsActive, CreatedDate)
SELECT 1, 1, t.Code, t.Name, t.Cat, t.Descr, 1, GETDATE() FROM @t t
WHERE NOT EXISTS (SELECT 1 FROM dbo.TariffCategoryMaster x WHERE x.CompanyId = 1 AND (x.Code = t.Code OR x.Name = t.Name));
PRINT CONCAT('2427 tariff categories added: ', @@ROWCOUNT);
GO
