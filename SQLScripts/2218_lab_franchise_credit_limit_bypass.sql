-- ============================================================================
-- Migration: 2218_lab_franchise_credit_limit_bypass.sql
-- "Bypass Cr Limit" on the Franchise Edit page. Kept out of the main
-- Create / Update: the three columns below are written only by
-- usp_Api_LabFranchiseMaster_UpdateCreditBypass (opened from a popup), and
-- read back by usp_Api_LabFranchiseMaster_GetById.
--   Bypass_Credit_Limit    BIT  NOT NULL DEFAULT 0
--   Bypass_Effective_From  DATE NULL
--   Bypass_Effective_To    DATE NULL
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.LabFranchiseMaster', 'Bypass_Credit_Limit') IS NULL
    ALTER TABLE dbo.LabFranchiseMaster
        ADD Bypass_Credit_Limit BIT NOT NULL
            CONSTRAINT DF_LabFranchiseMaster_Bypass_Credit_Limit DEFAULT (0);
GO
IF COL_LENGTH('dbo.LabFranchiseMaster', 'Bypass_Effective_From') IS NULL
    ALTER TABLE dbo.LabFranchiseMaster ADD Bypass_Effective_From DATE NULL;
GO
IF COL_LENGTH('dbo.LabFranchiseMaster', 'Bypass_Effective_To') IS NULL
    ALTER TABLE dbo.LabFranchiseMaster ADD Bypass_Effective_To DATE NULL;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabFranchiseMaster_UpdateCreditBypass
    @Franchise_ID           INT,
    @Bypass_Credit_Limit    BIT,
    @Bypass_Effective_From  DATE = NULL,
    @Bypass_Effective_To    DATE = NULL,
    @UserId                 INT  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabFranchiseMaster WHERE Franchise_ID = @Franchise_ID AND IsDeleted = 0)
        THROW 50001, 'Lab Franchise not found.', 1;

    IF @Bypass_Credit_Limit = 1
    BEGIN
        IF @Bypass_Effective_From IS NULL OR @Bypass_Effective_To IS NULL
            THROW 50002, 'Effective From and Effective To are required to bypass the credit limit.', 1;
        IF @Bypass_Effective_To < @Bypass_Effective_From
            THROW 50003, 'Effective To cannot be earlier than Effective From.', 1;
    END
    ELSE
    BEGIN
        -- Turning the bypass off clears its period.
        SET @Bypass_Effective_From = NULL;
        SET @Bypass_Effective_To = NULL;
    END

    UPDATE dbo.LabFranchiseMaster
    SET Bypass_Credit_Limit   = @Bypass_Credit_Limit,
        Bypass_Effective_From = @Bypass_Effective_From,
        Bypass_Effective_To   = @Bypass_Effective_To,
        ModifiedBy            = @UserId,
        ModifiedDate          = GETDATE()
    WHERE Franchise_ID = @Franchise_ID AND IsDeleted = 0;
END
GO

-- 4. Stored Procedure: usp_Api_LabFranchiseMaster_GetById
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabFranchiseMaster_GetById
    @Franchise_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        f.Franchise_ID,
        f.CompanyId,
        f.Franchise_Code,
        f.Franchise_Name,
        ISNULL(f.Mobile_No, '') AS Mobile_No,
        f.Email,
        f.Franchise_Type,
        CASE f.Franchise_Type
            WHEN 1 THEN 'Collection Center'
            WHEN 2 THEN 'Franchise Lab'
            WHEN 3 THEN 'Pickup Point'
            WHEN 4 THEN 'Marketing'
            ELSE 'Unknown'
        END AS Franchise_Type_Name,
        f.Parent_Branch_ID,
        pb.BranchName AS Parent_Branch_Name,
        f.Onboarding_Date,
        f.Go_Live_Date,
        f.Agreement_Doc_Path,
        f.Agreement_Valid_From,
        f.Agreement_Valid_To,
        f.Status,
        f.Suspension_Reason,
        f.IsActive,
        f.IsNotificationRequired,
        f.PreprintedBarcode,
        f.IsReportHeaderRequired,
        f.Bypass_Credit_Limit,
        f.Bypass_Effective_From,
        f.Bypass_Effective_To,
        f.CreatedBy,
        f.CreatedDate,
        f.ModifiedBy,
        f.ModifiedDate,

        -- Credit Limit Details
        c.Credit_ID,
        ISNULL(c.Credit_Facility_Type, 1) AS Credit_Facility_Type,
        CASE c.Credit_Facility_Type
            WHEN 1 THEN 'Prepaid (Wallet)'
            WHEN 2 THEN 'Postpaid (Credit)'
            WHEN 3 THEN 'Hybrid'
            ELSE 'Prepaid (Wallet)'
        END AS Credit_Facility_Type_Name,
        ISNULL(c.Credit_Limit, 0.00) AS Credit_Limit,
        c.Credit_Days,
        ISNULL(c.Grace_Days, 0) AS Grace_Days,
        c.Security_Deposit_Amount,
        c.Security_Deposit_Received_On,
        c.Interest_On_Overdue_Percent,
        ISNULL(c.Temporary_Limit_Increase, 0.00) AS Temporary_Limit_Increase,
        c.Temp_Limit_Valid_Till
    FROM dbo.LabFranchiseMaster f
    LEFT JOIN dbo.Branchmaster pb ON f.Parent_Branch_ID = pb.BranchID
    LEFT JOIN dbo.LabFranchiseCreditLimitMaster c ON f.Franchise_ID = c.Franchise_ID
    WHERE f.Franchise_ID = @Franchise_ID AND f.IsDeleted = 0;
END
GO
