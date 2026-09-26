-- =============================================
-- Script: 2132_radiology_investigation_rates.sql
-- Description: Updates MRP rates for Radiology Investigation tests
-- Database: Dev_EMR (SQL Server)
-- =============================================

USE [Dev_EMR];
GO

SET NOCOUNT ON;

PRINT 'Updating MRP rates for Radiology investigation tests...';

-- X-Ray Tests
UPDATE dbo.LabInvestigationMaster SET MRP = 300.00  WHERE Test_Code = 'RAD-XR-001' AND IsDeleted = 0; -- X-Ray Chest PA
UPDATE dbo.LabInvestigationMaster SET MRP = 350.00  WHERE Test_Code = 'RAD-XR-002' AND IsDeleted = 0; -- X-Ray Abdomen AP
UPDATE dbo.LabInvestigationMaster SET MRP = 400.00  WHERE Test_Code = 'RAD-XR-003' AND IsDeleted = 0; -- X-Ray Spine
UPDATE dbo.LabInvestigationMaster SET MRP = 500.00  WHERE Test_Code = 'RAD-XR-004' AND IsDeleted = 0; -- X-Ray Knee (Both)

-- CT Scan Tests
UPDATE dbo.LabInvestigationMaster SET MRP = 3500.00 WHERE Test_Code = 'RAD-CT-001' AND IsDeleted = 0; -- CT Brain (Plain)
UPDATE dbo.LabInvestigationMaster SET MRP = 5000.00 WHERE Test_Code = 'RAD-CT-002' AND IsDeleted = 0; -- CT Brain (Contrast)
UPDATE dbo.LabInvestigationMaster SET MRP = 4500.00 WHERE Test_Code = 'RAD-CT-003' AND IsDeleted = 0; -- CT Chest (HRCT)
UPDATE dbo.LabInvestigationMaster SET MRP = 6000.00 WHERE Test_Code = 'RAD-CT-004' AND IsDeleted = 0; -- CT Abdomen & Pelvis (Contrast)
UPDATE dbo.LabInvestigationMaster SET MRP = 3000.00 WHERE Test_Code = 'RAD-CT-005' AND IsDeleted = 0; -- CT PNS (Plain)

-- MRI Tests
UPDATE dbo.LabInvestigationMaster SET MRP = 6000.00 WHERE Test_Code = 'RAD-MR-001' AND IsDeleted = 0; -- MRI Brain (Plain)
UPDATE dbo.LabInvestigationMaster SET MRP = 8000.00 WHERE Test_Code = 'RAD-MR-002' AND IsDeleted = 0; -- MRI Brain (Contrast)
UPDATE dbo.LabInvestigationMaster SET MRP = 6500.00 WHERE Test_Code = 'RAD-MR-003' AND IsDeleted = 0; -- MRI Lumbar Spine
UPDATE dbo.LabInvestigationMaster SET MRP = 6000.00 WHERE Test_Code = 'RAD-MR-004' AND IsDeleted = 0; -- MRI Knee

-- USG Tests
UPDATE dbo.LabInvestigationMaster SET MRP = 1200.00 WHERE Test_Code = 'RAD-US-001' AND IsDeleted = 0; -- USG Abdomen (Whole)
UPDATE dbo.LabInvestigationMaster SET MRP = 1000.00 WHERE Test_Code = 'RAD-US-002' AND IsDeleted = 0; -- USG Pelvis
UPDATE dbo.LabInvestigationMaster SET MRP = 1500.00 WHERE Test_Code = 'RAD-US-003' AND IsDeleted = 0; -- USG Obstetric (Anomaly Scan)
UPDATE dbo.LabInvestigationMaster SET MRP = 800.00  WHERE Test_Code = 'RAD-US-004' AND IsDeleted = 0; -- USG Thyroid
UPDATE dbo.LabInvestigationMaster SET MRP = 1000.00 WHERE Test_Code = 'RAD-US-005' AND IsDeleted = 0; -- USG KUB

-- Mammography
UPDATE dbo.LabInvestigationMaster SET MRP = 2500.00 WHERE Test_Code = 'RAD-MG-001' AND IsDeleted = 0; -- Mammography (Bilateral)

-- Doppler
UPDATE dbo.LabInvestigationMaster SET MRP = 2000.00 WHERE Test_Code = 'RAD-DP-001' AND IsDeleted = 0; -- Doppler Carotid (Bilateral)
UPDATE dbo.LabInvestigationMaster SET MRP = 2500.00 WHERE Test_Code = 'RAD-DP-002' AND IsDeleted = 0; -- Doppler Lower Limb Venous

PRINT 'Radiology investigation MRP rates updated successfully.';
GO
