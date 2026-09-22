-- ============================================================================
-- Migration: 2087_lab_order_activity_history.sql
-- Description:
--   Adds dbo.usp_LabOrder_GetActivityHistory - a READ-ONLY procedure that returns the
--   complete activity trail of one Lab Order / Bill (used by the "i" icon on the
--   Lab Reporting Entry page).
--
--   Sources merged (newest first):
--     1. dbo.AuditLogs           - ModuleCode 'LAB' rows tied to the bill (booking, payment,
--                                  sample collection, report draft/submit/validate/approve/
--                                  re-collect, reporting sample status changes).
--                                  Matched on ReferenceNo = BillNo. ReferenceId is NOT used on
--                                  its own because B2B invoice rows also store an InvoiceId there.
--     2. dbo.SampleTransferAudit - sample transfer / receive events for the order.
--
--   No existing table or procedure is altered.
-- ============================================================================

USE [Dev_EMR];
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LabOrder_GetActivityHistory
    @LabOrderId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @BillNo NVARCHAR(100);
    SELECT @BillNo = lo.BillNo FROM dbo.LabOrder lo WHERE lo.LabOrderId = @LabOrderId;

    -- ── 1. Sample transfer / receive events, grouped per action ──────────────
    ;WITH T AS (
        SELECT
            t.TransferAuditId,
            t.SampleCollectionId,
            t.SourceBranchId,
            t.TargetBranchId,
            t.BarcodeNo,
            ISNULL(t.ActionType, 'TRANSFER')        AS ActionType,
            ISNULL(t.ActionDate, t.TransferredDate) AS EvDate,
            ISNULL(t.ActionBy, t.TransferredBy)     AS EvBy,
            t.TransferRemarks,
            lim.Test_Name                           AS TestName
        FROM dbo.SampleTransferAudit t
        LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = t.InvestigationId
        WHERE t.LabOrderId = @LabOrderId
    ),
    G AS (
        SELECT
            ActionType,
            EvDate,
            EvBy,
            MIN(SourceBranchId)  AS SourceBranchId,
            MIN(TargetBranchId)  AS TargetBranchId,
            MIN(TransferRemarks) AS Remarks,
            COUNT(*)             AS SampleCount
        FROM T
        GROUP BY ActionType, EvDate, EvBy
    )
    SELECT
        G.EvDate                                                    AS EventDate,
        CAST('TRANSFER' AS VARCHAR(20))                             AS Source,
        CASE WHEN G.ActionType = 'RECEIVE' THEN 'Sample Receive' ELSE 'Sample Transfer' END AS EventType,
        CASE WHEN G.ActionType = 'RECEIVE' THEN 'LAB.SampleReceived' ELSE 'LAB.SampleTransferred' END AS ActionName,
        CASE WHEN G.ActionType = 'RECEIVE'
             THEN CONCAT('Received ', G.SampleCount, ' sample(s) at ', ISNULL(tgt.BranchName, 'target branch'),
                         ' (sent from ', ISNULL(src.BranchName, 'source branch'), ').')
             ELSE CONCAT('Transferred ', G.SampleCount, ' sample(s) from ', ISNULL(src.BranchName, 'source branch'),
                         ' to ', ISNULL(tgt.BranchName, 'target branch'), '.')
        END
        + CASE WHEN NULLIF(LTRIM(RTRIM(G.Remarks)), '') IS NOT NULL THEN ' Remarks: ' + G.Remarks ELSE '' END AS Description,
        G.EvBy                                                      AS UserId,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username)    AS UserName,
        CASE WHEN G.ActionType = 'RECEIVE' THEN tgt.BranchName ELSE src.BranchName END AS BranchName,
        CAST(NULL AS NVARCHAR(64))                                  AS IpAddress,
        (
            SELECT
                src.BranchName AS SourceBranch,
                tgt.BranchName AS TargetBranch,
                G.Remarks      AS Remarks,
                (
                    SELECT t2.TestName, t2.BarcodeNo
                    FROM T t2
                    WHERE t2.ActionType = G.ActionType
                      AND ISNULL(t2.EvDate, '19000101') = ISNULL(G.EvDate, '19000101')
                      AND ISNULL(t2.EvBy, 0) = ISNULL(G.EvBy, 0)
                    FOR JSON PATH
                ) AS Tests
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        )                                                           AS MetadataJson
    INTO #TransferEvents
    FROM G
    LEFT JOIN dbo.Users        u   ON u.Id        = G.EvBy
    LEFT JOIN dbo.Branchmaster src ON src.BranchID = G.SourceBranchId
    LEFT JOIN dbo.Branchmaster tgt ON tgt.BranchID = G.TargetBranchId;

    -- ── 2. Merge with audit-log rows tied to the bill ────────────────────────
    SELECT
        x.EventDate, x.Source, x.EventType, x.ActionName, x.Description,
        x.UserId, x.UserName, x.BranchName, x.IpAddress, x.MetadataJson
    FROM (
        SELECT
            a.CreatedDate                                               AS EventDate,
            CAST('AUDIT' AS VARCHAR(20))                                AS Source,
            a.EventType,
            a.ActionName,
            a.Description,
            a.UserId,
            ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username)    AS UserName,
            b.BranchName,
            a.IpAddress,
            a.MetadataJson
        FROM dbo.AuditLogs a
        LEFT JOIN dbo.Users        u ON u.Id        = a.UserId
        LEFT JOIN dbo.Branchmaster b ON b.BranchID  = a.BranchId
        WHERE a.ModuleCode = 'LAB'
          AND (
                (@BillNo IS NOT NULL AND a.ReferenceNo = @BillNo)
                -- Older reporting sample-status rows were written with ReferenceId only
                OR (a.ReferenceNo IS NULL AND a.ReferenceId = @LabOrderId AND a.ActionName = 'LAB.SampleStatusChanged')
              )

        UNION ALL

        SELECT EventDate, Source, EventType, ActionName, Description,
               UserId, UserName, BranchName, IpAddress, MetadataJson
        FROM #TransferEvents
    ) x
    ORDER BY x.EventDate DESC;

    DROP TABLE #TransferEvents;
END;
GO

PRINT 'Created procedure dbo.usp_LabOrder_GetActivityHistory';
GO
