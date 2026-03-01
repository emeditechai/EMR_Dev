-- =============================================================================
-- Script : 15_west_bengal_geography.sql
-- Purpose: Add complete city and area data for all West Bengal districts.
--          Safe to re-run (uses IF NOT EXISTS guards).
-- =============================================================================

DECLARE @WB INT = (SELECT StateId FROM StateMaster WHERE StateCode = 'WB');

-- ─── Ensure Districts exist ───────────────────────────────────────────────────

IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'KOL')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('KOL', 'Kolkata', @WB, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'DRJ')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('DRJ', 'Darjeeling', @WB, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'HWH')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('HWH', 'Howrah', @WB, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'HGL')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('HGL', 'Hooghly', @WB, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'NDB')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('NDB', 'North 24 Parganas', @WB, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'SDB')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('SDB', 'South 24 Parganas', @WB, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'BRD')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('BRD', 'Bardhaman', @WB, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'MLD')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('MLD', 'Malda', @WB, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'MRS')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('MRS', 'Murshidabad', @WB, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'NBP')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('NBP', 'Nadia', @WB, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'MDP')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('MDP', 'Medinipur', @WB, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'JLP')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('JLP', 'Jalpaiguri', @WB, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'CBH')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('CBH', 'Cooch Behar', @WB, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'PKR')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('PKR', 'Purulia', @WB, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'BKR')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('BKR', 'Bankura', @WB, 1, GETDATE());

GO

-- =============================================================================
-- CITIES
-- =============================================================================

-- ─── Kolkata District ─────────────────────────────────────────────────────────
DECLARE @dKOL INT = (SELECT DistrictId FROM DistrictMaster WHERE DistrictCode = 'KOL');

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'KOL')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('KOL', 'Kolkata City', @dKOL, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'SLD')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('SLD', 'Salt Lake City', @dKOL, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'NTW')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('NTW', 'New Town', @dKOL, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'JAD')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('JAD', 'Jadavpur', @dKOL, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'DUM')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('DUM', 'Dum Dum', @dKOL, 1, GETDATE());

-- ─── Darjeeling District ──────────────────────────────────────────────────────
DECLARE @dDRJ INT = (SELECT DistrictId FROM DistrictMaster WHERE DistrictCode = 'DRJ');

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'DRJC')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('DRJC', 'Darjeeling Town', @dDRJ, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'KRS')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('KRS', 'Kurseong', @dDRJ, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'KLI')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('KLI', 'Kalimpong', @dDRJ, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'SBG')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('SBG', 'Siliguri', @dDRJ, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'MNS')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('MNS', 'Mirik', @dDRJ, 1, GETDATE());

-- ─── Howrah District ──────────────────────────────────────────────────────────
DECLARE @dHWH INT = (SELECT DistrictId FROM DistrictMaster WHERE DistrictCode = 'HWH');

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'HWHC')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('HWHC', 'Howrah City', @dHWH, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'ULP')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('ULP', 'Uluberia', @dHWH, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'SRP')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('SRP', 'Shibpur', @dHWH, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'BLL')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('BLL', 'Bally', @dHWH, 1, GETDATE());

-- ─── Hooghly District ─────────────────────────────────────────────────────────
DECLARE @dHGL INT = (SELECT DistrictId FROM DistrictMaster WHERE DistrictCode = 'HGL');

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'CHN')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('CHN', 'Chinsurah', @dHGL, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'SRM')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('SRM', 'Serampore', @dHGL, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'CGL')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('CGL', 'Chandannagar', @dHGL, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'ARM')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('ARM', 'Arambagh', @dHGL, 1, GETDATE());

-- ─── North 24 Parganas ────────────────────────────────────────────────────────
DECLARE @dNDB INT = (SELECT DistrictId FROM DistrictMaster WHERE DistrictCode = 'NDB');

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'BRK')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('BRK', 'Barasat', @dNDB, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'BRP')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('BRP', 'Barrackpur', @dNDB, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'NGK')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('NGK', 'Naihati', @dNDB, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'HBR')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('HBR', 'Habra', @dNDB, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'BNR')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('BNR', 'Bongaon', @dNDB, 1, GETDATE());

