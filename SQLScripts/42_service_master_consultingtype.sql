-- ── Add ConsultingType column to ServiceMaster ────────────────────────────────
-- Applicable when ServiceType = 'Consulting'. Values: 'Walking', 'Video', or NULL.

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.ServiceMaster')
      AND name = 'ConsultingType'
)
BEGIN
    ALTER TABLE dbo.ServiceMaster
    ADD ConsultingType NVARCHAR(20) NULL;
    PRINT 'Column ConsultingType added to ServiceMaster.';
END
ELSE
BEGIN
    PRINT 'Column ConsultingType already exists. Skipped.';
END
GO
