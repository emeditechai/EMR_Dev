-- Migration script for adding GlobalPatientSearchRequired to Hospital Settings
IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id = OBJECT_ID(N'[HospitalSettings]') AND name = 'GlobalPatientSearchRequired')
BEGIN
    ALTER TABLE HospitalSettings ADD GlobalPatientSearchRequired BIT NOT NULL DEFAULT 0;
END
GO