-- ─── South 24 Parganas ────────────────────────────────────────────────────────
DECLARE @dSDB INT = (SELECT DistrictId FROM DistrictMaster WHERE DistrictCode = 'SDB');

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'DMS')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('DMS', 'Diamond Harbour', @dSDB, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'BGL')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('BGL', 'Budge Budge', @dSDB, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'KNR')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('KNR', 'Kakdwip', @dSDB, 1, GETDATE());

-- ─── Bardhaman District ───────────────────────────────────────────────────────
DECLARE @dBRD INT = (SELECT DistrictId FROM DistrictMaster WHERE DistrictCode = 'BRD');

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'BRDC')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('BRDC', 'Bardhaman City', @dBRD, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'DSP')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('DSP', 'Durgapur', @dBRD, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'ASN')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('ASN', 'Asansol', @dBRD, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'KLY')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('KLY', 'Kalna', @dBRD, 1, GETDATE());

-- ─── Malda District ───────────────────────────────────────────────────────────
DECLARE @dMLD INT = (SELECT DistrictId FROM DistrictMaster WHERE DistrictCode = 'MLD');

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'MLDC')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('MLDC', 'Malda Town', @dMLD, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'ENG')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('ENG', 'English Bazar', @dMLD, 1, GETDATE());

-- ─── Murshidabad District ─────────────────────────────────────────────────────
DECLARE @dMRS INT = (SELECT DistrictId FROM DistrictMaster WHERE DistrictCode = 'MRS');

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'BHR')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('BHR', 'Behrampore', @dMRS, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'JGP')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('JGP', 'Jangipur', @dMRS, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'KDS')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('KDS', 'Kandi', @dMRS, 1, GETDATE());

-- ─── Nadia District ───────────────────────────────────────────────────────────
DECLARE @dNBP INT = (SELECT DistrictId FROM DistrictMaster WHERE DistrictCode = 'NBP');

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'KRI')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('KRI', 'Krishnanagar', @dNBP, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'RNP')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('RNP', 'Ranaghat', @dNBP, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'NDB2')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('NDB2', 'Nabadwip', @dNBP, 1, GETDATE());

-- ─── Jalpaiguri District ──────────────────────────────────────────────────────
DECLARE @dJLP INT = (SELECT DistrictId FROM DistrictMaster WHERE DistrictCode = 'JLP');

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'JLPC')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('JLPC', 'Jalpaiguri Town', @dJLP, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'DHU')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('DHU', 'Dhupguri', @dJLP, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'MYN')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('MYN', 'Mainaguri', @dJLP, 1, GETDATE());

GO

-- =============================================================================
-- AREAS
-- =============================================================================

-- ─── Kolkata City Areas ───────────────────────────────────────────────────────
DECLARE @cKOL INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'KOL');

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'PRK') AND @cKOL IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('PRK', 'Park Street', @cKOL, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'BBD') AND @cKOL IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('BBD', 'BBD Bagh', @cKOL, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'GDN') AND @cKOL IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('GDN', 'Garden Reach', @cKOL, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'BLG') AND @cKOL IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('BLG', 'Ballygunge', @cKOL, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'TLP') AND @cKOL IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('TLP', 'Tollygunge', @cKOL, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'GRD') AND @cKOL IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('GRD', 'Gariahat', @cKOL, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'DHR') AND @cKOL IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('DHR', 'Dhakuria', @cKOL, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'LAK') AND @cKOL IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('LAK', 'Lake Town', @cKOL, 1, GETDATE());

-- ─── Salt Lake City Areas ─────────────────────────────────────────────────────
DECLARE @cSLD INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'SLD');

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'SLB') AND @cSLD IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('SLB', 'Sector I', @cSLD, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'SL2') AND @cSLD IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('SL2', 'Sector II', @cSLD, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'SL3') AND @cSLD IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('SL3', 'Sector III', @cSLD, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'SL5') AND @cSLD IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('SL5', 'Sector V', @cSLD, 1, GETDATE());

