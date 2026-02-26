-- ============================================================
-- Sample Data: India Geography Masters
-- Country INDIA is assumed to already exist in CountryMaster.
-- Run this script on Dev_EMR database.
-- ============================================================

DECLARE @IndiaId INT = (SELECT TOP 1 CountryId FROM CountryMaster WHERE CountryCode = 'IN');

IF @IndiaId IS NULL
BEGIN
    RAISERROR('INDIA country not found. Please create it first.', 16, 1);
    RETURN;
END

-- ============================================================
-- STATES
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM StateMaster WHERE StateCode = 'MH')
    INSERT INTO StateMaster (StateCode, StateName, CountryId, IsActive, CreatedDate)
    VALUES ('MH', 'Maharashtra', @IndiaId, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM StateMaster WHERE StateCode = 'DL')
    INSERT INTO StateMaster (StateCode, StateName, CountryId, IsActive, CreatedDate)
    VALUES ('DL', 'Delhi', @IndiaId, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM StateMaster WHERE StateCode = 'KA')
    INSERT INTO StateMaster (StateCode, StateName, CountryId, IsActive, CreatedDate)
    VALUES ('KA', 'Karnataka', @IndiaId, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM StateMaster WHERE StateCode = 'TN')
    INSERT INTO StateMaster (StateCode, StateName, CountryId, IsActive, CreatedDate)
    VALUES ('TN', 'Tamil Nadu', @IndiaId, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM StateMaster WHERE StateCode = 'GJ')
    INSERT INTO StateMaster (StateCode, StateName, CountryId, IsActive, CreatedDate)
    VALUES ('GJ', 'Gujarat', @IndiaId, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM StateMaster WHERE StateCode = 'RJ')
    INSERT INTO StateMaster (StateCode, StateName, CountryId, IsActive, CreatedDate)
    VALUES ('RJ', 'Rajasthan', @IndiaId, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM StateMaster WHERE StateCode = 'UP')
    INSERT INTO StateMaster (StateCode, StateName, CountryId, IsActive, CreatedDate)
    VALUES ('UP', 'Uttar Pradesh', @IndiaId, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM StateMaster WHERE StateCode = 'WB')
    INSERT INTO StateMaster (StateCode, StateName, CountryId, IsActive, CreatedDate)
    VALUES ('WB', 'West Bengal', @IndiaId, 1, GETDATE());

-- ============================================================
-- DISTRICTS
-- ============================================================

-- Maharashtra
DECLARE @MH INT = (SELECT StateId FROM StateMaster WHERE StateCode = 'MH');
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'MUM')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('MUM', 'Mumbai', @MH, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'PUN')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('PUN', 'Pune', @MH, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'NGP')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('NGP', 'Nagpur', @MH, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'NAS')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('NAS', 'Nashik', @MH, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'AUR')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('AUR', 'Aurangabad', @MH, 1, GETDATE());

-- Delhi
DECLARE @DL INT = (SELECT StateId FROM StateMaster WHERE StateCode = 'DL');
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'NDL')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('NDL', 'New Delhi', @DL, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'NCR')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('NCR', 'North Delhi', @DL, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'SDH')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('SDH', 'South Delhi', @DL, 1, GETDATE());

-- Karnataka
DECLARE @KA INT = (SELECT StateId FROM StateMaster WHERE StateCode = 'KA');
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'BLR')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('BLR', 'Bangalore Urban', @KA, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'MYS')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('MYS', 'Mysuru', @KA, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'HUB')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('HUB', 'Dharwad', @KA, 1, GETDATE());

-- Tamil Nadu
DECLARE @TN INT = (SELECT StateId FROM StateMaster WHERE StateCode = 'TN');
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'CHN')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('CHN', 'Chennai', @TN, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'CBE')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('CBE', 'Coimbatore', @TN, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'MDU')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('MDU', 'Madurai', @TN, 1, GETDATE());

-- Gujarat
DECLARE @GJ INT = (SELECT StateId FROM StateMaster WHERE StateCode = 'GJ');
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'AMD')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('AMD', 'Ahmedabad', @GJ, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'SRT')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('SRT', 'Surat', @GJ, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'VDR')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('VDR', 'Vadodara', @GJ, 1, GETDATE());

-- Rajasthan
DECLARE @RJ INT = (SELECT StateId FROM StateMaster WHERE StateCode = 'RJ');
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'JPR')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('JPR', 'Jaipur', @RJ, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'JDH')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('JDH', 'Jodhpur', @RJ, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'UDR')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('UDR', 'Udaipur', @RJ, 1, GETDATE());

