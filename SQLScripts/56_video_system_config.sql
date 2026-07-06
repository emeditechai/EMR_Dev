-- ============================================================
-- Script: 56_video_system_config.sql
-- Description: Creates tbl_VideoSystemConfig for storing
--              Whereby API configuration dynamically.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'tbl_VideoSystemConfig')
BEGIN
    CREATE TABLE tbl_VideoSystemConfig (
        ConfigId            INT IDENTITY(1,1) PRIMARY KEY,
        ConfigKey           NVARCHAR(100) NOT NULL,
        ConfigValue         NVARCHAR(MAX) NOT NULL,
        MeetingCreationUrl  NVARCHAR(200) NULL,
        IsActive            BIT NOT NULL DEFAULT 1,
        CreatedDate         DATETIME NOT NULL DEFAULT GETDATE(),
        ModifiedDate        DATETIME NULL,
        ModifiedBy          NVARCHAR(100) NULL,
        CONSTRAINT UQ_VideoSystemConfig_ConfigKey UNIQUE (ConfigKey)
    );

    -- Seed default values
    INSERT INTO tbl_VideoSystemConfig (ConfigKey, ConfigValue, MeetingCreationUrl, IsActive)
    VALUES
        ('WherebyApiKey',         'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJodHRwczovL2FjY291bnRzLmFwcGVhci5pbiIsImF1ZCI6Imh0dHBzOi8vYXBpLmFwcGVhci5pbi92MSIsImV4cCI6MTc4NTIzNzAyMSwiaWF0IjoxNzgyNjQ1MDIxLCJvcmdhbml6YXRpb25JZCI6MzQzMjA1LCJqdGkiOiI0ZmY4NmFlOS04YjZjLTQyY2ItYjQ3MC03N2I4NTBhYjcxYjUifQ.PSedZG5JVfbsbL-Bn1TWNexyG55SEpkW1B_m3AtdTnM', 'https://api.whereby.dev/v1/meetings', 1),
        ('WherebyBaseUrl',        'https://api.whereby.dev/v1/meetings', NULL, 1),
        ('DefaultGraceMinutes',   '15', NULL, 1),
        ('WherebyRoomMode',       'normal', NULL, 1);

    PRINT 'tbl_VideoSystemConfig created and seeded successfully.';
END
ELSE
BEGIN
    PRINT 'tbl_VideoSystemConfig already exists. Skipping.';
END
GO
