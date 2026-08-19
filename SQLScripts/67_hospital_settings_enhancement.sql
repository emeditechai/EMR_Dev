-- ============================================================================
-- Script: 67_hospital_settings_enhancement.sql
-- Description: Add Hospital Type, Registration No, NABH accreditation details,
--              Emergency No, and Teaching Hospital flags to HospitalSettings.
-- ============================================================================

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.HospitalSettings') AND name = N'HospitalType')
BEGIN
    ALTER TABLE dbo.HospitalSettings ADD HospitalType NVARCHAR(100) NULL;
    PRINT 'Added HospitalType to HospitalSettings';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.HospitalSettings') AND name = N'RegistrationNumber')
BEGIN
    ALTER TABLE dbo.HospitalSettings ADD RegistrationNumber NVARCHAR(100) NULL;
    PRINT 'Added RegistrationNumber to HospitalSettings';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.HospitalSettings') AND name = N'NabhStatus')
BEGIN
    ALTER TABLE dbo.HospitalSettings ADD NabhStatus NVARCHAR(100) NULL;
    PRINT 'Added NabhStatus to HospitalSettings';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.HospitalSettings') AND name = N'NabhCertificateNo')
BEGIN
    ALTER TABLE dbo.HospitalSettings ADD NabhCertificateNo NVARCHAR(100) NULL;
    PRINT 'Added NabhCertificateNo to HospitalSettings';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.HospitalSettings') AND name = N'NabhValidFrom')
BEGIN
    ALTER TABLE dbo.HospitalSettings ADD NabhValidFrom DATE NULL;
    PRINT 'Added NabhValidFrom to HospitalSettings';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.HospitalSettings') AND name = N'NabhValidTo')
BEGIN
    ALTER TABLE dbo.HospitalSettings ADD NabhValidTo DATE NULL;
    PRINT 'Added NabhValidTo to HospitalSettings';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.HospitalSettings') AND name = N'EmergencyNumber')
BEGIN
    ALTER TABLE dbo.HospitalSettings ADD EmergencyNumber NVARCHAR(50) NULL;
    PRINT 'Added EmergencyNumber to HospitalSettings';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.HospitalSettings') AND name = N'IsTeachingHospital')
BEGIN
    ALTER TABLE dbo.HospitalSettings ADD IsTeachingHospital BIT NOT NULL CONSTRAINT DF_HospitalSettings_IsTeachingHospital DEFAULT(0);
    PRINT 'Added IsTeachingHospital to HospitalSettings';
END
GO

-- Seed sample values for default branch setting if currently empty
UPDATE dbo.HospitalSettings
SET HospitalType = ISNULL(HospitalType, 'Super Speciality Hospital'),
    RegistrationNumber = ISNULL(RegistrationNumber, 'WB/KOL/HOSP/2022/889'),
    NabhStatus = ISNULL(NabhStatus, 'Entry Level Accredited'),
    NabhCertificateNo = ISNULL(NabhCertificateNo, 'NABH-2024-HOSP-0941'),
    NabhValidFrom = ISNULL(NabhValidFrom, '2024-01-01'),
    NabhValidTo = ISNULL(NabhValidTo, '2027-12-31'),
    EmergencyNumber = ISNULL(EmergencyNumber, '+91 33 2456 9999'),
    IsTeachingHospital = ISNULL(IsTeachingHospital, 0)
WHERE HospitalType IS NULL;
GO
