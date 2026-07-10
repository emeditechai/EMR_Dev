IF NOT EXISTS(SELECT 1 FROM sys.columns 
              WHERE Name = N'ReferralDoctorId'
              AND Object_ID = Object_ID(N'dbo.PatientMaster'))
BEGIN
    ALTER TABLE dbo.PatientMaster ADD ReferralDoctorId INT NULL;
END
GO
