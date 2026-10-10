-- ============================================================================
-- Migration: 2199_lab_rate_list_bookable_items.sql
-- Description: LAB billing offers and bills only what is on the branch's rate list.
--   Before: usp_GetAvailableInvestigations LEFT JOINed the rate list and fell back to the master MRP, so every billable
--   test / profile / package of the master appeared in B2C billing - priced at master MRP - even when it was not on the
--   branch's B2C rate list (e.g. LAB/KOL2627000017 billed a test that Kolkata's rate list does not have), and the save
--   accepted it.
--   Now one rule, dbo.fn_LabBookableItems(@BranchId, @RateType, @AgentId): an item is bookable when it has an active row
--   (Status = 1, not deleted) on an active, in-date rate list -
--     B2C            the branch's B2C rate list;
--     Franchise / Corporate (B2B)   the partner's rate list, or else the branch's B2C rate list (as before).
--   * usp_GetAvailableInvestigations returns only those items, at the rate-list price (no master-MRP fallback for B2C).
--   * usp_CreateLabOrder refuses a bill with an item not on the list, and a B2C item whose price is not the rate-list price.
--   Run after 2198.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER FUNCTION dbo.fn_LabBookableItems (@BranchId INT, @RateType VARCHAR(50), @AgentId INT)
RETURNS TABLE
AS RETURN
(
    WITH b2cCard AS (
        SELECT TOP 1 m.RateCard_ID
        FROM dbo.LabRateCardMaster m
        WHERE m.Branch_ID = @BranchId AND m.Rate_Type = 'B2C' AND m.Status = 1 AND m.IsDeleted = 0
          AND CAST(GETDATE() AS DATE) BETWEEN m.Effective_From AND m.Effective_To
        ORDER BY m.Effective_From DESC, m.RateCard_ID DESC
    ),
    partnerCard AS (
        SELECT TOP 1 m.RateCard_ID
        FROM dbo.LabRateCardMaster m
        WHERE ISNULL(@RateType, 'B2C') <> 'B2C' AND @AgentId IS NOT NULL
          AND (m.Branch_ID = @BranchId OR (m.Rate_Type = 'Corporate' AND m.Branch_ID IS NULL))
          AND m.Rate_Type = @RateType AND m.B2CIdentity_ID = @AgentId AND m.Status = 1 AND m.IsDeleted = 0
          AND CAST(GETDATE() AS DATE) BETWEEN m.Effective_From AND m.Effective_To
        ORDER BY CASE WHEN m.Branch_ID = @BranchId THEN 0 ELSE 1 END, m.Effective_From DESC, m.RateCard_ID DESC
    ),
    b2c AS (
        SELECT d.Item_Type, d.Item_ID, d.Rate, d.Is_Discount_Allowed,
               ROW_NUMBER() OVER (PARTITION BY d.Item_Type, d.Item_ID ORDER BY d.Detail_ID DESC) AS rn
        FROM dbo.LabRateCardDetail d
        WHERE d.RateCard_ID IN (SELECT RateCard_ID FROM b2cCard) AND d.IsDeleted = 0 AND d.Status = 1
    ),
    partner AS (
        SELECT d.Item_Type, d.Item_ID, d.Rate, d.Is_Discount_Allowed,
               ROW_NUMBER() OVER (PARTITION BY d.Item_Type, d.Item_ID ORDER BY d.Detail_ID DESC) AS rn
        FROM dbo.LabRateCardDetail d
        WHERE d.RateCard_ID IN (SELECT RateCard_ID FROM partnerCard) AND d.IsDeleted = 0 AND d.Status = 1
    ),
    keys AS (
        SELECT Item_Type, Item_ID FROM b2c WHERE rn = 1
        UNION
        SELECT Item_Type, Item_ID FROM partner WHERE rn = 1
    )
    SELECT k.Item_Type, k.Item_ID,
           c.Rate AS B2CRate, c.Is_Discount_Allowed AS B2CDiscountAllowed,
           p.Rate AS PartnerRate, p.Is_Discount_Allowed AS PartnerDiscountAllowed
    FROM keys k
    LEFT JOIN b2c c ON c.rn = 1 AND c.Item_Type = k.Item_Type AND c.Item_ID = k.Item_ID
    LEFT JOIN partner p ON p.rn = 1 AND p.Item_Type = k.Item_Type AND p.Item_ID = k.Item_ID
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAvailableInvestigations
    @BranchId INT,
    @DepartmentId INT = NULL,
    @CategoryId INT = NULL,
    @SubCategoryId INT = NULL,
    @Gender VARCHAR(20) = NULL,
    @AgeInYears INT = NULL,
    @RateType VARCHAR(50) = 'B2C',
    @AgentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @RateType = NULLIF(LTRIM(RTRIM(@RateType)), '');
    DECLARE @IsB2C BIT = CASE WHEN ISNULL(@RateType, 'B2C') = 'B2C' THEN 1 ELSE 0 END;

    -- only what is on the rate list (script 2199)
    DECLARE @Bookable TABLE (Item_Type VARCHAR(20), Item_ID INT, B2CRate DECIMAL(18,2), B2CDiscountAllowed BIT, PartnerRate DECIMAL(18,2), PartnerDiscountAllowed BIT,
                             PRIMARY KEY (Item_Type, Item_ID));
    INSERT INTO @Bookable SELECT Item_Type, Item_ID, B2CRate, B2CDiscountAllowed, PartnerRate, PartnerDiscountAllowed
    FROM dbo.fn_LabBookableItems(@BranchId, ISNULL(@RateType, 'B2C'), @AgentId);

    -- 1. Investigations & Profiles from LabInvestigationMaster
    SELECT
        i.Test_ID as InvestigationId,
        i.Test_Code as TestCode,
        i.Test_Name as TestName,
        i.TAT_Hours as TATHours,
        CAST(CASE WHEN @IsB2C = 1 THEN b.B2CRate ELSE COALESCE(b.B2CRate, i.MRP, 0) END AS DECIMAL(18,2)) as MRP,
        CAST(ISNULL(i.Is_Profile_Test, 0) AS BIT) as IsProfileTest,
        h.Profile_ID as ProfileId,
        h.Profile_Code as ProfileCode,
        st.Sample_Name as SampleType,
        tm.Method_Name as Method,
        CAST(ISNULL(COALESCE(b.PartnerDiscountAllowed, b.B2CDiscountAllowed), 0) AS BIT) as IsDiscountAllowed,
        CAST(0 AS BIT) as IsPackage,
        CAST(ISNULL(i.Is_Outsourced, 0) AS BIT) as IsOutsourced,
        CAST(COALESCE(b.PartnerRate, b.B2CRate) AS DECIMAL(18,2)) as B2BRate
    FROM LabInvestigationMaster i
    INNER JOIN @Bookable b ON b.Item_ID = i.Test_ID AND b.Item_Type = CASE WHEN i.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END
    OUTER APPLY (SELECT TOP 1 hh.Profile_ID, hh.Profile_Code FROM LabInvestigationProfileHeader hh
                 WHERE (hh.Test_ID = i.Test_ID OR hh.Profile_Name = i.Test_Name) AND hh.IsDeleted = 0 AND hh.Profile_Type = 1
                 ORDER BY CASE WHEN hh.Test_ID = i.Test_ID THEN 0 ELSE 1 END, hh.Profile_ID) h
    LEFT JOIN dbo.LabSampleTypeMaster st ON i.Sample_Type_ID = st.Sample_Type_ID
    LEFT JOIN dbo.LabTestMethodMaster tm ON i.Method_ID = tm.Method_ID
    WHERE i.Status = 1 AND i.IsDeleted = 0
      AND i.Is_Billable = 1
      AND (@DepartmentId IS NULL OR i.Department_ID = @DepartmentId)
      AND (@CategoryId IS NULL OR i.Category_ID = @CategoryId)
      AND (@SubCategoryId IS NULL OR i.SubCategory_ID = @SubCategoryId)
      AND (
          i.Applicable_Gender = 'All'
          OR @Gender IS NULL
          OR i.Applicable_Gender = @Gender
      )
      AND (
          i.Age_Operator IS NULL
          OR i.Age_Operator = '-- No Age Limit --'
          OR @AgeInYears IS NULL
          OR (i.Age_Operator = '=' AND @AgeInYears = i.Applicable_Age)
          OR (i.Age_Operator = '>=' AND @AgeInYears >= i.Applicable_Age)
          OR (i.Age_Operator = '<=' AND @AgeInYears <= i.Applicable_Age)
      )

    UNION ALL

    -- 2. Packages from LabInvestigationProfileHeader (Profile_Type = 2)
    SELECT
        h.Profile_ID as InvestigationId,
        h.Profile_Code as TestCode,
        h.Profile_Name as TestName,
        h.Profile_TAT_Hours as TATHours,
        CAST(CASE WHEN @IsB2C = 1 THEN b.B2CRate ELSE COALESCE(b.B2CRate, h.MRP, 0) END AS DECIMAL(18,2)) as MRP,
        CAST(0 AS BIT) as IsProfileTest,
        h.Profile_ID as ProfileId,
        h.Profile_Code as ProfileCode,
        NULL as SampleType,
        NULL as Method,
        CAST(ISNULL(COALESCE(b.PartnerDiscountAllowed, b.B2CDiscountAllowed), 0) AS BIT) as IsDiscountAllowed,
        CAST(1 AS BIT) as IsPackage,
        CAST(0 AS BIT) as IsOutsourced,
        CAST(COALESCE(b.PartnerRate, b.B2CRate) AS DECIMAL(18,2)) as B2BRate
    FROM LabInvestigationProfileHeader h
    INNER JOIN @Bookable b ON b.Item_ID = h.Profile_ID AND b.Item_Type = 'Package'
    WHERE h.Status = 1 AND h.IsDeleted = 0
      AND h.Profile_Type = 2 -- 2 = Package
      AND (@DepartmentId IS NULL)
      AND (@CategoryId IS NULL)
      AND (@SubCategoryId IS NULL)
      AND (
          h.Applicable_Gender = 'All'
          OR @Gender IS NULL
          OR h.Applicable_Gender = @Gender
      )
      AND (
          h.Age_Operator IS NULL
          OR h.Age_Operator = '-- No Age Limit --'
          OR @AgeInYears IS NULL
          OR (h.Age_Operator = '=' AND @AgeInYears = h.Applicable_Age)
          OR (h.Age_Operator = '>=' AND @AgeInYears >= h.Applicable_Age)
          OR (h.Age_Operator = '<=' AND @AgeInYears <= h.Applicable_Age)
      )
    ORDER BY TestName;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CreateLabOrder
    @PatientId        INT,
    @BranchId         INT,
    @CreatedBy        INT,
    @TotalAmount      DECIMAL(10,2),
    @Items            dbo.udt_LabOrderItem READONLY,
    @CollectionType   NVARCHAR(50) = 'Lab',
    @PhlebotomistId   INT          = NULL,
    @BookingDate      DATETIME     = NULL,
    @IsB2B            BIT          = 0,
    @B2BAgentID       INT          = NULL,
    @AgentType        VARCHAR(10)  = NULL,
    @B2BTotal         DECIMAL(18,2)= NULL,
    @ReferralDoctorId INT          = NULL,
    @LabOrderId       INT          OUTPUT,
    @BillNo           NVARCHAR(50) OUTPUT,
    @TokenNo          NVARCHAR(50) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Strict validation: Cannot create lab order without at least one valid test investigation
    IF NOT EXISTS (SELECT 1 FROM @Items WHERE ISNULL(InvestigationId, 0) > 0)
    BEGIN
        RAISERROR('Cannot create a laboratory bill without at least one valid test investigation (InvestigationId > 0).', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM @Items WHERE ISNULL(InvestigationId, 0) <= 0)
    BEGIN
        RAISERROR('One or more test items have an invalid Investigation ID (InvestigationId <= 0). Billing cannot proceed.', 16, 1);
        RETURN;
    END

    -- Rate list (script 2199): every item must be on the branch's active rate list - B2C bills the branch B2C list,
    -- B2B bills the partner's list or the branch B2C list - never a test that is only in the master. A B2C item is
    -- billed at its rate-list price.
    DECLARE @RateType VARCHAR(50) = CASE WHEN ISNULL(@IsB2B, 0) = 1
                                         THEN CASE @AgentType WHEN 'F' THEN 'Franchise' WHEN 'C' THEN 'Corporate' ELSE @AgentType END
                                         ELSE 'B2C' END;
    DECLARE @Lines TABLE (InvestigationId INT, ItemType VARCHAR(10), Price DECIMAL(18,2), Code NVARCHAR(100), Name NVARCHAR(300));
    INSERT INTO @Lines (InvestigationId, ItemType, Price, Code, Name)
    SELECT it.InvestigationId,
           CASE WHEN it.[Type] = 'P' THEN 'Package' WHEN ISNULL(i.Is_Profile_Test, 0) = 1 THEN 'Profile' ELSE 'Test' END,
           it.Price,
           COALESCE(CASE WHEN it.[Type] = 'P' THEN h.Profile_Code END, i.Test_Code, CAST(it.InvestigationId AS NVARCHAR(20))),
           COALESCE(CASE WHEN it.[Type] = 'P' THEN h.Profile_Name END, i.Test_Name, N'Item ' + CAST(it.InvestigationId AS NVARCHAR(20)))
    FROM @Items it
    LEFT JOIN dbo.LabInvestigationMaster i ON it.[Type] <> 'P' AND i.Test_ID = it.InvestigationId
    LEFT JOIN dbo.LabInvestigationProfileHeader h ON it.[Type] = 'P' AND h.Profile_ID = it.InvestigationId;

    DECLARE @NotListed NVARCHAR(2000) = (
        SELECT STRING_AGG(CONVERT(NVARCHAR(400), l.Name + N' (' + l.Code + N')'), N', ')
        FROM @Lines l
        WHERE NOT EXISTS (SELECT 1 FROM dbo.fn_LabBookableItems(@BranchId, @RateType, @B2BAgentID) b
                          WHERE b.Item_Type = l.ItemType AND b.Item_ID = l.InvestigationId));
    IF @NotListed IS NOT NULL
    BEGIN
        DECLARE @NotListedMsg NVARCHAR(2048) = LEFT(N'Not on this branch''s rate list, so it cannot be billed: ' + @NotListed
            + N'. Add it to the rate list first, or remove it from the bill and refresh the page.', 2000);
        RAISERROR(@NotListedMsg, 16, 1);
        RETURN;
    END

    IF ISNULL(@IsB2B, 0) = 0
    BEGIN
        DECLARE @Repriced NVARCHAR(2000) = (
            SELECT STRING_AGG(CONVERT(NVARCHAR(400), l.Name + N' (rate list ' + FORMAT(b.B2CRate, 'N2') + N', bill ' + FORMAT(l.Price, 'N2') + N')'), N', ')
            FROM @Lines l
            INNER JOIN dbo.fn_LabBookableItems(@BranchId, 'B2C', NULL) b ON b.Item_Type = l.ItemType AND b.Item_ID = l.InvestigationId
            WHERE ABS(ISNULL(l.Price, 0) - ISNULL(b.B2CRate, 0)) > 0.01);
        IF @Repriced IS NOT NULL
        BEGIN
            DECLARE @RepricedMsg NVARCHAR(2048) = LEFT(N'The rate has changed in the rate list for: ' + @Repriced
                + N'. Refresh the page and add the test again.', 2000);
            RAISERROR(@RepricedMsg, 16, 1);
            RETURN;
        END
    END

    -- Referral doctor = Doctor Master doctor marked Is Referral Doctor, assigned to an active LAB-type department (2127, 2173)
    SET @ReferralDoctorId = NULLIF(@ReferralDoctorId, 0);
    IF @ReferralDoctorId IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM dbo.DoctorMaster d
        INNER JOIN dbo.DoctorDepartmentMap ddm ON ddm.DoctorId = d.DoctorId AND ddm.IsActive = 1
        INNER JOIN dbo.DepartmentMaster dm ON dm.DeptId = ddm.DeptId AND dm.IsActive = 1 AND dm.DeptType = 'LAB'
        WHERE d.DoctorId = @ReferralDoctorId AND d.IsActive = 1 AND d.IsReferralDoctor = 1)
    BEGIN
        RAISERROR('The selected referral doctor is not an active referral doctor of a LAB department.', 16, 1);
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Set effective booking date
        DECLARE @EffectiveDate DATETIME = ISNULL(@BookingDate, GETDATE());

        -- Generate dedicated LAB Bill No
        EXEC dbo.usp_LAB_GetNextBillNo @BranchId = @BranchId, @BillNo = @BillNo OUTPUT;

        -- Generate Token immediately for each B2B billing
        IF ISNULL(@IsB2B, 0) = 1
        BEGIN
            DECLARE @DateOnly DATE = CAST(@EffectiveDate AS DATE);
            EXEC dbo.usp_B2B_LAB_GetNextTokenNo 
                @BranchId  = @BranchId, 
                @TokenDate = @DateOnly, 
                @TokenNo   = @TokenNo OUTPUT;
        END
        ELSE
        BEGIN
            SET @TokenNo = NULL; -- B2C tokens are assigned upon payment
        END

        -- Check if any item is marked urgent
        DECLARE @HasUrgent BIT = 0;
        IF EXISTS (SELECT 1 FROM @Items WHERE IsUrgent = 1)
            SET @HasUrgent = 1;

        -- Insert Header with generated TokenNo
        INSERT INTO dbo.LabOrder 
            (PatientId, BranchId, OrderDate, BillNo, TokenNo, TotalAmount, CollectionType, PhlebotomistId, BookingDate, IsUrgent, CreatedBy, CreatedDate, IsActive, IsB2B, B2BAgentID, AgentType, B2BTotal, RefDoctorId)
        VALUES 
            (@PatientId, @BranchId, @EffectiveDate, @BillNo, @TokenNo, @TotalAmount, ISNULL(@CollectionType, 'Lab'), @PhlebotomistId, @EffectiveDate, @HasUrgent, @CreatedBy, GETDATE(), 1, ISNULL(@IsB2B, 0), @B2BAgentID, @AgentType, @B2BTotal, @ReferralDoctorId);
        
        SET @LabOrderId = SCOPE_IDENTITY();

        -- Insert Items (include Type, IsUrgent, and B2BRate from @Items)
        INSERT INTO dbo.LabOrderItem (LabOrderId, InvestigationId, [Type], Price, IsUrgent, CreatedBy, CreatedDate, IsActive, B2BRate)
        SELECT 
            @LabOrderId, 
            InvestigationId, 
            ISNULL(NULLIF([Type], ''), 'I'), 
            Price, 
            ISNULL(IsUrgent, 0), 
            @CreatedBy, 
            GETDATE(), 
            1,
            B2BRate
        FROM @Items
        WHERE InvestigationId > 0;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
