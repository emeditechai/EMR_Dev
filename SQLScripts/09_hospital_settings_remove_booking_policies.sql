-- ============================================================
-- 09_hospital_settings_remove_booking_policies.sql
-- Drop Booking & Policies columns from HospitalSettings table
-- ============================================================

IF OBJECT_ID('HospitalSettings', 'U') IS NULL
BEGIN
    PRINT 'HospitalSettings table not found.';
    RETURN;
END
GO

DECLARE @tableName SYSNAME = 'HospitalSettings';

DECLARE @cols TABLE (ColumnName SYSNAME);
INSERT INTO @cols (ColumnName)
VALUES
('ByPassActualDayRate'),
('DiscountApprovalRequired'),
('MinimumBookingAmountRequired'),
('MinimumBookingAmount'),
('NoShowGraceHours'),
('CancellationRefundApprovalThreshold');

DECLARE @col SYSNAME;
DECLARE col_cursor CURSOR FOR SELECT ColumnName FROM @cols;
OPEN col_cursor;
FETCH NEXT FROM col_cursor INTO @col;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF COL_LENGTH(@tableName, @col) IS NOT NULL
    BEGIN
        DECLARE @dropDefaultsSql NVARCHAR(MAX) = N'';
        SELECT @dropDefaultsSql = STRING_AGG(
            'ALTER TABLE [' + @tableName + '] DROP CONSTRAINT [' + dc.name + '];',
            CHAR(10)
        )
        FROM sys.default_constraints dc
        INNER JOIN sys.columns c
            ON c.object_id = dc.parent_object_id
           AND c.column_id = dc.parent_column_id
        WHERE dc.parent_object_id = OBJECT_ID(@tableName)
          AND c.name = @col;

        IF @dropDefaultsSql IS NOT NULL AND LEN(@dropDefaultsSql) > 0
            EXEC sp_executesql @dropDefaultsSql;

        EXEC ('ALTER TABLE [' + @tableName + '] DROP COLUMN [' + @col + '];');
        PRINT 'Dropped column: ' + @col;
    END
    ELSE
    BEGIN
        PRINT 'Column not present, skipped: ' + @col;
    END

    FETCH NEXT FROM col_cursor INTO @col;
END

CLOSE col_cursor;
DEALLOCATE col_cursor;
GO
