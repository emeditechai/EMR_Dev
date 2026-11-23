-- ============================================================================================================
-- Migration: 2517_opd_doctor_commission_services.sql   (application database)
-- OPD > Doctor Commission Configuration: a rule for Services (Revenue Type 'Service'), with the same calculation as
-- the others (Calculation Type, Commission Basis, Doctor Share), on all services or on selected ones. Services =
-- Service Master items of Service Type 'Service' that are not "Is Registration Service".
--   dbo.DoctorCommissionConfigService            : the services a 'Service' rule is limited to (none = all services)
--   usp_Api_DoctorCommissionConfig_SetServices / _GetServices : the rule's selected services
--   usp_Api_DoctorCommissionConfig_ServiceOptions             : the services that can be selected
--   ufn_DoctorPayout_VisitShare (2213): each service line of a visit is shared by its own 'Service' rule (a rule naming
--     the service > all services; doctor > speciality > general; branch > all; latest) on the line's gross or net (its
--     discount and its part of the bill discount); 'Fixed Amount' = per service line. The services' share is added to
--     the visit's FullShare / EarnedShare (accrual, payout board, Doctor Revenue Share report and settlement take it as
--     before - one line per visit). A visit whose rule is 'All Services' is unchanged (the whole bill is shared already).
--     Visits without a 'Service' rule are unchanged. New columns: ConsultFullShare, ServiceGross, ServiceFullShare, ServiceConfigId.
-- Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
IF OBJECT_ID(N'dbo.DoctorCommissionConfigService', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.DoctorCommissionConfigService
    (
        CommissionConfigId INT NOT NULL CONSTRAINT FK_DoctorCommissionConfigService_Config REFERENCES dbo.DoctorCommissionConfig (CommissionConfigId) ON DELETE CASCADE,
        ServiceId          INT NOT NULL CONSTRAINT FK_DoctorCommissionConfigService_Service REFERENCES dbo.ServiceMaster (ServiceId),
        CONSTRAINT PK_DoctorCommissionConfigService PRIMARY KEY (CommissionConfigId, ServiceId)
    );
    CREATE INDEX IX_DoctorCommissionConfigService_Service ON dbo.DoctorCommissionConfigService (ServiceId);
END
GO

-- the rule's selected services (JSON array of ServiceMaster.ServiceId; empty / NULL = all services)
CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorCommissionConfig_SetServices
    @CommissionConfigId INT,
    @ServiceIds NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @ids TABLE (Id INT PRIMARY KEY);
    -- only for a 'Service' rule, and only real services (Service Type 'Service', not registration)
    IF EXISTS (SELECT 1 FROM dbo.DoctorCommissionConfig WHERE CommissionConfigId = @CommissionConfigId AND RevenueType = 'Service')
       AND ISJSON(@ServiceIds) = 1
        INSERT @ids SELECT DISTINCT sm.ServiceId
          FROM OPENJSON(@ServiceIds) j
          JOIN dbo.ServiceMaster sm ON sm.ServiceId = TRY_CAST(j.value AS INT) AND sm.ServiceType = 'Service' AND ISNULL(sm.IsRegistration, 0) = 0;
    BEGIN TRANSACTION;
    DELETE dbo.DoctorCommissionConfigService WHERE CommissionConfigId = @CommissionConfigId AND ServiceId NOT IN (SELECT Id FROM @ids);
    INSERT dbo.DoctorCommissionConfigService (CommissionConfigId, ServiceId)
    SELECT @CommissionConfigId, i.Id FROM @ids i
     WHERE NOT EXISTS (SELECT 1 FROM dbo.DoctorCommissionConfigService x WHERE x.CommissionConfigId = @CommissionConfigId AND x.ServiceId = i.Id);
    COMMIT;
    SELECT COUNT(*) AS Services FROM dbo.DoctorCommissionConfigService WHERE CommissionConfigId = @CommissionConfigId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorCommissionConfig_GetServices
    @CommissionConfigId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT x.ServiceId, sm.ItemCode, sm.ItemName
      FROM dbo.DoctorCommissionConfigService x
      JOIN dbo.ServiceMaster sm ON sm.ServiceId = x.ServiceId
     WHERE x.CommissionConfigId = @CommissionConfigId
     ORDER BY sm.ItemName;
END
GO

-- the services a 'Service' rule can name: Service Type 'Service', not a registration service, of the company / branch
CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorCommissionConfig_ServiceOptions
    @CompanyId INT,
    @BranchId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT sm.ServiceId, sm.ItemCode, sm.ItemName, sm.ItemCharges, sm.IsActive
      FROM dbo.ServiceMaster sm
     WHERE sm.ServiceType = 'Service' AND ISNULL(sm.IsRegistration, 0) = 0
       AND (sm.CompanyId IS NULL OR sm.CompanyId = @CompanyId)
       AND (@BranchId IS NULL OR sm.BranchId IS NULL OR sm.BranchId = @BranchId)
     ORDER BY sm.IsActive DESC, sm.ItemName;
END
GO

-- ── 2. the share of each visit, as of now ──────────────────────────────────
-- Visits of the branch billed, paid, refunded or cancelled in the range. EarnedShare = the share earned so far
-- (in proportion to what is collected); FullShare = the share once the bill is fully paid.
CREATE OR ALTER FUNCTION dbo.ufn_DoctorPayout_VisitShare (@BranchId INT, @FromDate DATE, @ToDate DATE, @DoctorId INT)
RETURNS TABLE
AS RETURN
WITH v AS (
    SELECT s.OPDServiceId AS VisitId, s.BranchId, s.CompanyId, s.ConsultingDoctorId AS DoctorId, d.PrimarySpecialityId AS SpecialityId,
           s.PatientId, s.CreatedDate AS BillDate, CAST(s.IsActive AS BIT) AS VisitActive, ph.PaymentHeaderId AS BillId,
           CAST(ISNULL(ph.SubTotal, s.TotalAmount) AS DECIMAL(18, 2)) AS BillGross,
           CAST(ISNULL(ph.NetAmount, s.TotalAmount) AS DECIMAL(18, 2)) AS BillNet,
           CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS BillPaid,
           CAST(ISNULL(ph.HeaderDiscountAmount, 0) AS DECIMAL(18, 2)) AS HeaderDisc,
           CAST(COALESCE(NULLIF(pl.g, 0), ps.g, 0) AS DECIMAL(18, 2)) AS ConsultGross,
           CAST(CASE WHEN ISNULL(pl.g, 0) > 0 THEN ISNULL(pl.ld, 0) ELSE 0 END AS DECIMAL(18, 2)) AS ConsultLineDisc,
           act.ActivityOn
    FROM dbo.PatientOPDService s
    INNER JOIN dbo.DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = s.OPDServiceId AND ph.IsActive = 1
    -- consulting lines of the bill whose service is still active (a cancelled line keeps its bill line)
    OUTER APPLY (SELECT SUM(pli.OriginalAmount) AS g, SUM(ISNULL(pli.LineDiscountAmount, 0)) AS ld
                   FROM dbo.PaymentLineItem pli
                   LEFT JOIN dbo.PatientOPDServiceItem si ON si.ItemId = pli.ModuleLineRefId AND si.OPDServiceId = s.OPDServiceId
                  WHERE pli.PaymentHeaderId = ph.PaymentHeaderId AND pli.IsActive = 1 AND pli.ServiceType = 'Consulting'
                    AND ISNULL(si.IsActive, 1) = 1) pl
    OUTER APPLY (SELECT SUM(si.ServiceCharges) AS g FROM dbo.PatientOPDServiceItem si
                  WHERE si.OPDServiceId = s.OPDServiceId AND si.IsActive = 1 AND si.ServiceType = 'Consulting') ps
    OUTER APPLY (SELECT MAX(x.d) AS ActivityOn
                   FROM (VALUES (CAST(s.CreatedDate AS DATETIME)),
                                ((SELECT MAX(COALESCE(pd.PaymentDate, pd.CreatedDate)) FROM dbo.PaymentDetail pd WHERE pd.PaymentHeaderId = ph.PaymentHeaderId AND pd.IsActive = 1)),
                                ((SELECT MAX(r.RefundDate) FROM dbo.BillRefund r WHERE r.ModuleCode = 'OPD' AND r.ModuleRefId = s.OPDServiceId AND r.IsActive = 1)),
                                ((SELECT MAX(bc.CancellationDate) FROM dbo.BillCancellation bc WHERE bc.ModuleCode = 'OPD' AND bc.ModuleRefId = s.OPDServiceId AND bc.IsActive = 1))) x(d)) act
    WHERE s.BranchId = @BranchId AND s.ConsultingDoctorId IS NOT NULL
      AND (@DoctorId IS NULL OR s.ConsultingDoctorId = @DoctorId)
      AND ((s.CreatedDate >= @FromDate AND s.CreatedDate < DATEADD(DAY, 1, CAST(@ToDate AS DATETIME)))
           OR (act.ActivityOn >= @FromDate AND act.ActivityOn < DATEADD(DAY, 1, CAST(@ToDate AS DATETIME))))
),
-- 2517: the visit's services (Service Type = Service, not a registration service) and each one's share, by its own rule
-- (Revenue Type 'Service': the rule's selected services, or all services when none is selected)
sv AS (
    SELECT v.VisitId,
           CAST(SUM(l.Gross) AS DECIMAL(18, 2)) AS ServiceGross,
           CAST(SUM(l.Net) AS DECIMAL(18, 2)) AS ServiceNet,
           CAST(SUM(CASE WHEN sr.CommissionConfigId IS NULL THEN 0
                         WHEN sr.CalculationType = 'Fixed Amount' THEN sr.DoctorShare
                         ELSE ROUND(CASE WHEN sr.CommissionBasis = 'Gross Bill' THEN l.Gross ELSE l.Net END * sr.DoctorShare / 100.0, 2) END) AS DECIMAL(18, 2)) AS ServiceShare,
           CAST(SUM(CASE WHEN sr.CommissionConfigId IS NULL THEN 0 ELSE l.Gross END) AS DECIMAL(18, 2)) AS ServiceRuleGross,
           CAST(SUM(CASE WHEN sr.CommissionConfigId IS NULL THEN 0 ELSE l.Net END) AS DECIMAL(18, 2)) AS ServiceRuleNet,
           MIN(sr.CommissionConfigId) AS ServiceConfigId,
           COUNT(sr.CommissionConfigId) AS ServiceLinesWithRule
    FROM v
    INNER JOIN dbo.PatientOPDServiceItem si ON si.OPDServiceId = v.VisitId AND si.IsActive = 1 AND si.ServiceType = 'Service'
    INNER JOIN dbo.ServiceMaster sm ON sm.ServiceId = si.ServiceId AND ISNULL(sm.IsRegistration, 0) = 0
    OUTER APPLY (SELECT TOP 1 pli.OriginalAmount, pli.LineDiscountAmount FROM dbo.PaymentLineItem pli
                  WHERE pli.PaymentHeaderId = v.BillId AND pli.IsActive = 1 AND pli.ServiceType = 'Service' AND pli.ModuleLineRefId = si.ItemId) pl
    CROSS APPLY (SELECT CAST(ISNULL(pl.OriginalAmount, si.ServiceCharges) AS DECIMAL(18, 2)) AS Gross) g
    -- the line's discount: its own, plus its part of the bill (header) discount
    CROSS APPLY (SELECT CAST(ISNULL(pl.LineDiscountAmount, 0) + CASE WHEN v.BillGross > 0 THEN ROUND(v.HeaderDisc * g.Gross / v.BillGross, 2) ELSE 0 END AS DECIMAL(18, 2)) AS Disc) d
    CROSS APPLY (SELECT g.Gross, CAST(CASE WHEN d.Disc > g.Gross THEN 0 ELSE g.Gross - d.Disc END AS DECIMAL(18, 2)) AS Net) l
    OUTER APPLY (SELECT TOP 1 c.CommissionConfigId, c.CalculationType, c.CommissionBasis, c.DoctorShare
                   FROM dbo.DoctorCommissionConfig c
                  WHERE c.IsActive = 1 AND c.RevenueType = 'Service' AND (v.CompanyId IS NULL OR c.CompanyId = v.CompanyId)
                    AND (ISNULL(c.BranchId, 0) = 0 OR c.BranchId = v.BranchId)
                    AND (c.DoctorId = v.DoctorId
                         OR (ISNULL(c.DoctorId, 0) = 0 AND c.SpecialityId = v.SpecialityId)
                         OR (ISNULL(c.DoctorId, 0) = 0 AND ISNULL(c.SpecialityId, 0) = 0))
                    AND c.EffectiveFrom <= CAST(v.BillDate AS DATE) AND (c.EffectiveTo IS NULL OR c.EffectiveTo >= CAST(v.BillDate AS DATE))
                    AND (NOT EXISTS (SELECT 1 FROM dbo.DoctorCommissionConfigService x WHERE x.CommissionConfigId = c.CommissionConfigId)
                         OR EXISTS (SELECT 1 FROM dbo.DoctorCommissionConfigService x WHERE x.CommissionConfigId = c.CommissionConfigId AND x.ServiceId = si.ServiceId))
                  -- a rule naming this service > one for all services; then doctor > speciality > general, branch > all, latest
                  ORDER BY CASE WHEN EXISTS (SELECT 1 FROM dbo.DoctorCommissionConfigService x WHERE x.CommissionConfigId = c.CommissionConfigId) THEN 0 ELSE 1 END,
                           CASE WHEN c.DoctorId = v.DoctorId THEN 1 WHEN ISNULL(c.SpecialityId, 0) <> 0 THEN 2 ELSE 3 END,
                           CASE WHEN ISNULL(c.BranchId, 0) = 0 THEN 1 ELSE 0 END, c.EffectiveFrom DESC, c.CommissionConfigId DESC) sr
    GROUP BY v.VisitId
)
SELECT v.VisitId, v.BranchId, v.CompanyId, v.DoctorId, v.SpecialityId, v.PatientId, v.BillDate, v.VisitActive, v.BillId,
       v.BillGross, v.BillNet, v.BillPaid, v.ConsultGross, a.ConsultDisc, v.ActivityOn,
       ISNULL(r.CommissionConfigId, s2.ServiceConfigId) AS CommissionConfigId,
       CASE WHEN r.CommissionConfigId IS NULL AND s2.ServiceConfigId IS NOT NULL THEN 'Service' ELSE r.RevenueType END AS RevenueType,
       CASE WHEN r.CommissionConfigId IS NULL AND s2.ServiceConfigId IS NOT NULL THEN sc.CalculationType ELSE r.CalculationType END AS CalculationType,
       CASE WHEN r.CommissionConfigId IS NULL AND s2.ServiceConfigId IS NOT NULL THEN sc.CommissionBasis ELSE r.CommissionBasis END AS CommissionBasis,
       CASE WHEN r.CommissionConfigId IS NULL AND s2.ServiceConfigId IS NOT NULL THEN sc.DoctorShare ELSE r.DoctorShare END AS DoctorShare,
       CAST(b.BaseGross + s2.RuleGross AS DECIMAL(18, 2)) AS BaseGross, CAST(b.BaseNet + s2.RuleNet AS DECIMAL(18, 2)) AS BaseNet, k.Ratio,
       CAST(ROUND((b.BaseNet + s2.RuleNet) * k.Ratio, 2) AS DECIMAL(18, 2)) AS CollectedBase,
       CAST(f.FullShare + s2.Share AS DECIMAL(18, 2)) AS FullShare,
       CAST(ROUND((f.FullShare + s2.Share) * k.Ratio, 2) AS DECIMAL(18, 2)) AS EarnedShare,
       CAST(CASE WHEN r.CommissionConfigId IS NULL AND s2.ServiceConfigId IS NULL THEN 'No commission rule'
                 WHEN r.CommissionConfigId IS NULL THEN N'Services: ₹' + FORMAT(s2.Share, '0.##') + ' (' + CAST(s2.Lines AS VARCHAR(5)) + ' service line(s))'
                 ELSE CASE WHEN r.CalculationType = 'Fixed Amount' THEN N'Flat ₹' + FORMAT(r.DoctorShare, '0.##') + ' per visit (' + r.RevenueType + ')'
                           ELSE FORMAT(r.DoctorShare, '0.##') + '% of ' + r.CommissionBasis + ' (' + r.RevenueType + ')' END
                      + CASE WHEN s2.ServiceConfigId IS NOT NULL THEN N' + services ₹' + FORMAT(s2.Share, '0.##') ELSE N'' END END AS NVARCHAR(300)) AS RuleText,
       -- 2517: the services' part (0 under an 'All Services' rule, which already covers the whole bill)
       CAST(f.FullShare AS DECIMAL(18, 2)) AS ConsultFullShare,
       s2.Gross AS ServiceGross, s2.Share AS ServiceFullShare, s2.ServiceConfigId
FROM v
LEFT JOIN sv ON sv.VisitId = v.VisitId
-- the consulting lines' share of the bill (header) discount
CROSS APPLY (SELECT CAST(CASE WHEN v.ConsultGross <= 0 THEN 0
                              WHEN v.ConsultLineDisc + CASE WHEN v.BillGross > 0 THEN ROUND(v.HeaderDisc * v.ConsultGross / v.BillGross, 2) ELSE 0 END > v.ConsultGross THEN v.ConsultGross
                              ELSE v.ConsultLineDisc + CASE WHEN v.BillGross > 0 THEN ROUND(v.HeaderDisc * v.ConsultGross / v.BillGross, 2) ELSE 0 END END AS DECIMAL(18, 2)) AS ConsultDisc) a
-- the rule in force on the bill date: doctor > speciality > general, branch > all branches, latest first
OUTER APPLY (SELECT TOP 1 c.CommissionConfigId, ISNULL(c.RevenueType, 'Consultation') AS RevenueType, c.CalculationType, c.CommissionBasis, c.DoctorShare
               FROM dbo.DoctorCommissionConfig c
              WHERE c.IsActive = 1 AND (v.CompanyId IS NULL OR c.CompanyId = v.CompanyId)
                AND (ISNULL(c.BranchId, 0) = 0 OR c.BranchId = v.BranchId)
                AND (c.DoctorId = v.DoctorId
                     OR (ISNULL(c.DoctorId, 0) = 0 AND c.SpecialityId = v.SpecialityId)
                     OR (ISNULL(c.DoctorId, 0) = 0 AND ISNULL(c.SpecialityId, 0) = 0))
                AND (c.RevenueType IS NULL OR c.RevenueType IN ('Consultation', 'Consultant', 'All Services'))
                AND c.EffectiveFrom <= CAST(v.BillDate AS DATE) AND (c.EffectiveTo IS NULL OR c.EffectiveTo >= CAST(v.BillDate AS DATE))
              ORDER BY CASE WHEN c.DoctorId = v.DoctorId THEN 1 WHEN ISNULL(c.SpecialityId, 0) <> 0 THEN 2 ELSE 3 END,
                       CASE WHEN ISNULL(c.BranchId, 0) = 0 THEN 1 ELSE 0 END, c.EffectiveFrom DESC, c.CommissionConfigId DESC) r
-- 2517: the services' share counts unless the visit's rule is 'All Services' (that one is on the whole bill already)
CROSS APPLY (SELECT CAST(CASE WHEN r.RevenueType = 'All Services' THEN 0 ELSE ISNULL(sv.ServiceShare, 0) END AS DECIMAL(18, 2)) AS Share,
                    CAST(CASE WHEN r.RevenueType = 'All Services' THEN 0 ELSE ISNULL(sv.ServiceRuleGross, 0) END AS DECIMAL(18, 2)) AS RuleGross,
                    CAST(CASE WHEN r.RevenueType = 'All Services' THEN 0 ELSE ISNULL(sv.ServiceRuleNet, 0) END AS DECIMAL(18, 2)) AS RuleNet,
                    CAST(ISNULL(sv.ServiceGross, 0) AS DECIMAL(18, 2)) AS Gross,
                    CASE WHEN r.RevenueType = 'All Services' THEN NULL ELSE sv.ServiceConfigId END AS ServiceConfigId,
                    CASE WHEN r.RevenueType = 'All Services' THEN 0 ELSE ISNULL(sv.ServiceLinesWithRule, 0) END AS Lines) s2
OUTER APPLY (SELECT c.CalculationType, c.CommissionBasis, c.DoctorShare FROM dbo.DoctorCommissionConfig c WHERE c.CommissionConfigId = s2.ServiceConfigId) sc
CROSS APPLY (SELECT CAST(CASE WHEN r.RevenueType = 'All Services' THEN v.BillGross ELSE v.ConsultGross END AS DECIMAL(18, 2)) AS BaseGross,
                    CAST(CASE WHEN r.RevenueType = 'All Services' THEN v.BillNet ELSE v.ConsultGross - a.ConsultDisc END AS DECIMAL(18, 2)) AS BaseNet) b
-- how much of the bill is collected (refunds already reduce TotalPaid); a cancelled visit earns nothing
CROSS APPLY (SELECT CAST(CASE WHEN v.VisitActive = 0 THEN 0 WHEN v.BillNet <= 0 THEN 1
                              WHEN v.BillPaid >= v.BillNet THEN 1 WHEN v.BillPaid <= 0 THEN 0
                              ELSE v.BillPaid / v.BillNet END AS DECIMAL(9, 6)) AS Ratio) k
CROSS APPLY (SELECT CAST(CASE WHEN r.CommissionConfigId IS NULL OR b.BaseGross <= 0 THEN 0
                              WHEN r.CalculationType = 'Fixed Amount' THEN r.DoctorShare
                              ELSE ROUND(CASE WHEN r.CommissionBasis = 'Gross Bill' THEN b.BaseGross ELSE b.BaseNet END * r.DoctorShare / 100.0, 2) END
                         AS DECIMAL(18, 2)) AS FullShare) f;
GO

-- the new API endpoint (api/doctor-commission-configs/service-options), catalogued like the controller's other ones
IF NOT EXISTS (SELECT 1 FROM dbo.PageEndpointMap WHERE App = 'API' AND Controller = N'DoctorCommissionConfigs' AND Action = N'ServiceOptions')
    INSERT dbo.PageEndpointMap (Page_ID, Control_ID, App, Http_Method, Controller, Action, Route, IsActive, CreatedDate, Source, Discovered_On, Last_Seen_On, Is_Orphaned, Is_Public)
    SELECT TOP 1 Page_ID, Control_ID, App, 'GET', Controller, N'ServiceOptions', N'api/doctor-commission-configs/service-options', IsActive, GETDATE(), Source,
           GETDATE(), GETDATE(), 0, Is_Public
      FROM dbo.PageEndpointMap WHERE App = 'API' AND Controller = N'DoctorCommissionConfigs' AND Action = N'GetList';
GO
PRINT 'Script 2517 applied: OPD Doctor Commission - Service rules.';
GO
