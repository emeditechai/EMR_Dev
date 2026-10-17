-- ============================================================================================================
-- Migration: 2280_b2b_cancel_blocked_when_invoiced.sql
-- LAB > Bill Cancellation: a B2B bill that is already on a B2B invoice cannot be cancelled (fully or partly).
-- Checked when the bill is opened for cancellation (usp_Bill_GetDetailForCancellation) and again when the
-- cancellation is saved (usp_Bill_Cancel), so no screen can get round it.
-- Patches the live procedures in place. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @check NVARCHAR(MAX) = N'
    -- 2280: a B2B bill already on a B2B invoice cannot be cancelled
    IF @ModuleCode = ''LAB''
    BEGIN
        DECLARE @InvoiceNo2280 NVARCHAR(50) = (SELECT TOP 1 i.InvoiceNo FROM dbo.B2BInvoiceItem ii
                                               INNER JOIN dbo.B2BInvoice i ON i.InvoiceId = ii.InvoiceId
                                               WHERE ii.LabOrderId = @ModuleRefId AND ISNULL(i.Status, '''') <> ''C'' ORDER BY i.InvoiceId DESC);
        IF @InvoiceNo2280 IS NOT NULL
        BEGIN
            DECLARE @Msg2280 NVARCHAR(400) = CONCAT(N''This B2B bill is already invoiced (Invoice '', @InvoiceNo2280,
                N'') and cannot be cancelled. Cancel or correct it through the partner''''s invoice instead.'');
            THROW 50280, @Msg2280, 1;
        END
    END
';
DECLARE @name SYSNAME, @def NVARCHAR(MAX), @anchor NVARCHAR(100), @p INT, @c INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR
    SELECT v.n, v.a FROM (VALUES (N'dbo.usp_Bill_GetDetailForCancellation', N'    SET NOCOUNT ON;'),
                                 (N'dbo.usp_Bill_Cancel',                  N'    BEGIN TRY')) v(n, a);
OPEN pc; FETCH NEXT FROM pc INTO @name, @anchor;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @def = OBJECT_DEFINITION(OBJECT_ID(@name));
    IF @def IS NULL THROW 55300, 'A cancellation procedure was not found; not changed.', 1;
    IF CHARINDEX(N'2280:', @def) = 0
    BEGIN
        SET @p = CHARINDEX(@anchor, @def);
        IF @p = 0 THROW 55301, 'Anchor not found in a cancellation procedure; not changed.', 1;
        IF @anchor = N'    SET NOCOUNT ON;' SET @p = @p + LEN(@anchor) + 1;   -- after SET NOCOUNT ON
        SET @def = STUFF(@def, @p, 0, @check + CHAR(13) + CHAR(10));
        SET @c = PATINDEX(N'%CREATE%PROCEDURE%', @def);
        SET @def = STUFF(@def, @c, CHARINDEX(N'PROCEDURE', @def, @c) + 9 - @c, N'CREATE OR ALTER PROCEDURE');
        IF @def IS NULL THROW 55302, 'A cancellation procedure text could not be prepared; not changed.', 1;
        EXEC sys.sp_executesql @def;
    END
    FETCH NEXT FROM pc INTO @name, @anchor;
END
CLOSE pc; DEALLOCATE pc;
GO

PRINT 'Script 2280 applied: an invoiced B2B bill cannot be cancelled.';
GO