-- Uttar Pradesh
DECLARE @UP INT = (SELECT StateId FROM StateMaster WHERE StateCode = 'UP');
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'LKO')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('LKO', 'Lucknow', @UP, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'KNP')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('KNP', 'Kanpur', @UP, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'AGR')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('AGR', 'Agra', @UP, 1, GETDATE());

-- West Bengal
DECLARE @WB INT = (SELECT StateId FROM StateMaster WHERE StateCode = 'WB');
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'KOL')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('KOL', 'Kolkata', @WB, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'HWR')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('HWR', 'Howrah', @WB, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM DistrictMaster WHERE DistrictCode = 'DRJ')
    INSERT INTO DistrictMaster (DistrictCode, DistrictName, StateId, IsActive, CreatedDate)
    VALUES ('DRJ', 'Darjeeling', @WB, 1, GETDATE());

-- ============================================================
-- CITIES
-- ============================================================

-- Mumbai district
DECLARE @dMUM INT = (SELECT DistrictId FROM DistrictMaster WHERE DistrictCode = 'MUM');
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'CST')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('CST', 'Mumbai City', @dMUM, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'AND')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('AND', 'Andheri', @dMUM, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'BOR')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('BOR', 'Borivali', @dMUM, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'THN')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('THN', 'Thane', @dMUM, 1, GETDATE());

-- Pune district
DECLARE @dPUN INT = (SELECT DistrictId FROM DistrictMaster WHERE DistrictCode = 'PUN');
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'PUN')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('PUN', 'Pune City', @dPUN, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'HJW')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('HJW', 'Hadapsar', @dPUN, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'KTW')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('KTW', 'Kothrud', @dPUN, 1, GETDATE());

-- Nagpur district
DECLARE @dNGP INT = (SELECT DistrictId FROM DistrictMaster WHERE DistrictCode = 'NGP');
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'NGP')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('NGP', 'Nagpur City', @dNGP, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'KAM')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('KAM', 'Kamptee', @dNGP, 1, GETDATE());

-- New Delhi district
DECLARE @dNDL INT = (SELECT DistrictId FROM DistrictMaster WHERE DistrictCode = 'NDL');
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'CPL')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('CPL', 'Connaught Place', @dNDL, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'DWK')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('DWK', 'Dwarka', @dNDL, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'RKP')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('RKP', 'Rohini', @dNDL, 1, GETDATE());

-- South Delhi district
DECLARE @dSDH INT = (SELECT DistrictId FROM DistrictMaster WHERE DistrictCode = 'SDH');
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'SKT')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('SKT', 'Saket', @dSDH, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'VVN')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('VVN', 'Vasant Vihar', @dSDH, 1, GETDATE());

-- Bangalore Urban district
DECLARE @dBLR INT = (SELECT DistrictId FROM DistrictMaster WHERE DistrictCode = 'BLR');
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'BLR')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('BLR', 'Bangalore City', @dBLR, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'KOR')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('KOR', 'Koramangala', @dBLR, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'ELK')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('ELK', 'Electronic City', @dBLR, 1, GETDATE());

-- Chennai district
DECLARE @dCHN INT = (SELECT DistrictId FROM DistrictMaster WHERE DistrictCode = 'CHN');
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'CHN')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('CHN', 'Chennai City', @dCHN, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'ANB')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('ANB', 'Anna Nagar', @dCHN, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'TMB')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('TMB', 'Tambaram', @dCHN, 1, GETDATE());

-- Ahmedabad district
DECLARE @dAMD INT = (SELECT DistrictId FROM DistrictMaster WHERE DistrictCode = 'AMD');
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'AMD')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('AMD', 'Ahmedabad City', @dAMD, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'NAR')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('NAR', 'Naroda', @dAMD, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'ASR')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('ASR', 'Asarwa', @dAMD, 1, GETDATE());

-- Jaipur district
DECLARE @dJPR INT = (SELECT DistrictId FROM DistrictMaster WHERE DistrictCode = 'JPR');
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'JPR')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('JPR', 'Jaipur City', @dJPR, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'CGK')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('CGK', 'Chomu', @dJPR, 1, GETDATE());

-- Lucknow district
DECLARE @dLKO INT = (SELECT DistrictId FROM DistrictMaster WHERE DistrictCode = 'LKO');
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'LKO')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('LKO', 'Lucknow City', @dLKO, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'ALD')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('ALD', 'Aliganj', @dLKO, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'GOM')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('GOM', 'Gomti Nagar', @dLKO, 1, GETDATE());

