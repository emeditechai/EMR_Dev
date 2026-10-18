-- ============================================================================================================
-- Migration: 2292_hospital_settings_lab_bill_page_size.sql
-- Hospital Settings > LAB > Printing > "LAB Bill Print Page Size": A4 (default - the bill prints exactly as before) or
-- A5L (A5 landscape - the same bill, compact, on half an A4 sheet). Applies to the LAB bill print (B2C and B2B).
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
IF COL_LENGTH('dbo.HospitalSettings', 'LabBillPrintPageSize') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD LabBillPrintPageSize VARCHAR(5) NOT NULL
        CONSTRAINT DF_HospitalSettings_LabBillPrintPageSize DEFAULT ('A4')
        CONSTRAINT CK_HospitalSettings_LabBillPrintPageSize CHECK (LabBillPrintPageSize IN ('A4', 'A5L'));
GO
PRINT 'Script 2292 applied: Hospital Settings - LAB Bill Print Page Size.';
GO