-- ─── Darjeeling Town Areas ────────────────────────────────────────────────────
DECLARE @cDRJC INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'DRJC');

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'CHW') AND @cDRJC IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('CHW', 'Chowrasta', @cDRJC, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'GHM') AND @cDRJC IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('GHM', 'Ghoom', @cDRJC, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'TLB') AND @cDRJC IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('TLB', 'Lebong', @cDRJC, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'JLH') AND @cDRJC IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('JLH', 'Jalapahar', @cDRJC, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'TPG') AND @cDRJC IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('TPG', 'Tukvar', @cDRJC, 1, GETDATE());

-- ─── Siliguri Areas ───────────────────────────────────────────────────────────
DECLARE @cSBG INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'SBG');

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'SBG1') AND @cSBG IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('SBG1', 'Siliguri Town', @cSBG, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'NJP') AND @cSBG IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('NJP', 'New Jalpaiguri', @cSBG, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'PDM') AND @cSBG IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('PDM', 'Pradhan Nagar', @cSBG, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'BGL2') AND @cSBG IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('BGL2', 'Bagdogra', @cSBG, 1, GETDATE());

-- ─── Kurseong Areas ───────────────────────────────────────────────────────────
DECLARE @cKRS INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'KRS');

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'KRS1') AND @cKRS IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('KRS1', 'Kurseong Bazaar', @cKRS, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'MKB') AND @cKRS IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('MKB', 'Makaibari', @cKRS, 1, GETDATE());

-- ─── Howrah City Areas ────────────────────────────────────────────────────────
DECLARE @cHWHC INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'HWHC');

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'SGR') AND @cHWHC IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('SGR', 'Shibpur', @cHWHC, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'LLG') AND @cHWHC IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('LLG', 'Liluah', @cHWHC, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'GBR') AND @cHWHC IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('GBR', 'Golabari', @cHWHC, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'DKN') AND @cHWHC IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('DKN', 'Dasnagar', @cHWHC, 1, GETDATE());

-- ─── Durgapur Areas ───────────────────────────────────────────────────────────
DECLARE @cDSP INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'DSP');

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'CTY') AND @cDSP IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('CTY', 'City Centre', @cDSP, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'STL') AND @cDSP IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('STL', 'Steel Township', @cDSP, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'BNK') AND @cDSP IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('BNK', 'Benachity', @cDSP, 1, GETDATE());

-- ─── Asansol Areas ────────────────────────────────────────────────────────────
DECLARE @cASN INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'ASN');

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'ASN1') AND @cASN IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('ASN1', 'Asansol Main', @cASN, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'RNR') AND @cASN IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('RNR', 'Raniganj', @cASN, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'KLN') AND @cASN IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('KLN', 'Kulti', @cASN, 1, GETDATE());

-- ─── Barasat Areas ────────────────────────────────────────────────────────────
DECLARE @cBRK INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'BRK');

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'BRK1') AND @cBRK IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('BRK1', 'Barasat Town', @cBRK, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'MDN') AND @cBRK IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('MDN', 'Madhyamgram', @cBRK, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'MNG') AND @cBRK IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('MNG', 'Noapara', @cBRK, 1, GETDATE());

-- ─── Krishnanagar Areas ───────────────────────────────────────────────────────
DECLARE @cKRI INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'KRI');

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'KRI1') AND @cKRI IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('KRI1', 'Krishnanagar Town', @cKRI, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'BWN') AND @cKRI IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('BWN', 'Beldanga', @cKRI, 1, GETDATE());

-- ─── Behrampore Areas ────────────────────────────────────────────────────────
DECLARE @cBHR INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'BHR');

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'BHR1') AND @cBHR IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('BHR1', 'Behrampore Town', @cBHR, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'LBG') AND @cBHR IS NOT NULL
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('LBG', 'Lalbagh', @cBHR, 1, GETDATE());

GO

PRINT 'Script 15 complete: West Bengal cities and areas seeded.';
