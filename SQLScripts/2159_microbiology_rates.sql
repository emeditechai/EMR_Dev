-- =============================================
-- Script : 2159_microbiology_rates.sql
-- Purpose: Prices for the microbiology tests.
--          1. MRP for the 5 descriptive stains (seeded at 0).
--          2. Every microbiology test / profile added to every active rate
--             card at MRP, so it shows in the Rate List screens and each
--             card can be adjusted from there.
-- Notes  : Booking already falls back to MRP when a test is not on a card;
--          adding rows at MRP does not change today's charged price.
--          Stain MRPs are starter values - adjust per client.
-- =============================================

-- 1. Stain MRPs
DECLARE @Mrp TABLE (Code NVARCHAR(50), Mrp DECIMAL(10,2));
INSERT INTO @Mrp VALUES
 ('MIC-ST-001', 150),  -- Gram Stain
 ('MIC-ST-002', 150),  -- KOH Mount
 ('MIC-ST-003', 150),  -- Wet Mount
 ('MIC-ST-004', 250),  -- India Ink (CSF)
 ('MIC-ST-005', 200);  -- Albert Stain

UPDATE i SET MRP = m.Mrp, ModifiedDate = GETDATE()
FROM dbo.LabInvestigationMaster i
JOIN @Mrp m ON m.Code = i.Test_Code
WHERE i.IsDeleted = 0 AND ISNULL(i.MRP, 0) = 0;
GO

-- 2. Rate card entries (Profile rows are keyed by the profile test's Test_ID, as existing entries are)
;WITH MicroItems AS (
    SELECT i.Test_ID,
           CASE WHEN i.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END AS Item_Type,
           CASE WHEN i.Is_Profile_Test = 1 THEN ISNULL(h.MRP, i.MRP) ELSE i.MRP END AS Rate
    FROM dbo.LabInvestigationMaster i
    LEFT JOIN dbo.LabInvestigationProfileHeader h ON h.Test_ID = i.Test_ID AND h.IsDeleted = 0
    WHERE i.IsDeleted = 0 AND i.Status = 1 AND i.Is_Billable = 1
      AND (i.Test_Code LIKE 'MIC-%' OR (i.Test_Code LIKE 'CP-%' AND i.Is_Profile_Test = 1))
)
INSERT INTO dbo.LabRateCardDetail (RateCard_ID, Item_Type, Item_ID, Rate, Status, IsDeleted, CreatedDate, Is_Discount_Allowed)
SELECT c.RateCard_ID, mi.Item_Type, mi.Test_ID, mi.Rate, 1, 0, GETDATE(), 1
FROM dbo.LabRateCardMaster c
CROSS JOIN MicroItems mi
WHERE c.IsDeleted = 0 AND c.Status = 1
  AND ISNULL(mi.Rate, 0) > 0
  AND NOT EXISTS (SELECT 1 FROM dbo.LabRateCardDetail d
                  WHERE d.RateCard_ID = c.RateCard_ID AND d.Item_ID = mi.Test_ID AND d.Item_Type = mi.Item_Type AND d.IsDeleted = 0);
GO

PRINT 'Microbiology rates updated.';
