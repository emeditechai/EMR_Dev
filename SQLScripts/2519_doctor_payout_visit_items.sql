-- ============================================================================================================
-- Migration: 2519_doctor_payout_visit_items.sql   (application database; needs 2517)
-- OPD > Doctor Commission & Disbursals: the item-wise breakdown of one bill's doctor share (optional, opened from a
-- share line) - each consultation / service / registration line with its amount, discount, net, the rule that applies
-- and its share. The totals come from ufn_DoctorPayout_VisitShare, so the items add up to the share on the board:
--   Consultation lines : the consultation share, split over the consulting lines by their net
--   Service lines      : each by its own 'Service' rule (as the visit share does)
--   Registration lines : not shared
--   'All Services' rule: the whole bill's share, split over every line by its net
-- Earned = share x the part of the bill collected.
--   usp_DoctorPayout_VisitItems : result 1 the bill (totals), result 2 the items
-- Endpoints: DoctorDisbursal/VisitItemsData (WEB, the Doctor Disbursal page), api/doctor-payouts/visit-items (API).
-- Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_DoctorPayout_VisitItems
    @BranchId INT,
    @VisitId  INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @d DATE, @doc INT;
    SELECT @d = CAST(s.CreatedDate AS DATE), @doc = s.ConsultingDoctorId
      FROM dbo.PatientOPDService s WHERE s.OPDServiceId = @VisitId AND s.BranchId = @BranchId;

    SELECT * INTO #V FROM dbo.ufn_DoctorPayout_VisitShare(@BranchId, ISNULL(@d, '19000101'), ISNULL(@d, '19000101'), @doc) WHERE VisitId = @VisitId;

    DECLARE @allSvc BIT = CASE WHEN EXISTS (SELECT 1 FROM #V WHERE RevenueType = 'All Services') THEN 1 ELSE 0 END;
    DECLARE @consultRule INT = (SELECT CommissionConfigId FROM #V WHERE RevenueType NOT IN ('Service') AND CommissionConfigId IS NOT NULL);
    DECLARE @headerDisc DECIMAL(18, 2) = ISNULL((SELECT ph.HeaderDiscountAmount FROM dbo.PaymentHeader ph
                                                 WHERE ph.ModuleCode = 'OPD' AND ph.ModuleRefId = @VisitId AND ph.IsActive = 1), 0);

    -- 1. the bill
    SELECT v.VisitId, s.OPDBillNo AS BillNo, s.TokenNo, v.BillDate, v.BillGross, v.BillNet, v.BillPaid, v.Ratio,
           v.ConsultFullShare, v.ServiceFullShare, v.FullShare, v.EarnedShare, v.RuleText
      FROM #V v LEFT JOIN dbo.PatientOPDService s ON s.OPDServiceId = v.VisitId;

    -- 2. the items
    WITH it AS (
        SELECT si.ItemId, si.ServiceType, si.ServiceId, sm.ItemName, sm.ItemCode, ISNULL(sm.IsRegistration, 0) AS IsReg,
               CAST(ISNULL(pl.OriginalAmount, si.ServiceCharges) AS DECIMAL(18, 2)) AS Gross,
               CAST(ISNULL(pl.LineDiscountAmount, 0) AS DECIMAL(18, 2)) AS LineDisc
          FROM dbo.PatientOPDServiceItem si
          LEFT JOIN dbo.ServiceMaster sm ON sm.ServiceId = si.ServiceId
          OUTER APPLY (SELECT TOP 1 p.OriginalAmount, p.LineDiscountAmount FROM dbo.PaymentLineItem p
                         JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = p.PaymentHeaderId AND ph.ModuleCode = 'OPD' AND ph.ModuleRefId = si.OPDServiceId AND ph.IsActive = 1
                        WHERE p.IsActive = 1 AND p.ModuleLineRefId = si.ItemId AND p.ServiceType = si.ServiceType) pl
         WHERE si.OPDServiceId = @VisitId AND si.IsActive = 1
    ), n AS (
        SELECT it.*, CAST(CASE WHEN it.LineDisc + CASE WHEN v.BillGross > 0 THEN ROUND(@headerDisc * it.Gross / v.BillGross, 2) ELSE 0 END > it.Gross THEN it.Gross
                               ELSE it.LineDisc + CASE WHEN v.BillGross > 0 THEN ROUND(@headerDisc * it.Gross / v.BillGross, 2) ELSE 0 END END AS DECIMAL(18, 2)) AS Disc,
               v.ConsultFullShare, v.FullShare, v.Ratio, v.BillDate, v.BranchId, v.CompanyId, v.DoctorId, v.SpecialityId
          FROM it CROSS JOIN #V v
    ), r AS (
        SELECT n.*, CAST(n.Gross - n.Disc AS DECIMAL(18, 2)) AS Net,
               CASE WHEN @allSvc = 1 THEN 'ALL' WHEN n.ServiceType = 'Consulting' THEN 'CONSULT' WHEN n.IsReg = 1 THEN 'REG' ELSE 'SERVICE' END AS Kind
          FROM n
    )
    SELECT r.ItemId,
           CASE r.Kind WHEN 'CONSULT' THEN 'Consultation' WHEN 'REG' THEN 'Registration' WHEN 'SERVICE' THEN 'Service'
                       ELSE CASE WHEN r.ServiceType = 'Consulting' THEN 'Consultation' WHEN r.IsReg = 1 THEN 'Registration' ELSE 'Service' END END AS ItemType,
           ISNULL(r.ItemName, r.ServiceType) AS ItemName, r.ItemCode, r.Gross, r.Disc AS Discount, r.Net,
           CASE r.Kind
                WHEN 'REG'     THEN N'Not shared (registration)'
                WHEN 'CONSULT' THEN ISNULL(dbo.ufn_DoctorCommission_LineText(@consultRule), N'No consultation rule')
                WHEN 'ALL'     THEN ISNULL(dbo.ufn_DoctorCommission_LineText(@consultRule), N'All Services')
                ELSE ISNULL(dbo.ufn_DoctorCommission_LineText(sr.CommissionConfigId), N'No service rule') END AS RuleText,
           x.Share, CAST(ROUND(x.Share * r.Ratio, 2) AS DECIMAL(18, 2)) AS Earned
      FROM r
      -- the service line's own rule (the same choice as ufn_DoctorPayout_VisitShare)
      OUTER APPLY (SELECT TOP 1 c.CommissionConfigId, c.CalculationType, c.CommissionBasis, c.DoctorShare
                     FROM dbo.DoctorCommissionConfig c
                    WHERE r.Kind = 'SERVICE' AND c.IsActive = 1 AND c.RevenueType = 'Service' AND (r.CompanyId IS NULL OR c.CompanyId = r.CompanyId)
                      AND (ISNULL(c.BranchId, 0) = 0 OR c.BranchId = r.BranchId)
                      AND (c.DoctorId = r.DoctorId OR (ISNULL(c.DoctorId, 0) = 0 AND c.SpecialityId = r.SpecialityId) OR (ISNULL(c.DoctorId, 0) = 0 AND ISNULL(c.SpecialityId, 0) = 0))
                      AND c.EffectiveFrom <= CAST(r.BillDate AS DATE) AND (c.EffectiveTo IS NULL OR c.EffectiveTo >= CAST(r.BillDate AS DATE))
                      AND (NOT EXISTS (SELECT 1 FROM dbo.DoctorCommissionConfigService x WHERE x.CommissionConfigId = c.CommissionConfigId)
                           OR EXISTS (SELECT 1 FROM dbo.DoctorCommissionConfigService x WHERE x.CommissionConfigId = c.CommissionConfigId AND x.ServiceId = r.ServiceId))
                    ORDER BY CASE WHEN EXISTS (SELECT 1 FROM dbo.DoctorCommissionConfigService x WHERE x.CommissionConfigId = c.CommissionConfigId) THEN 0 ELSE 1 END,
                             CASE WHEN c.DoctorId = r.DoctorId THEN 1 WHEN ISNULL(c.SpecialityId, 0) <> 0 THEN 2 ELSE 3 END,
                             CASE WHEN ISNULL(c.BranchId, 0) = 0 THEN 1 ELSE 0 END, c.EffectiveFrom DESC, c.CommissionConfigId DESC) sr
      -- the consultation / whole-bill share split by net over its lines
      OUTER APPLY (SELECT SUM(q.Net) AS ConsultNet, (SELECT SUM(z.Net) FROM r z) AS AllNet FROM r q WHERE q.Kind = 'CONSULT') t
      CROSS APPLY (SELECT CAST(CASE r.Kind
                       WHEN 'REG' THEN 0
                       WHEN 'CONSULT' THEN CASE WHEN ISNULL(t.ConsultNet, 0) > 0 THEN ROUND(r.ConsultFullShare * r.Net / t.ConsultNet, 2) ELSE 0 END
                       WHEN 'ALL' THEN CASE WHEN ISNULL(t.AllNet, 0) > 0 THEN ROUND(r.FullShare * r.Net / t.AllNet, 2) ELSE 0 END
                       ELSE CASE WHEN sr.CommissionConfigId IS NULL THEN 0
                                 WHEN sr.CalculationType = 'Fixed Amount' THEN sr.DoctorShare
                                 ELSE ROUND(CASE WHEN sr.CommissionBasis = 'Gross Bill' THEN r.Gross ELSE r.Net END * sr.DoctorShare / 100.0, 2) END
                       END AS DECIMAL(18, 2)) AS Share) x
     ORDER BY CASE r.Kind WHEN 'CONSULT' THEN 0 WHEN 'SERVICE' THEN 1 WHEN 'ALL' THEN 1 ELSE 2 END, r.ItemId;
END
GO

-- endpoints: the page's data call (WEB, Doctor Disbursal page) and the API action, mapped like their neighbours
DECLARE @wp INT, @wc INT;
SELECT TOP 1 @wp = Page_ID, @wc = Control_ID FROM dbo.PageEndpointMap WHERE App = 'WEB' AND Controller = N'DoctorDisbursal' AND Action = N'BoardData';
IF @wp IS NOT NULL
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @wp, @Control_ID = @wc, @App = 'WEB', @Http_Method = 'GET',
         @Controller = N'DoctorDisbursal', @Action = N'VisitItemsData', @Source = 'SEED';
IF NOT EXISTS (SELECT 1 FROM dbo.PageEndpointMap WHERE App = 'API' AND Controller = N'DoctorPayouts' AND Action = N'VisitItems')
    INSERT dbo.PageEndpointMap (Page_ID, Control_ID, App, Http_Method, Controller, Action, Route, IsActive, CreatedDate, Source, Discovered_On, Last_Seen_On, Is_Orphaned, Is_Public)
    SELECT TOP 1 Page_ID, Control_ID, 'API', 'GET', N'DoctorPayouts', N'VisitItems', N'api/doctor-payouts/visit-items', IsActive, GETDATE(), Source, GETDATE(), GETDATE(), 0, Is_Public
      FROM dbo.PageEndpointMap WHERE App = 'API' AND Controller = N'DoctorPayouts' AND Action = N'Board';
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2519 applied: Doctor payout - item-wise breakdown of a bill.';
GO
