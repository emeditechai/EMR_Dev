-- ============================================================================
-- Migration: 2256_lab_b2b_partner_rate_list_only.sql
-- Description: B2B billing offers and bills only the items on THAT partner's own rate list (active and in date):
--     Franchise   LabRateCardMaster Rate_Type = 'Franchise', B2CIdentity_ID = the franchise, Branch_ID = the branch;
--     Corporate   Rate_Type = 'Corporate', B2CIdentity_ID = the company, Branch_ID = the branch, or else the
--                 company-wide list (Branch_ID NULL) - as the rate list is set up.
--   Before (2199) an item missing from the partner's list fell back to the branch's B2C rate list, so a franchise or
--   company with no rate list saw - and could bill - every B2C test at the B2C price.
--   One change in dbo.fn_LabBookableItems, so both sides follow it:
--     * usp_GetAvailableInvestigations (the B2B booking test search) lists only the partner's items;
--     * usp_CreateLabOrder refuses a B2B bill with an item not on the partner's rate list.
--   B2C billing is unchanged. The B2C rate is still returned (for the struck-through MRP).
--   Run after 2255.
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
        -- B2B (Franchise / Corporate) bills only what is on the partner's own rate list (2256); B2C uses the branch's B2C list
        SELECT Item_Type, Item_ID FROM b2c WHERE rn = 1 AND ISNULL(@RateType, 'B2C') = 'B2C'
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

PRINT 'Script 2256 applied: B2B billing (Franchise / Corporate) uses only the partner''s own rate list.';
GO
