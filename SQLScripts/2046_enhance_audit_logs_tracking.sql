-- =========================================================================================
-- Migration: 2046_enhance_audit_logs_tracking.sql
-- Description: Add structured tracking columns to dbo.AuditLogs for OPD & LAB Billing Lifecycle
-- =========================================================================================

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.AuditLogs') AND name = 'ModuleCode')
BEGIN
    ALTER TABLE dbo.AuditLogs ADD ModuleCode NVARCHAR(50) NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.AuditLogs') AND name = 'ReferenceNo')
BEGIN
    ALTER TABLE dbo.AuditLogs ADD ReferenceNo NVARCHAR(100) NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.AuditLogs') AND name = 'ReferenceId')
BEGIN
    ALTER TABLE dbo.AuditLogs ADD ReferenceId BIGINT NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.AuditLogs') AND name = 'PatientCode')
BEGIN
    ALTER TABLE dbo.AuditLogs ADD PatientCode NVARCHAR(50) NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.AuditLogs') AND name = 'MetadataJson')
BEGIN
    ALTER TABLE dbo.AuditLogs ADD MetadataJson NVARCHAR(MAX) NULL;
END
GO

-- Create non-clustered indexes for fast querying by Module and Reference
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.AuditLogs') AND name = 'IX_AuditLogs_Module_RefNo')
BEGIN
    CREATE NONCLUSTERED INDEX IX_AuditLogs_Module_RefNo
    ON dbo.AuditLogs (ModuleCode, ReferenceNo)
    WHERE ModuleCode IS NOT NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.AuditLogs') AND name = 'IX_AuditLogs_Module_RefId')
BEGIN
    CREATE NONCLUSTERED INDEX IX_AuditLogs_Module_RefId
    ON dbo.AuditLogs (ModuleCode, ReferenceId)
    WHERE ModuleCode IS NOT NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.AuditLogs') AND name = 'IX_AuditLogs_PatientCode')
BEGIN
    CREATE NONCLUSTERED INDEX IX_AuditLogs_PatientCode
    ON dbo.AuditLogs (PatientCode)
    WHERE PatientCode IS NOT NULL;
END
GO
