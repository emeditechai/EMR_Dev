-- ============================================================================================================
-- Migration: 2290_lab_reporting_filter_by_collection_date.sql
-- LAB Reporting, Image Report Entry and Microbiology Report Entry: "Filter by date" gets "Sample Collection DateTime"
-- (the screens' new default). An order falls in the period when its first collected sample (collection date + time)
-- does. dbo.usp_LabReporting_GetHeaderList is patched in place: one more value of @DateFilterType ('CollectionDate');
-- 'BookingDate' and 'OrderDate' work exactly as before. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_LabReporting_GetHeaderList'));
IF @def IS NULL
    THROW 50290, 'dbo.usp_LabReporting_GetHeaderList not found.', 1;

IF CHARINDEX(N'MinCollectionDateTime', @def) = 0
BEGIN
    DECLARE @a NVARCHAR(200) = N'MIN(sc.Orderdate) AS MinOrderDate,';
    DECLARE @b NVARCHAR(300) = N'OR (@DateFilterType = ''OrderDate'' AND lo.OrderDate BETWEEN @FromDate AND @ToDate)';
    IF CHARINDEX(@a, @def) = 0 OR CHARINDEX(@b, @def) = 0
        THROW 50291, 'usp_LabReporting_GetHeaderList is not the expected version (2179); patch not applied.', 1;

    -- first collection of the order's collected samples, as a date + time
    SET @def = REPLACE(@def, @a, @a + N'
            MIN(CASE WHEN sc.CollectionstatusID = 2 AND sc.Samplecollectiondate IS NOT NULL
                     THEN CAST(sc.Samplecollectiondate AS DATETIME) + CAST(ISNULL(sc.Samplecollectiontime, ''00:00'') AS DATETIME) END) AS MinCollectionDateTime,');
    SET @def = REPLACE(@def, @b, @b + N'
        OR (@DateFilterType = ''CollectionDate'' AND eo.MinCollectionDateTime BETWEEN @FromDate AND @ToDate)');

    -- CREATE -> CREATE OR ALTER
    DECLARE @p INT = PATINDEX(N'%CREATE%PROCEDURE%', @def);
    IF @p > 0 AND SUBSTRING(@def, @p, 15) NOT LIKE N'CREATE OR ALTER%'
        SET @def = STUFF(@def, @p, CHARINDEX(N'PROCEDURE', @def, @p) - @p, N'CREATE OR ALTER ');
    EXEC sys.sp_executesql @def;
    PRINT 'usp_LabReporting_GetHeaderList: Sample Collection DateTime filter added.';
END
ELSE PRINT 'usp_LabReporting_GetHeaderList already filters by collection date.';
GO
PRINT 'Script 2290 applied.';
GO
