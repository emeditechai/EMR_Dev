-- 2329 Doctor Master is company-wise: a doctor created from another company's branch was saved under company 1
-- (the create left CompanyId out - fixed in EMR.Web/Services/DoctorService.cs). Move each such doctor to the company of
-- the branch it was created in.
SET QUOTED_IDENTIFIER ON;
GO
UPDATE d
   SET d.CompanyId = b.CompanyId
  FROM dbo.DoctorMaster d
  JOIN dbo.Branchmaster b ON b.BranchID = d.CreatedBranchId
 WHERE d.CompanyId <> b.CompanyId;
PRINT CONCAT('Script 2329 applied: ', @@ROWCOUNT, ' doctor(s) moved to the company of their branch.');
GO
