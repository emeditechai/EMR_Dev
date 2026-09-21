-- ============================================================================
-- Migration: 2100_lab_report_unapprove_recollect.sql
-- Description:
--   "Un-Authorize Report" now asks what the withdrawal is FOR:
--
--     RETEST    (default) - the test goes back to Submitted (2) and keeps its value; it is corrected on the
--                           Lab Reporting Entry page and validated / approved again.  (behaviour of 2099)
--     RECOLLECT           - the sample has to be drawn again: the sample goes back to the Sample Collection
--                           page with status Re-Collect (3) and the entered result is cleared, exactly like the
--                           existing "Re-Collect" action of dbo.usp_LabReporting_UpdateSampleStatus.
--
--   Changes
--     1. dbo.LabReportUnapproval.Action   - RETEST | RECOLLECT (existing rows are RETEST); NewStatusId now NULL-able
--                                           because a re-collected test has no report status at all.
--     2. dbo.usp_LabUnapprove_Execute     - new @Action parameter and the RECOLLECT branch.
--
--   A profile is still un-approved as a whole. Nothing else is altered.
-- ============================================================================

USE [Dev_EMR];
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── 1. Action column + NULL-able NewStatusId ────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.LabReportUnapproval') AND name = 'Action')
BEGIN
    ALTER TABLE dbo.LabReportUnapproval
        ADD [Action] VARCHAR(20) NOT NULL CONSTRAINT DF_LabReportUnapproval_Action DEFAULT ('RETEST');
    PRINT 'Added column dbo.LabReportUnapproval.Action';
END
GO

IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('dbo.LabReportUnapproval') AND name = 'NewStatusId' AND is_nullable = 0)
BEGIN
    ALTER TABLE dbo.LabReportUnapproval ALTER COLUMN NewStatusId INT NULL;
    PRINT 'dbo.LabReportUnapproval.NewStatusId is now NULL-able (re-collect has no report status)';
END
GO

