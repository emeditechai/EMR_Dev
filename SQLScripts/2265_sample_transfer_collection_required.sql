-- ============================================================================================================
-- Migration: 2265_sample_transfer_collection_required.sql
-- Sample Transfer (Dispatch and Receive worklists, their counts): a test whose category says
-- "Is Sample Collection Required = No" (LabTestCategoryMaster.Is_Sample_Collection_Required = 0, e.g. Radiology -
-- X-Ray, USG, CT) has no physical sample to send, so it is no longer listed. A test with no category stays listed.
-- The transfer itself refuses such a sample too (SampleTransferController).
-- Patches the live procedures in place (their other logic untouched). Safe to re-run. Run after 2264.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @anchor NVARCHAR(400) = N'AND (@SubCategoryId IS NULL OR sc.TestsubcategoryID = @SubCategoryId OR lim.SubCategory_ID = @SubCategoryId)';
DECLARE @rule NVARCHAR(600) = @anchor + N'
      -- 2265: only tests that need a sample (category "Is Sample Collection Required")
      AND NOT EXISTS (SELECT 1 FROM dbo.LabTestCategoryMaster ncat
                      WHERE ncat.Category_ID = ISNULL(lim.Category_ID, sc.TestcategoryID) AND ncat.Is_Sample_Collection_Required = 0)';
DECLARE @p SYSNAME, @def NVARCHAR(MAX), @c INT;
DECLARE procs CURSOR LOCAL FAST_FORWARD FOR
    SELECT N'usp_SampleTransfer_GetEligibleSamples' UNION ALL SELECT N'usp_SampleTransfer_GetReceivableSamples';
OPEN procs; FETCH NEXT FROM procs INTO @p;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @def = OBJECT_DEFINITION(OBJECT_ID(N'dbo.' + @p));
    IF @def IS NULL THROW 55200, 'Script 2265: a sample transfer procedure was not found.', 1;
    IF CHARINDEX(N'-- 2265:', @def) = 0
    BEGIN
        IF (LEN(@def) - LEN(REPLACE(@def, @anchor, N''))) / LEN(@anchor) <> 2
            THROW 55201, 'Script 2265: the filter anchor was not found twice (summary + list); not changed.', 1;
        SET @def = REPLACE(@def, @anchor, @rule);
        SET @c = PATINDEX(N'%CREATE%PROCEDURE%', @def);
        SET @def = STUFF(@def, @c, CHARINDEX(N'PROCEDURE', @def, @c) + 9 - @c, N'CREATE OR ALTER PROCEDURE');
        IF @def IS NULL THROW 55202, 'Script 2265: the procedure text could not be prepared; not changed.', 1;
        EXEC sys.sp_executesql @def;
    END
    FETCH NEXT FROM procs INTO @p;
END
CLOSE procs; DEALLOCATE procs;
GO

PRINT 'Script 2265 applied: Sample Transfer lists only tests whose category needs a sample.';
GO