-- Kolkata district
DECLARE @dKOL INT = (SELECT DistrictId FROM DistrictMaster WHERE DistrictCode = 'KOL');
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'KOL')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('KOL', 'Kolkata City', @dKOL, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'SAL')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('SAL', 'Salt Lake City', @dKOL, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM CityMaster WHERE CityCode = 'NST')
    INSERT INTO CityMaster (CityCode, CityName, DistrictId, IsActive, CreatedDate)
    VALUES ('NST', 'New Town', @dKOL, 1, GETDATE());

-- ============================================================
-- AREAS
-- ============================================================

-- Mumbai City areas
DECLARE @cMUM INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'CST');
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'COL')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('COL', 'Colaba', @cMUM, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'FRT')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('FRT', 'Fort', @cMUM, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'CHR')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('CHR', 'Churchgate', @cMUM, 1, GETDATE());

-- Andheri areas
DECLARE @cAND INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'AND');
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'ANE')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('ANE', 'Andheri East', @cAND, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'ANW')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('ANW', 'Andheri West', @cAND, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'VLE')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('VLE', 'Versova', @cAND, 1, GETDATE());

-- Pune City areas
DECLARE @cPUN INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'PUN');
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'SHV')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('SHV', 'Shivaji Nagar', @cPUN, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'DCP')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('DCP', 'Deccan', @cPUN, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'WKD')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('WKD', 'Wakad', @cPUN, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'HNJ')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('HNJ', 'Hinjewadi', @cPUN, 1, GETDATE());

-- Bangalore City areas
DECLARE @cBLR INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'BLR');
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'INR')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('INR', 'Indiranagar', @cBLR, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'MLP')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('MLP', 'Malleshwaram', @cBLR, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'JAY')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('JAY', 'Jayanagar', @cBLR, 1, GETDATE());

-- Koramangala areas
DECLARE @cKOR INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'KOR');
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'K1B')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('K1B', 'Koramangala 1st Block', @cKOR, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'K5B')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('K5B', 'Koramangala 5th Block', @cKOR, 1, GETDATE());

-- Chennai City areas
DECLARE @cCHN INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'CHN');
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'TNS')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('TNS', 'T. Nagar', @cCHN, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'ADY')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('ADY', 'Adyar', @cCHN, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'VLV')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('VLV', 'Velachery', @cCHN, 1, GETDATE());

-- New Delhi areas
DECLARE @cCPL INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'CPL');
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'KRG')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('KRG', 'Karol Bagh', @cCPL, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'PAH')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('PAH', 'Paharganj', @cCPL, 1, GETDATE());

-- Dwarka areas
DECLARE @cDWK INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'DWK');
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'D3')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('D3', 'Dwarka Sector 3', @cDWK, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'D10')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('D10', 'Dwarka Sector 10', @cDWK, 1, GETDATE());

-- Ahmedabad City areas
DECLARE @cAMD INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'AMD');
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'NSP')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('NSP', 'Navrangpura', @cAMD, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'VPN')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('VPN', 'Vastrapur', @cAMD, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'SGH')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('SGH', 'Satellite', @cAMD, 1, GETDATE());

-- Jaipur City areas
DECLARE @cJPR INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'JPR');
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'PCH')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('PCH', 'Pink City (Walled City)', @cJPR, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'VKY')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('VKY', 'Vaishali Nagar', @cJPR, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'MNT')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('MNT', 'Malviya Nagar', @cJPR, 1, GETDATE());

-- Lucknow City areas
DECLARE @cLKO INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'LKO');
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'HZT')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('HZT', 'Hazratganj', @cLKO, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'VBK')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('VBK', 'Vibhuti Khand', @cLKO, 1, GETDATE());

-- Gomti Nagar areas
DECLARE @cGOM INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'GOM');
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'GE1')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('GE1', 'Gomti Nagar Ext 1', @cGOM, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'GVP')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('GVP', 'Govindpur', @cGOM, 1, GETDATE());

-- Kolkata City areas
DECLARE @cKOL INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'KOL');
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'PRK')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('PRK', 'Park Street', @cKOL, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'BBR')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('BBR', 'Ballygunge', @cKOL, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'HPR')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('HPR', 'Howrah Bridge Area', @cKOL, 1, GETDATE());

-- Salt Lake City areas
DECLARE @cSAL INT = (SELECT CityId FROM CityMaster WHERE CityCode = 'SAL');
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'SLS1')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('SLS1', 'Salt Lake Sector 1', @cSAL, 1, GETDATE());
IF NOT EXISTS (SELECT 1 FROM AreaMaster WHERE AreaCode = 'SLS5')
    INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedDate)
    VALUES ('SLS5', 'Salt Lake Sector 5', @cSAL, 1, GETDATE());

PRINT 'India Geography Sample Data inserted successfully.';
