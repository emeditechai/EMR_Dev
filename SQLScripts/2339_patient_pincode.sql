-- 2339 Patient Pincode (OPD Patient Registration, LAB B2C booking): the 6-digit PIN of the patient's address.
--   It is also kept at the end of PatientMaster.Address as ", PIN: nnnnnn" so every bill, print and report shows it.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
IF COL_LENGTH('dbo.PatientMaster', 'Pincode') IS NULL
    ALTER TABLE dbo.PatientMaster ADD Pincode NVARCHAR(10) NULL;
GO
PRINT 'Script 2339 applied: PatientMaster.Pincode.';
GO