-- ── 2. Withdraw the approval, for a re-test or for a re-collection ──────────
CREATE OR ALTER PROCEDURE dbo.usp_LabUnapprove_Execute
    @LabOrderId          INT,
    @SamplecollectionIds NVARCHAR(MAX),      -- CSV of SamplecollectionID
    @Reason              NVARCHAR(500),
    @UserId              INT,
    @Action              VARCHAR(20) = 'RETEST'   -- RETEST | RECOLLECT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Reason = LTRIM(RTRIM(ISNULL(@Reason, '')));
    SET @Action = UPPER(LTRIM(RTRIM(ISNULL(@Action, 'RETEST'))));

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
    BEGIN RAISERROR('Valid LabOrderId is required.', 16, 1); RETURN; END
    IF LEN(@Reason) < 5
    BEGIN RAISERROR('A reason (at least 5 characters) is required to un-approve a report.', 16, 1); RETURN; END
    IF @Action NOT IN ('RETEST', 'RECOLLECT')
    BEGIN RAISERROR('Select what the withdrawal is for: Re-Test or Re-Collect.', 16, 1); RETURN; END

    DECLARE @Ids TABLE (Id BIGINT PRIMARY KEY);
    INSERT @Ids (Id)
    SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS BIGINT)
    FROM STRING_SPLIT(ISNULL(@SamplecollectionIds, ''), ',')
    WHERE TRY_CAST(LTRIM(RTRIM(value)) AS BIGINT) IS NOT NULL;

    IF NOT EXISTS (SELECT 1 FROM @Ids)
    BEGIN RAISERROR('Select at least one approved test to un-approve.', 16, 1); RETURN; END

    -- A profile is un-approved as a whole: every approved test of a selected test's profile comes with it.
    INSERT @Ids (Id)
    SELECT DISTINCT sc2.samplecollectionID
    FROM dbo.SampleCollection sc1
    INNER JOIN @Ids i ON i.Id = sc1.samplecollectionID
    INNER JOIN dbo.SampleCollection sc2
            ON sc2.Laborderid = sc1.Laborderid
           AND sc2.ProfileId = sc1.ProfileId
           AND sc2.Is_Active = 1 AND sc2.Iscancelled = 0
    INNER JOIN dbo.labentrydetails led2
            ON led2.SamplecollectionID = sc2.samplecollectionID
           AND led2.IsActive = 1 AND led2.ReportStatusId = 5
           AND LTRIM(RTRIM(ISNULL(led2.TestValue, ''))) <> ''
    WHERE sc1.Laborderid = @LabOrderId
      AND sc1.ProfileId IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM @Ids x WHERE x.Id = sc2.samplecollectionID);

    -- every selected test must belong to this bill and currently be approved
    IF EXISTS (
        SELECT 1 FROM @Ids i
        WHERE NOT EXISTS (
            SELECT 1
            FROM dbo.labentrydetails led
            INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = led.SamplecollectionID
            WHERE led.SamplecollectionID = i.Id
              AND led.LabOrderId = @LabOrderId
              AND sc.Laborderid = @LabOrderId
              AND led.IsActive = 1
              AND led.ReportStatusId = 5
              AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> ''))
    BEGIN
        RAISERROR('One or more selected tests are not approved (they may already have been un-approved). Refresh and try again.', 16, 1);
        RETURN;
    END

    DECLARE @Now DATETIME = GETDATE();
    DECLARE @NewStatusId INT = CASE WHEN @Action = 'RETEST' THEN 2 ELSE NULL END;   -- Re-collect: no report status at all

    BEGIN TRAN;

    INSERT dbo.LabReportUnapproval
        (LabOrderId, SamplecollectionID, InvestigationID, PreviousStatusId, NewStatusId, TestValue, PreviousApprovedDate, Reason, [Action], UnapprovedBy, UnapprovedDate)
    SELECT @LabOrderId, led.SamplecollectionID, led.InvestigationID, 5, @NewStatusId, led.TestValue, led.Approved_Date, @Reason, @Action, @UserId, @Now
    FROM dbo.labentrydetails led
    INNER JOIN @Ids i ON i.Id = led.SamplecollectionID
    WHERE led.ReportStatusId = 5;

    IF @Action = 'RETEST'
    BEGIN
        -- Back to Submitted, value kept: corrected on the Lab Reporting Entry page.
        UPDATE led
        SET led.ReportStatusId = 2,
            led.Approved_Date  = NULL,
            led.Validated_date = NULL,
            led.ModifiedBy     = @UserId,
            led.ModifiedDate   = @Now
        FROM dbo.labentrydetails led
        INNER JOIN @Ids i ON i.Id = led.SamplecollectionID
        WHERE led.ReportStatusId = 5;
    END
    ELSE
    BEGIN
        -- Re-collect: same effect as the "Re-Collect" action of dbo.usp_LabReporting_UpdateSampleStatus -
        -- the sample returns to the Sample Collection page and the entered result is cleared.
        UPDATE sc
        SET sc.CollectionstatusID   = 3,                 -- Re-Collect
            sc.RejectionReason      = @Reason,
            sc.Samplecollectiondate = NULL,
            sc.Samplecollectiontime = NULL,
            sc.ModifiedBy           = @UserId,
            sc.ModifiedDate         = @Now
        FROM dbo.SampleCollection sc
        INNER JOIN @Ids i ON i.Id = sc.samplecollectionID
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1 AND sc.Iscancelled = 0;

        UPDATE led
        SET led.TestValue       = NULL,
            led.ReportStatusId  = NULL,
            led.Drafted_Date    = NULL,
            led.Submitted_Date  = NULL,
            led.Validated_date  = NULL,
            led.Approved_Date   = NULL,
            led.AbnormalFlag    = NULL,
            led.RejectionReason = @Reason,
            led.ModifiedBy      = @UserId,
            led.ModifiedDate    = @Now
        FROM dbo.labentrydetails led
        INNER JOIN @Ids i ON i.Id = led.SamplecollectionID
        WHERE led.ReportStatusId = 5;
    END

    DECLARE @Count INT = @@ROWCOUNT;

    COMMIT;

    SELECT @Count AS UnapprovedCount;
END;
GO

PRINT 'Updated dbo.usp_LabUnapprove_Execute (Re-Test / Re-Collect).';
GO
