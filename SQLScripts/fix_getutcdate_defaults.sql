-- Fix all GETUTCDATE() default constraints → GETDATE()
DECLARE @sql NVARCHAR(MAX) = '';

SELECT @sql = @sql +
    'ALTER TABLE [' + t.name + '] DROP CONSTRAINT [' + dc.name + '];' + CHAR(13) +
    'ALTER TABLE [' + t.name + '] ADD DEFAULT (GETDATE()) FOR [' + c.name + '];' + CHAR(13)
FROM sys.default_constraints dc
JOIN sys.columns c ON dc.parent_object_id = c.object_id
                   AND dc.parent_column_id = c.column_id
JOIN sys.tables t  ON dc.parent_object_id = t.object_id
WHERE dc.definition LIKE '%getutcdate%'
ORDER BY t.name;

IF LEN(@sql) > 0
BEGIN
    PRINT 'Executing:';
    PRINT @sql;
    EXEC sp_executesql @sql;
    PRINT 'Done — all GETUTCDATE defaults replaced with GETDATE().';
END
ELSE
    PRINT 'No GETUTCDATE default constraints found.';
GO
