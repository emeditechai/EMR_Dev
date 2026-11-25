-- ============================================================================================================
-- 2554: LAB B2C - FORM F (PC-PNDT Act, Rule 9(4) / 10(1A)) printed from the bill.
--   A bill with a test whose Investigation Master has Applicable Gender = Female and Consent Required = Yes (directly or
--   inside a profile / package) can print FORM F on A4: from the success card after B2C billing and from the B2C Order
--   List ("Print FORM - F").
--     HospitalSettings.PndtRegistrationNo   new: the branch's PC-PNDT registration no. (Hospital Settings > Lab);
--                                           FORM F falls back to the general Registration Number when blank.
--     usp_LabOrder_ConsentStatus            + FormFRequired
--     usp_LabOrder_FormF                    the form's dynamic fields: clinic, registration, patient, age, husband /
--                                           father, address, phone, referring doctor, LMP + weeks, procedures, date.
--   Permission: PrintFormF is part of PRINT on the B2C Order List and B2C Booking pages. Safe to re-run. Needs 2553.
-- ============================================================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

IF COL_LENGTH('dbo.HospitalSettings', 'PndtRegistrationNo') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PndtRegistrationNo NVARCHAR(100) NULL;
GO

-- the tests of some orders: a test line is itself, a package line is its members, a profile test brings its members
CREATE OR ALTER FUNCTION dbo.ufn_LabOrder_TestsOf (@LabOrderIds NVARCHAR(MAX))
RETURNS @T TABLE (LabOrderId INT, TestId INT)
AS
BEGIN
    DECLARE @Ids TABLE (LabOrderId INT PRIMARY KEY);
    INSERT @Ids SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS INT)
    FROM STRING_SPLIT(ISNULL(@LabOrderIds, ''), ',')
    WHERE TRY_CAST(LTRIM(RTRIM(value)) AS INT) IS NOT NULL;

    INSERT @T
    SELECT li.LabOrderId, li.InvestigationId
    FROM dbo.LabOrderItem li INNER JOIN @Ids i ON i.LabOrderId = li.LabOrderId
    WHERE li.IsActive = 1 AND ISNULL(li.[Type], 'I') <> 'P';

    INSERT @T
    SELECT li.LabOrderId, d.Test_ID
    FROM dbo.LabOrderItem li INNER JOIN @Ids i ON i.LabOrderId = li.LabOrderId
    INNER JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = li.InvestigationId AND d.IsDeleted = 0
    WHERE li.IsActive = 1 AND li.[Type] = 'P';

    INSERT @T
    SELECT t.LabOrderId, d.Test_ID
    FROM @T t
    INNER JOIN dbo.LabInvestigationMaster m ON m.Test_ID = t.TestId AND ISNULL(m.Is_Profile_Test, 0) = 1
    INNER JOIN dbo.LabInvestigationProfileHeader h ON (h.Test_ID = m.Test_ID OR h.Profile_Name = m.Test_Name) AND h.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = h.Profile_ID AND d.IsDeleted = 0;
    RETURN;
END;
GO

