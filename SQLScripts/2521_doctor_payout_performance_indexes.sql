-- ============================================================================================================
-- Migration: 2521_doctor_payout_performance_indexes.sql   (application database)
-- OPD > Doctor Commission & Disbursals loads faster: the doctor share calculation (ufn_DoctorPayout_VisitShare, run on
-- every board load for 90 days of visits, and by the reports / item breakdown) looks up each visit's consultation and
-- service lines and reads visits by branch and bill date - neither had an index (a full scan per visit).
--   IX_PatientOPDServiceItem_OPDService : PatientOPDServiceItem (OPDServiceId, ServiceType, IsActive) + ServiceId, ServiceCharges
--   IX_PatientOPDService_BranchCreated  : PatientOPDService (BranchId, CreatedDate) + the columns the share reads
-- Indexes only (no data or logic change). Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_PatientOPDServiceItem_OPDService' AND object_id = OBJECT_ID(N'dbo.PatientOPDServiceItem'))
    CREATE INDEX IX_PatientOPDServiceItem_OPDService ON dbo.PatientOPDServiceItem (OPDServiceId, ServiceType, IsActive)
        INCLUDE (ServiceId, ServiceCharges);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_PatientOPDService_BranchCreated' AND object_id = OBJECT_ID(N'dbo.PatientOPDService'))
    CREATE INDEX IX_PatientOPDService_BranchCreated ON dbo.PatientOPDService (BranchId, CreatedDate)
        INCLUDE (ConsultingDoctorId, PatientId, CompanyId, IsActive, TotalAmount);
GO
PRINT 'Script 2521 applied: doctor payout performance indexes.';
GO
