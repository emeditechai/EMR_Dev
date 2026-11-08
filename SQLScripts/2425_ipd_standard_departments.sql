-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2425  Master > Department: standard in-patient (type IPD) departments
--   Kept: IPD-GEN General Ward (IPD), IPD-ICU Intensive Care Unit, IPD-NICU Neonatal ICU, IPD-SURG Surgical Ward,
--         IPD-MATN Maternity Ward.
--   Added: the other inpatient units of a standard (NABH / international) hospital. Wards (Master > Ward) are linked
--   to these, and the IPD admission page shows only the beds of the chosen department's wards.
--   Only for company 1 (codes are unique across the application). Adds what is missing; safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET NOCOUNT ON;
DECLARE @d TABLE (Code NVARCHAR(20), Name NVARCHAR(150));
INSERT @d VALUES
 (N'IPD-PAED',  N'Paediatric Ward'),
 (N'IPD-PICU',  N'Paediatric ICU (PICU)'),
 (N'IPD-HDU',   N'High Dependency Unit (HDU)'),
 (N'IPD-CCU',   N'Cardiac Care Unit (CCU / ICCU)'),
 (N'IPD-SICU',  N'Surgical ICU (SICU)'),
 (N'IPD-ORTHO', N'Orthopaedic Ward'),
 (N'IPD-LDR',   N'Labour & Delivery'),
 (N'IPD-PACU',  N'Post-Operative Recovery (PACU)'),
 (N'IPD-DCARE', N'Day Care Unit'),
 (N'IPD-EOBS',  N'Emergency Observation Ward'),
 (N'IPD-ISO',   N'Isolation Ward'),
 (N'IPD-BURN',  N'Burns Unit'),
 (N'IPD-ONCO',  N'Oncology Ward'),
 (N'IPD-PSY',   N'Psychiatry Ward'),
 (N'IPD-PVT',   N'Private / Deluxe Ward');
INSERT dbo.DepartmentMaster (DeptCode, DeptName, DeptType, IsActive, CreatedDate, CompanyId)
SELECT d.Code, d.Name, 'IPD', 1, GETDATE(), 1
FROM @d d
WHERE NOT EXISTS (SELECT 1 FROM dbo.DepartmentMaster x WHERE x.DeptCode = d.Code)
  AND NOT EXISTS (SELECT 1 FROM dbo.DepartmentMaster x WHERE x.DeptName = d.Name AND x.CompanyId = 1);
PRINT CONCAT('2425 IPD departments added: ', @@ROWCOUNT);
GO
