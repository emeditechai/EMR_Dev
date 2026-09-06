USE [Dev_EMR]
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ─────────────────────────────────────────────────────────────
-- 1. Table: WhatsAppConfiguration
-- ─────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'WhatsAppConfiguration')
BEGIN
    CREATE TABLE dbo.WhatsAppConfiguration (
        Id                      INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        BranchId                INT NOT NULL,
        CompanyId               INT NULL,
        ConfigName              NVARCHAR(100) NOT NULL DEFAULT 'Primary WaSender API',
        ApiUrl                  NVARCHAR(500) NOT NULL DEFAULT 'https://wasenderapi.com/api/send-message',
        AuthHeaderKey           NVARCHAR(50) NOT NULL DEFAULT 'Authorization',
        ApiKey                  NVARCHAR(500) NOT NULL,
        DefaultCountryCode      NVARCHAR(10) NOT NULL DEFAULT '+91',
        SenderPhone             NVARCHAR(50) NULL,
        IsEnabled               BIT NOT NULL DEFAULT 1,
        OpdNotificationEnabled  BIT NOT NULL DEFAULT 1,
        LabNotificationEnabled  BIT NOT NULL DEFAULT 1,
        OpdMessageTemplate      NVARCHAR(1000) NOT NULL DEFAULT 'Dear {PatientName}, thank you for visiting {HospitalName}. Your OPD Bill {BillNo} of Rs. {Amount} has been generated. Token: {TokenNo}, Doctor: {DoctorName}. Please find your bill attached. Wish you a speedy recovery!',
        LabMessageTemplate      NVARCHAR(1000) NOT NULL DEFAULT 'Dear {PatientName}, thank you for choosing {HospitalName}. Your Lab Order {BillNo} of Rs. {Amount} has been registered. Token: {TokenNo}. Please find your bill attached. Thank you!',
        IsDefault               BIT NOT NULL DEFAULT 1,
        IsActive                BIT NOT NULL DEFAULT 1,
        LastTestedDate          DATETIME NULL,
        LastTestResult          NVARCHAR(500) NULL,
        CreatedBy               NVARCHAR(100) NULL,
        CreatedDate             DATETIME NOT NULL DEFAULT GETDATE(),
        ModifiedBy              NVARCHAR(100) NULL,
        ModifiedDate            DATETIME NULL
    );
    PRINT 'Created table WhatsAppConfiguration.';
END
ELSE
BEGIN
    PRINT 'Table WhatsAppConfiguration already exists.';
END
GO

-- ─────────────────────────────────────────────────────────────
-- 2. Table: WhatsAppLog
-- ─────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'WhatsAppLog')
BEGIN
    CREATE TABLE dbo.WhatsAppLog (
        Id              INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        ConfigId        INT NULL,
        BranchId        INT NOT NULL,
        ModuleCode      NVARCHAR(20) NOT NULL DEFAULT 'TEST', -- OPD, LAB, TEST
        ModuleRefId     INT NULL,
        RecipientPhone  NVARCHAR(50) NOT NULL,
        MessageText     NVARCHAR(MAX) NOT NULL,
        IsSuccess       BIT NOT NULL,
        MsgId           NVARCHAR(100) NULL,
        Jid             NVARCHAR(100) NULL,
        Status          NVARCHAR(50) NULL,
        ApiResponse     NVARCHAR(MAX) NULL,
        ErrorMessage    NVARCHAR(1000) NULL,
        SentDate        DATETIME NOT NULL DEFAULT GETDATE()
    );
    PRINT 'Created table WhatsAppLog.';
END
ELSE
BEGIN
    PRINT 'Table WhatsAppLog already exists.';
END
GO

-- ─────────────────────────────────────────────────────────────
-- 3. Pre-seed Default Configuration for Branch 1
-- ─────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM dbo.WhatsAppConfiguration WHERE BranchId = 1)
BEGIN
    INSERT INTO dbo.WhatsAppConfiguration (
        BranchId,
        CompanyId,
        ConfigName,
        ApiUrl,
        AuthHeaderKey,
        ApiKey,
        DefaultCountryCode,
        IsEnabled,
        OpdNotificationEnabled,
        LabNotificationEnabled,
        OpdMessageTemplate,
        LabMessageTemplate,
        IsDefault,
        IsActive,
        CreatedBy,
        CreatedDate
    ) VALUES (
        1,
        1,
        'WaSender Production API',
        'https://wasenderapi.com/api/send-message',
        'Authorization',
        'c52dac44ef6202fa7b97d6474e8d20d2ad5b66cfa7d563f3d3fe67db24badd9c',
        '+91',
        1,
        1,
        1,
        'Dear {PatientName}, thank you for visiting {HospitalName}. Your OPD Bill {BillNo} of Rs. {Amount} has been generated. Token: {TokenNo}, Doctor: {DoctorName}. Please find your bill attached. Wish you a speedy recovery!',
        'Dear {PatientName}, thank you for choosing {HospitalName}. Your Lab Order {BillNo} of Rs. {Amount} has been registered. Token: {TokenNo}. Please find your bill attached. Thank you!',
        1,
        1,
        'System Seed',
        GETDATE()
    );
    PRINT 'Inserted default WhatsApp configuration for Branch 1.';
END
GO
