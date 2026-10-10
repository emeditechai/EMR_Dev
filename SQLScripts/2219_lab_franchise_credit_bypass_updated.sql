-- ============================================================================
-- Migration: 2219_lab_franchise_credit_bypass_updated.sql
-- Records who last changed the credit-limit bypass and when:
--   Bypass_Updated_By    INT      NULL  (Users.Id)
--   Bypass_Updated_Date  DATETIME NULL
-- Set only by usp_Api_LabFranchiseMaster_UpdateCreditBypass, which no longer
-- touches ModifiedBy / ModifiedDate (those stay for the main Edit). GetById and
-- GetList now return the bypass fields plus the updater's name for the
-- Franchise list and the Edit popup.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.LabFranchiseMaster', 'Bypass_Updated_By') IS NULL
    ALTER TABLE dbo.LabFranchiseMaster ADD Bypass_Updated_By INT NULL;
GO
IF COL_LENGTH('dbo.LabFranchiseMaster', 'Bypass_Updated_Date') IS NULL
    ALTER TABLE dbo.LabFranchiseMaster ADD Bypass_Updated_Date DATETIME NULL;
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
        Bypass_Updated_By     = @UserId,
        Bypass_Updated_Date   = GETDATE()
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
        f.Bypass_Updated_By,
        f.Bypass_Updated_Date,
        COALESCE(NULLIF(bu.FullName, ''), bu.Username) AS Bypass_Updated_By_Name,
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
    LEFT JOIN dbo.Users bu ON bu.Id = f.Bypass_Updated_By
    WHERE f.Franchise_ID = @Franchise_ID AND f.IsDeleted = 0;
END
GO

-- 3. Stored Procedure: usp_Api_LabFranchiseMaster_GetList
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabFranchiseMaster_GetList
    @Status           BIT = NULL, -- Is Suspended filter
    @IsActive         BIT = NULL, -- IsActive filter
    @Search           NVARCHAR(100) = NULL,
    @CompanyId        INT = NULL,
    @FranchiseType    INT = NULL,
    @ParentBranchId   INT = NULL
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
        f.Bypass_Updated_By,
        f.Bypass_Updated_Date,
        COALESCE(NULLIF(bu.FullName, ''), bu.Username) AS Bypass_Updated_By_Name,
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
    LEFT JOIN dbo.Users bu ON bu.Id = f.Bypass_Updated_By
    WHERE f.IsDeleted = 0
      AND (@Status IS NULL OR f.Status = @Status)
      AND (@IsActive IS NULL OR f.IsActive = @IsActive)
      AND (@CompanyId IS NULL OR f.CompanyId = @CompanyId)
      AND (@FranchiseType IS NULL OR f.Franchise_Type = @FranchiseType)
      AND (@ParentBranchId IS NULL OR f.Parent_Branch_ID = @ParentBranchId)
      AND (@Search IS NULL OR LTRIM(RTRIM(@Search)) = '' OR 
           f.Franchise_Name LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR 
           f.Franchise_Code LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           f.Mobile_No LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           f.Email LIKE '%' + LTRIM(RTRIM(@Search)) + '%')
    ORDER BY f.Franchise_ID DESC;
END
GO
