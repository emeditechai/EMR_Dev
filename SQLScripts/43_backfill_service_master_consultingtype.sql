-- ── Backfill existing Consulting services with 'Walking' ──────────────────────────
-- Set ConsultingType = 'Walking' for any service of type 'Consulting' that currently has no ConsultingType.

UPDATE dbo.ServiceMaster
SET ConsultingType = 'Walking'
WHERE ServiceType = 'Consulting'
  AND (ConsultingType IS NULL OR ConsultingType = '');

PRINT 'Backfilled old Consulting records with ConsultingType = ''Walking''.';
GO
