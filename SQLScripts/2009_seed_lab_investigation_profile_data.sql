-- =================================================================================
-- Script Name: 2009_seed_lab_investigation_profile_data.sql
-- Description: Seeds initial Lab Investigation Profiles / Packages and Details.
-- Database:    Dev_EMR (SQL Server)
-- =================================================================================

USE [Dev_EMR];
GO

-- Seed Profile 1: Complete Blood Count Profile (PRF0001)
IF NOT EXISTS (SELECT 1 FROM [dbo].[LabInvestigationProfileHeader] WHERE [Profile_Code] = 'PRF0001' AND [IsDeleted] = 0)
BEGIN
    INSERT INTO [dbo].[LabInvestigationProfileHeader]
    ([CompanyId], [Profile_Code], [Profile_Name], [Profile_Type], [MRP], [Discount_Pct], [Age_Operator], [Applicable_Age], [Applicable_Gender], [Profile_TAT_Hours], [Profile_NABL_Accredited], [Report_Print_Sequence], [Status], [IsDeleted], [CreatedDate])
    VALUES
    (1, 'PRF0001', 'Complete Blood Count (CBC) Panel', 'Profile', 450.00, 10.00, NULL, NULL, 'All', 12, 1, 1, 1, 0, GETDATE());

    DECLARE @Pid1 INT = SCOPE_IDENTITY();

    INSERT INTO [dbo].[LabInvestigationProfileDetail] ([Profile_ID], [Test_ID], [Sequence], [IsDeleted], [CreatedDate])
    SELECT @Pid1, Test_ID, 1, 0, GETDATE() FROM [dbo].[LabInvestigationMaster] WHERE Test_Code = 'TST0001'
    UNION ALL
    SELECT @Pid1, Test_ID, 2, 0, GETDATE() FROM [dbo].[LabInvestigationMaster] WHERE Test_Code = 'TST0002';
END

-- Seed Profile 2: Executive Senior Citizen Health Package (PRF0002)
IF NOT EXISTS (SELECT 1 FROM [dbo].[LabInvestigationProfileHeader] WHERE [Profile_Code] = 'PRF0002' AND [IsDeleted] = 0)
BEGIN
    INSERT INTO [dbo].[LabInvestigationProfileHeader]
    ([CompanyId], [Profile_Code], [Profile_Name], [Profile_Type], [MRP], [Discount_Pct], [Age_Operator], [Applicable_Age], [Applicable_Gender], [Profile_TAT_Hours], [Profile_NABL_Accredited], [Report_Print_Sequence], [Status], [IsDeleted], [CreatedDate])
    VALUES
    (1, 'PRF0002', 'Senior Citizen Executive Health Bundle', 'Package', 2500.00, 20.00, 'GreaterEqual', 50, 'All', 24, 1, 2, 1, 0, GETDATE());

    DECLARE @Pid2 INT = SCOPE_IDENTITY();

    INSERT INTO [dbo].[LabInvestigationProfileDetail] ([Profile_ID], [Test_ID], [Sequence], [IsDeleted], [CreatedDate])
    SELECT @Pid2, Test_ID, 1, 0, GETDATE() FROM [dbo].[LabInvestigationMaster] WHERE Test_Code = 'TST0001'
    UNION ALL
    SELECT @Pid2, Test_ID, 2, 0, GETDATE() FROM [dbo].[LabInvestigationMaster] WHERE Test_Code = 'TST0003'
    UNION ALL
    SELECT @Pid2, Test_ID, 3, 0, GETDATE() FROM [dbo].[LabInvestigationMaster] WHERE Test_Code = 'TST0005'
    UNION ALL
    SELECT @Pid2, Test_ID, 4, 0, GETDATE() FROM [dbo].[LabInvestigationMaster] WHERE Test_Code = 'TST0006';
END

PRINT 'Seed data for Lab Investigation Profile Master inserted successfully.';
GO
