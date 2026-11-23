-- ============================================================================================================
-- 2412  Pharmacy counter: a walk-in found by mobile (after 2411). Typing a 10-digit mobile on the POS fills the name and
--       address from that buyer's last walk-in bill, and offers the registered patient(s) with that phone.
--       Answers 1 the last walk-in details (with bill count), 2 up to 3 patients with this phone. Re-runnable.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_WalkinByMobile @CompanyId INT, @Mobile NVARCHAR(15)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISNULL(@Mobile, N'') NOT LIKE '[6-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]' SET @Mobile = N'-';
    SELECT TOP 1 s.CustomerName AS Name, s.Address, s.Email, s.SaleDate AS LastBillDate,
           (SELECT COUNT(*) FROM dbo.PhSale x WHERE x.CompanyId = @CompanyId AND x.Mobile = @Mobile AND x.Status = 'POSTED' AND x.CustomerKind = 'WALKIN') AS Bills
      FROM dbo.PhSale s
     WHERE s.CompanyId = @CompanyId AND s.Mobile = @Mobile AND s.CustomerKind = 'WALKIN' AND s.Status = 'POSTED'
       AND NULLIF(LTRIM(RTRIM(s.CustomerName)), N'') IS NOT NULL
     ORDER BY s.SaleId DESC;
    SELECT TOP 3 p.PatientId AS id, p.PatientCode AS uhid, LTRIM(RTRIM(ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS name, p.PhoneNumber AS mobile
      FROM dbo.PatientMaster p
     WHERE p.CompanyId = @CompanyId AND p.IsActive = 1 AND (p.PhoneNumber = @Mobile OR p.SecondaryPhoneNumber = @Mobile)
     ORDER BY p.PatientId DESC;
END
GO
DECLARE @co INT, @page INT, @view INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @page = NULL; SET @view = NULL;
    SELECT @page = Page_ID FROM dbo.PageMaster WHERE Page_Code = 'PHARMACY.POS' AND CompanyId = @co;
    SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    IF @view IS NOT NULL
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhSales', @Action = N'WalkinByMobile', @Source = 'SEED';
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2412 applied: walk-in found by mobile at the counter.';
GO
