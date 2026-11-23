-- ============================================================================================================
-- Migration: 2283_patient_register_report.sql
-- Reports > Patient Register, rebuilt: patients registered in a period with their demographics, family position
-- (head of family / dependent and the head they belong to), address, membership card, OPD / LAB activity, branch
-- and the user who registered them. Filters: branch, scope (all / heads / dependents), gender, age, membership,
-- status and a search on name / code / mobile.
--   dbo.usp_Report_PatientRegister   new; the old dbo.usp_Api_Report_PatientRegister is left as it is.
--   Endpoint Reports/GetPatientRegisterReport on page REPORTS.PATIENTREGISTER, control VIEW (no grant changes).
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Report_PatientRegister
    @CompanyId   INT,
    @BranchId    INT           = NULL,     -- NULL = every branch of the company
    @FromDate    DATE,
    @ToDate      DATE,
    @Scope       VARCHAR(5)    = 'ALL',    -- ALL | HEAD (relation Self) | DEP (every other relation)
    @Gender      NVARCHAR(10)  = NULL,     -- Male | Female | Other (anything else, or blank)
    @AgeFrom     INT           = NULL,     -- age in completed years, today
    @AgeTo       INT           = NULL,
    @Membership  CHAR(1)       = NULL,     -- Y = has an active card, N = none
    @Status      CHAR(1)       = 'A',      -- A = active, I = inactive, NULL = both
    @Search      NVARCHAR(100) = NULL      -- name, patient code or mobile
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));   -- the whole of the last day
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');

    ;WITH pat AS
    (
        SELECT p.*,
               CASE WHEN p.DateOfBirth IS NULL THEN NULL
                    ELSE DATEDIFF(YEAR, p.DateOfBirth, @Today)
                         - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, @Today), p.DateOfBirth) > @Today THEN 1 ELSE 0 END
               END AS AgeYears,
               NULLIF(LTRIM(RTRIM(p.PhoneNumber)), '') AS Phone
          FROM dbo.PatientMaster p
         WHERE p.CompanyId = @CompanyId
           AND p.CreatedDate >= @FromDate AND p.CreatedDate < @To
           AND (@BranchId IS NULL OR p.BranchId = @BranchId)
           AND (@Status IS NULL OR p.IsActive = CASE @Status WHEN 'A' THEN 1 ELSE 0 END)
           AND (@Scope = 'ALL' OR (@Scope = 'HEAD' AND p.RelationId = 1) OR (@Scope = 'DEP' AND ISNULL(p.RelationId, 0) <> 1))
           AND (@Gender IS NULL
                OR (@Gender IN ('Male', 'Female') AND p.Gender = @Gender)
                OR (@Gender = 'Other' AND ISNULL(p.Gender, '') NOT IN ('Male', 'Female')))
           AND (@Search IS NULL
                OR p.PatientCode LIKE @Search + '%'
                OR p.PhoneNumber LIKE @Search + '%'
                OR CONCAT(p.FirstName, ' ', p.MiddleName + ' ', p.LastName) LIKE '%' + @Search + '%'
                OR CONCAT(p.FirstName, ' ', p.LastName) LIKE '%' + @Search + '%')
    )
    SELECT p.PatientId, p.PatientCode, p.CreatedDate AS RegistrationDate,
           LTRIM(CONCAT(p.Salutation + ' ', p.FirstName, ' ' + NULLIF(p.MiddleName, ''), ' ' + p.LastName)) AS PatientName,
           p.Gender, p.DateOfBirth, p.AgeYears, p.PhoneNumber, p.SecondaryPhoneNumber, p.EmailId, p.BloodGroup,
           p.RelationId, rel.RelationName, CAST(CASE WHEN p.RelationId = 1 THEN 1 ELSE 0 END AS BIT) AS IsHead,
           hd.HeadPatientId, hd.HeadCode, hd.HeadName,
           fam.FamilyCount,
           p.Address, ar.AreaName, ci.CityName, di.DistrictName, st.StateName,
           b.BranchName, COALESCE(NULLIF(u.FullName, ''), u.Username) AS RegisteredBy,
           LTRIM(ISNULL(rd.Salutation + ' ', '') + rd.DoctorName) AS ReferralDoctor,
           mc.CardId, mc.CardNo, mc.PlanName, mc.CardStatus,
           act.OpdVisits, act.LabBills, act.LastVisit,
           p.IsActive
      FROM pat p
      LEFT JOIN dbo.RelationMaster       rel ON rel.RelationId = p.RelationId
      LEFT JOIN dbo.Branchmaster         b   ON b.BranchID = p.BranchId
      LEFT JOIN dbo.Users                u   ON u.Id = p.CreatedBy
      LEFT JOIN dbo.ReferralDoctorMaster rd  ON rd.ReferralDoctorId = p.ReferralDoctorId
      LEFT JOIN dbo.AreaMaster           ar  ON ar.AreaId = p.AreaId
      LEFT JOIN dbo.CityMaster           ci  ON ci.CityId = p.CityId
      LEFT JOIN dbo.DistrictMaster       di  ON di.DistrictId = p.DistrictId
      LEFT JOIN dbo.StateMaster          st  ON st.StateId = p.StateId
      -- head of family: the Self patient on the same mobile number
      OUTER APPLY (SELECT TOP 1 h.PatientId AS HeadPatientId, h.PatientCode AS HeadCode,
                          LTRIM(CONCAT(h.Salutation + ' ', h.FirstName, ' ' + NULLIF(h.MiddleName, ''), ' ' + h.LastName)) AS HeadName
                     FROM dbo.PatientMaster h
                    WHERE p.RelationId <> 1 AND p.Phone IS NOT NULL AND h.CompanyId = p.CompanyId
                      AND h.RelationId = 1 AND LTRIM(RTRIM(h.PhoneNumber)) = p.Phone AND h.PatientId <> p.PatientId
                    ORDER BY h.IsActive DESC, h.PatientId) hd
      -- the others registered on the same mobile number
      OUTER APPLY (SELECT COUNT(*) AS FamilyCount
                     FROM dbo.PatientMaster f
                    WHERE p.Phone IS NOT NULL AND f.CompanyId = p.CompanyId AND f.IsActive = 1
                      AND LTRIM(RTRIM(f.PhoneNumber)) = p.Phone AND f.PatientId <> p.PatientId) fam
      -- membership: an active, unexpired card first, else the newest
      OUTER APPLY (SELECT TOP 1 c.CardId, c.CardNo, pl.PlanName,
                          CASE WHEN c.Status = 'Active' AND c.ValidTo < @Today THEN 'Expired' ELSE c.Status END AS CardStatus
                     FROM dbo.MembershipCardMember m
                     JOIN dbo.MembershipCard c  ON c.CardId = m.CardId
                     JOIN dbo.MembershipPlan pl ON pl.PlanId = c.PlanId
                    WHERE m.PatientId = p.PatientId AND m.IsActive = 1
                    ORDER BY CASE WHEN c.Status = 'Active' AND c.ValidTo >= @Today THEN 0 ELSE 1 END, c.CardId DESC) mc
      OUTER APPLY (SELECT (SELECT COUNT(*) FROM dbo.PatientOPDService s WHERE s.PatientId = p.PatientId AND s.IsActive = 1) AS OpdVisits,
                          (SELECT COUNT(*) FROM dbo.LabOrder l WHERE l.PatientId = p.PatientId AND l.IsActive = 1) AS LabBills,
                          (SELECT MAX(d) FROM (SELECT MAX(s.VisitDate) FROM dbo.PatientOPDService s WHERE s.PatientId = p.PatientId AND s.IsActive = 1
                                               UNION ALL
                                               SELECT MAX(l.OrderDate) FROM dbo.LabOrder l WHERE l.PatientId = p.PatientId AND l.IsActive = 1) x(d)) AS LastVisit) act
     WHERE (@AgeFrom IS NULL OR p.AgeYears >= @AgeFrom)
       AND (@AgeTo IS NULL OR p.AgeYears <= @AgeTo)
       AND (@Membership IS NULL
            OR (@Membership = 'Y' AND mc.CardStatus = 'Active')
            OR (@Membership = 'N' AND ISNULL(mc.CardStatus, '') <> 'Active'))
     ORDER BY p.CreatedDate DESC, p.PatientId DESC
    OPTION (RECOMPILE);
END
GO

DECLARE @page INT, @ctl INT;
DECLARE pg CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'REPORTS.PATIENTREGISTER';
OPEN pg; FETCH NEXT FROM pg INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = (SELECT Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW');
    IF @ctl IS NOT NULL
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'Reports', @Action = N'GetPatientRegisterReport', @Source = 'SEED';
    FETCH NEXT FROM pg INTO @page;
END
CLOSE pg; DEALLOCATE pg;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2283 applied: Patient Register report (usp_Report_PatientRegister).';
GO