-- 2553 + FormFRequired (a consent test that applies to females)
CREATE OR ALTER PROCEDURE dbo.usp_LabOrder_ConsentStatus
    @LabOrderIds NVARCHAR(MAX),
    @BranchId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * INTO #T FROM dbo.ufn_LabOrder_TestsOf(@LabOrderIds);

    SELECT o.LabOrderId,
           CAST(CASE WHEN c.Tests IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS ConsentRequired,
           c.Tests AS ConsentTests,
           o.ConsentFilePath, o.ConsentRemarks,
           CAST(CASE WHEN ISNULL(o.IsB2B, 0) = 0 AND EXISTS (
                    SELECT 1 FROM #T t INNER JOIN dbo.LabInvestigationMaster m ON m.Test_ID = t.TestId
                    WHERE t.LabOrderId = o.LabOrderId AND ISNULL(m.Is_Consent_Required, 0) = 1 AND m.Applicable_Gender = 'Female')
                THEN 1 ELSE 0 END AS BIT) AS FormFRequired
    FROM dbo.LabOrder o
    INNER JOIN (SELECT DISTINCT LabOrderId FROM #T
                UNION SELECT TRY_CAST(LTRIM(RTRIM(value)) AS INT) FROM STRING_SPLIT(ISNULL(@LabOrderIds, ''), ',')
                WHERE TRY_CAST(LTRIM(RTRIM(value)) AS INT) IS NOT NULL) i ON i.LabOrderId = o.LabOrderId
    OUTER APPLY (SELECT STRING_AGG(x.Test_Name, ', ') AS Tests
                 FROM (SELECT DISTINCT m.Test_Name FROM #T t
                       INNER JOIN dbo.LabInvestigationMaster m ON m.Test_ID = t.TestId AND ISNULL(m.Is_Consent_Required, 0) = 1
                       WHERE t.LabOrderId = o.LabOrderId) x) c
    WHERE @BranchId IS NULL OR o.BranchId = @BranchId;
END;
GO

-- FORM F: the dynamic fields of one bill (nothing when the bill does not need it)
CREATE OR ALTER PROCEDURE dbo.usp_LabOrder_FormF
    @LabOrderId INT,
    @BranchId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ids NVARCHAR(20) = CAST(@LabOrderId AS NVARCHAR(20));
    SELECT * INTO #T FROM dbo.ufn_LabOrder_TestsOf(@ids);

    DECLARE @Procedures NVARCHAR(MAX) = (
        SELECT STRING_AGG(x.Test_Name, ', ')
        FROM (SELECT DISTINCT m.Test_Name FROM #T t INNER JOIN dbo.LabInvestigationMaster m ON m.Test_ID = t.TestId
              WHERE ISNULL(m.Is_Consent_Required, 0) = 1 AND m.Applicable_Gender = 'Female') x);
    IF @Procedures IS NULL RETURN;   -- no FORM F for this bill: no row

    SELECT o.LabOrderId, o.BillNo,
           COALESCE(o.CreatedDate, o.OrderDate) AS BillDate,
           -- clinic
           ISNULL(NULLIF(LTRIM(RTRIM(hs.HotelName)), ''), b.BranchName) AS ClinicName,
           LTRIM(RTRIM(CONCAT(ISNULL(NULLIF(LTRIM(RTRIM(hs.Address)), ''), b.Address),
                 CASE WHEN NULLIF(LTRIM(RTRIM(hs.Address)), '') IS NULL AND b.City IS NOT NULL THEN ', ' + b.City ELSE '' END))) AS ClinicAddress,
           ISNULL(NULLIF(LTRIM(RTRIM(hs.PndtRegistrationNo)), ''), hs.RegistrationNumber) AS RegistrationNo,
           hs.ContactNumber1 AS ClinicPhone,
           ISNULL(NULLIF(LTRIM(RTRIM(b.City)), ''), b.BranchName) AS Place,
           -- patient
           p.PatientCode,
           LTRIM(RTRIM(CONCAT(p.FirstName, ' ', ISNULL(p.MiddleName + ' ', ''), p.LastName))) AS PatientName,
           p.Salutation, p.Gender,
           CASE WHEN p.DateOfBirth IS NULL THEN NULL
                ELSE DATEDIFF(YEAR, p.DateOfBirth, COALESCE(o.CreatedDate, o.OrderDate))
                     - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, COALESCE(o.CreatedDate, o.OrderDate)), p.DateOfBirth) > COALESCE(o.CreatedDate, o.OrderDate) THEN 1 ELSE 0 END END AS AgeYears,
           p.GuardianName, r.RelationName AS GuardianRelation,
           LTRIM(RTRIM(CONCAT(p.Address, CASE WHEN NULLIF(p.Pincode, '') IS NOT NULL THEN ' - ' + p.Pincode ELSE '' END))) AS PatientAddress,
           p.PhoneNumber,
           -- referral
           COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''),
                    NULLIF(LTRIM(RTRIM(ISNULL(rd.Salutation + ' ', '') + ISNULL(rd.DoctorName, ''))), '')) AS ReferredBy,
           -- pregnancy
           o.LmpDate,
           CASE WHEN o.LmpDate IS NULL THEN NULL ELSE DATEDIFF(DAY, o.LmpDate, COALESCE(o.CreatedDate, o.OrderDate)) END AS PregnancyDays,
           @Procedures AS Procedures
    FROM dbo.LabOrder o
    INNER JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
    LEFT  JOIN dbo.Branchmaster b ON b.BranchID = o.BranchId
    OUTER APPLY (SELECT TOP 1 * FROM dbo.HospitalSettings s WHERE s.BranchID = o.BranchId AND s.IsActive = 1 ORDER BY s.Id DESC) hs
    LEFT  JOIN dbo.RelationMaster r ON r.RelationId = p.RelationId
    LEFT  JOIN dbo.DoctorMaster d ON d.DoctorId = o.RefDoctorId
    LEFT  JOIN dbo.ReferralDoctorMaster rd ON rd.ReferralDoctorId = o.ReferralDoctorId
    WHERE o.LabOrderId = @LabOrderId AND (@BranchId IS NULL OR o.BranchId = @BranchId);
END;
GO

-- ── permission: PrintFormF under PRINT of the B2C Order List and B2C Booking pages ──
DECLARE @page INT, @pr INT;
DECLARE pp CURSOR LOCAL FAST_FORWARD FOR
    SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code IN ('LAB.LABORDERBOOKING.B2CORDERLIST', 'LAB.LABORDERBOOKING.B2CBOOKING');
OPEN pp; FETCH NEXT FROM pp INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @pr = (SELECT TOP 1 Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'PRINT');
    IF @pr IS NULL SET @pr = (SELECT TOP 1 Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW');
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @pr, @App = 'WEB', @Http_Method = 'GET',
         @Controller = N'LabOrderBooking', @Action = N'PrintFormF', @Source = 'SEED';
    FETCH NEXT FROM pp INTO @page;
END
CLOSE pp; DEALLOCATE pp;

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2554 applied: LAB B2C - FORM F (PC-PNDT).';
GO
