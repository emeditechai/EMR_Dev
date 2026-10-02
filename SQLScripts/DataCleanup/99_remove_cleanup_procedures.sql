-- ============================================================================
-- DataCleanup / 99_remove_cleanup_procedures.sql
-- Removes the clean-up procedures (schema [cleanup]) once the go-live clean-up is done, so nothing that can
-- delete data in bulk stays in the database. Run 00_install_cleanup_procedures.sql again if they are ever needed.
-- ============================================================================
SET NOCOUNT ON;
DECLARE @sql NVARCHAR(MAX) = N'';
SELECT @sql += N'DROP ' + CASE o.type WHEN 'P' THEN N'PROCEDURE ' ELSE N'FUNCTION ' END
             + QUOTENAME(SCHEMA_NAME(o.schema_id)) + N'.' + QUOTENAME(o.name) + N';' + CHAR(10)
FROM sys.objects o WHERE o.schema_id = SCHEMA_ID('cleanup') AND o.type IN ('P', 'IF', 'FN', 'TF');
EXEC sys.sp_executesql @sql;
IF SCHEMA_ID('cleanup') IS NOT NULL EXEC (N'DROP SCHEMA cleanup');
PRINT 'DataCleanup procedures removed.';
