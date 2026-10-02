-- ============================================================================
-- Migration: 2191_opd_token_status_log.sql
-- Description: OPD > Token Management shows, on every token, how long it has been in its state (waiting, in
--   consultation) and, once completed, how long it waited and was consulted. For that every token gets a time line:
--   * OPDTokenStatusLog - when the token number was issued and every status change (Registered -> Consulting ->
--     Completed, Skipped ...), with who changed it.
--   * trg_PatientOPDService_TokenLog - AFTER INSERT, UPDATE on PatientOPDService: writes the log whatever changed the
--     status (Token Management, Doctor Dashboard, video consultation, the API). It only adds rows; it never changes
--     PatientOPDService and never blocks a save.
--   * Backfill of the existing tokens from CreatedDate / ModifiedDate (Source = 'BACKFILL', shown as approximate).
--   Run after 2190.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.OPDTokenStatusLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.OPDTokenStatusLog
    (
        LogId        BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_OPDTokenStatusLog PRIMARY KEY,
        OPDServiceId INT           NOT NULL,
        EventType    VARCHAR(10)   NOT NULL,          -- 'TOKEN' (number issued) | 'STATUS' (status changed)
        FromStatus   NVARCHAR(50)  NULL,
        ToStatus     NVARCHAR(50)  NULL,
        TokenNo      NVARCHAR(50)  NULL,
        ChangedAt    DATETIME2     NOT NULL CONSTRAINT DF_OPDTokenStatusLog_ChangedAt DEFAULT (SYSDATETIME()),
        ChangedBy    INT           NULL,
        Source       VARCHAR(10)   NOT NULL CONSTRAINT DF_OPDTokenStatusLog_Source DEFAULT ('LIVE')   -- LIVE | BACKFILL
    );
    CREATE INDEX IX_OPDTokenStatusLog_Service ON dbo.OPDTokenStatusLog (OPDServiceId, ChangedAt);
END
GO

CREATE OR ALTER TRIGGER dbo.trg_PatientOPDService_TokenLog
ON dbo.PatientOPDService
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;

    -- token number issued (at booking, or later when the payment clears)
    INSERT INTO dbo.OPDTokenStatusLog (OPDServiceId, EventType, TokenNo, ChangedBy)
    SELECT i.OPDServiceId, 'TOKEN', i.TokenNo, COALESCE(i.ModifiedBy, i.CreatedBy)
    FROM inserted i
    LEFT JOIN deleted d ON d.OPDServiceId = i.OPDServiceId
    WHERE NULLIF(LTRIM(RTRIM(i.TokenNo)), '') IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(d.TokenNo)), '') IS NULL;

    -- status set (new booking) or changed
    INSERT INTO dbo.OPDTokenStatusLog (OPDServiceId, EventType, FromStatus, ToStatus, TokenNo, ChangedBy)
    SELECT i.OPDServiceId, 'STATUS', d.Status, i.Status, i.TokenNo, COALESCE(i.ModifiedBy, i.CreatedBy)
    FROM inserted i
    LEFT JOIN deleted d ON d.OPDServiceId = i.OPDServiceId
    WHERE i.Status IS NOT NULL
      AND (d.OPDServiceId IS NULL OR ISNULL(d.Status, N'') <> i.Status);
END
GO

-- Backfill: what the existing rows can tell (approximate - only the last change has a time)
IF NOT EXISTS (SELECT 1 FROM dbo.OPDTokenStatusLog WHERE Source = 'BACKFILL')
BEGIN
    INSERT INTO dbo.OPDTokenStatusLog (OPDServiceId, EventType, TokenNo, ChangedAt, ChangedBy, Source)
    SELECT s.OPDServiceId, 'TOKEN', s.TokenNo, s.CreatedDate, s.CreatedBy, 'BACKFILL'
    FROM dbo.PatientOPDService s
    WHERE NULLIF(LTRIM(RTRIM(s.TokenNo)), '') IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM dbo.OPDTokenStatusLog l WHERE l.OPDServiceId = s.OPDServiceId AND l.EventType = 'TOKEN');

    INSERT INTO dbo.OPDTokenStatusLog (OPDServiceId, EventType, FromStatus, ToStatus, TokenNo, ChangedAt, ChangedBy, Source)
    SELECT s.OPDServiceId, 'STATUS', NULL, s.Status, s.TokenNo, COALESCE(s.ModifiedDate, s.CreatedDate), COALESCE(s.ModifiedBy, s.CreatedBy), 'BACKFILL'
    FROM dbo.PatientOPDService s
    WHERE s.Status IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM dbo.OPDTokenStatusLog l WHERE l.OPDServiceId = s.OPDServiceId AND l.EventType = 'STATUS');
END
GO
