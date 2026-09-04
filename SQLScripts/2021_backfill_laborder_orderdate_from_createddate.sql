-- =============================================================
-- Migration 2021: Backfill LabOrder.OrderDate for existing records
-- =============================================================
-- For old records created before migration 2020, OrderDate was
-- set to BookingDate (or GETDATE() if no booking date).
-- Now OrderDate should represent the Bill creation time.
-- Since CreatedDate is always GETDATE() at insert, we use it
-- as the authoritative Bill Date for old records.
-- =============================================================

UPDATE dbo.LabOrder
SET OrderDate = CreatedDate
WHERE CreatedDate IS NOT NULL
  AND (
      -- Records where OrderDate = BookingDate (old bad data)
      (BookingDate IS NOT NULL AND DATEDIFF(MINUTE, OrderDate, BookingDate) = 0)
      -- OR records where OrderDate differs significantly from CreatedDate
      -- (CreatedDate is always the true insert time)
      OR ABS(DATEDIFF(SECOND, OrderDate, CreatedDate)) > 5
  );

PRINT CAST(@@ROWCOUNT AS VARCHAR) + ' LabOrder records backfilled: OrderDate set to CreatedDate.';
GO
