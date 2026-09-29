-- ============================================================================
-- Migration: 2176_doctor_ip_master.sql
-- Description: Doctor IP (referral doctor commission) master.
--   * Doctor_IP_Hdr / Doctor_IP_Dtl - commission % per test / profile, per doctor, branch and period.
--   * DoctorIpAccessSetting / DoctorIpAccessLog - the page is confidential: it opens only after a
--     company-level access code is validated. The code is stored as a salted SHA-256 hash, never as
--     plain text. Repeated wrong codes lock the user out for a while.
--   * Authorization: page MASTER.DOCTORIP under MASTER.IPD_MASTER, Show_In_Menu = 0, with controls
--     VIEW / ADD / EDIT / DETAILS / STATUS / DELETE and every endpoint mapped.
--   Run after 2163 (navigation seed).
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- 1. Tables ------------------------------------------------------------------
IF OBJECT_ID('dbo.Doctor_IP_Hdr', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Doctor_IP_Hdr
    (
        Doctor_IP_Hdr_ID INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId        INT NOT NULL DEFAULT 1,
        Doctor_ID        INT NOT NULL,
        Speciality_ID    INT NULL,
        Branch_ID        INT NOT NULL,
        Effective_From   DATE NOT NULL,
        Effective_To     DATE NOT NULL,
        IsActive         BIT NOT NULL DEFAULT 1,
        IsDeleted        BIT NOT NULL DEFAULT 0,
        Created_By       INT NULL,
        CreatedDate      DATETIME NOT NULL DEFAULT GETDATE(),
        Updated_By       INT NULL,
        UpdatedDate      DATETIME NULL,
        CONSTRAINT CK_Doctor_IP_Hdr_Dates CHECK (Effective_To >= Effective_From)
    );
    CREATE INDEX IX_Doctor_IP_Hdr_Doctor ON dbo.Doctor_IP_Hdr (Doctor_ID, Branch_ID, IsDeleted);
END
GO

IF OBJECT_ID('dbo.Doctor_IP_Dtl', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Doctor_IP_Dtl
    (
        Doctor_IP_Dtl_ID BIGINT IDENTITY(1,1) PRIMARY KEY,
        Doctor_IP_Hdr_ID INT NOT NULL REFERENCES dbo.Doctor_IP_Hdr (Doctor_IP_Hdr_ID),
        Department_ID    INT NULL,
        Category_ID      INT NULL,
        Sub_Category_ID  INT NULL,
        Test_ID          BIGINT NOT NULL,
        Commission_Rate  DECIMAL(18,2) NOT NULL,
        CONSTRAINT CK_Doctor_IP_Dtl_Rate CHECK (Commission_Rate BETWEEN 0 AND 100)
    );
    CREATE UNIQUE INDEX UX_Doctor_IP_Dtl_Test ON dbo.Doctor_IP_Dtl (Doctor_IP_Hdr_ID, Test_ID);
END
GO

IF OBJECT_ID('dbo.DoctorIpAccessSetting', 'U') IS NULL
    CREATE TABLE dbo.DoctorIpAccessSetting
    (
        CompanyId      INT PRIMARY KEY,
        Code_Salt      VARBINARY(16) NOT NULL,
        Code_Hash      VARBINARY(32) NOT NULL,
        Unlock_Minutes INT NOT NULL DEFAULT 15,
        Max_Attempts   INT NOT NULL DEFAULT 5,
        Lock_Minutes   INT NOT NULL DEFAULT 15,
        ModifiedBy     INT NULL,
        ModifiedDate   DATETIME NOT NULL DEFAULT GETDATE()
    );
GO

IF OBJECT_ID('dbo.DoctorIpAccessLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DoctorIpAccessLog
    (
        Log_ID      BIGINT IDENTITY(1,1) PRIMARY KEY,
        CompanyId   INT NOT NULL,
        UserId      INT NOT NULL,
        Event_Type  VARCHAR(20) NOT NULL,   -- UNLOCK_OK / UNLOCK_FAIL / LOCKED_OUT / CODE_SET
        Ip_Address  NVARCHAR(64) NULL,
        CreatedDate DATETIME NOT NULL DEFAULT GETDATE()
    );
    CREATE INDEX IX_DoctorIpAccessLog_User ON dbo.DoctorIpAccessLog (CompanyId, UserId, CreatedDate);
END
GO

-- 2. Access code -------------------------------------------------------------
CREATE OR ALTER FUNCTION dbo.fn_DoctorIp_AccessState (@CompanyId INT, @UserId INT)
RETURNS TABLE
AS
RETURN
    WITH cfg AS (
        SELECT CAST(1 AS BIT) AS IsConfigured, Unlock_Minutes, Max_Attempts, Lock_Minutes
        FROM dbo.DoctorIpAccessSetting WHERE CompanyId = @CompanyId
        UNION ALL
        SELECT CAST(0 AS BIT), 15, 5, 15
        WHERE NOT EXISTS (SELECT 1 FROM dbo.DoctorIpAccessSetting WHERE CompanyId = @CompanyId)
    ),
    fails AS (
        -- failures since the last success, inside the lock window
        SELECT COUNT(*) AS Fails, MAX(l.CreatedDate) AS LastFail
        FROM dbo.DoctorIpAccessLog l CROSS JOIN cfg
        WHERE l.CompanyId = @CompanyId AND l.UserId = @UserId AND l.Event_Type = 'UNLOCK_FAIL'
          AND l.CreatedDate > DATEADD(MINUTE, -cfg.Lock_Minutes, GETDATE())
          AND l.Log_ID > ISNULL((SELECT MAX(o.Log_ID) FROM dbo.DoctorIpAccessLog o
                                 WHERE o.CompanyId = @CompanyId AND o.UserId = @UserId AND o.Event_Type = 'UNLOCK_OK'), 0)
    )
    SELECT cfg.IsConfigured,
           cfg.Unlock_Minutes AS UnlockMinutes,
           cfg.Lock_Minutes AS LockMinutes,
           CAST(CASE WHEN f.Fails >= cfg.Max_Attempts THEN 1 ELSE 0 END AS BIT) AS IsLockedOut,
           CASE WHEN f.Fails >= cfg.Max_Attempts THEN CAST(CEILING(DATEDIFF(SECOND, GETDATE(), DATEADD(MINUTE, cfg.Lock_Minutes, f.LastFail)) / 60.0) AS INT) ELSE 0 END AS LockedMinutesLeft,
           CASE WHEN cfg.Max_Attempts - f.Fails > 0 THEN cfg.Max_Attempts - f.Fails ELSE 0 END AS AttemptsLeft
    FROM cfg CROSS JOIN fails f;
GO

CREATE OR ALTER PROCEDURE dbo.usp_DoctorIp_AccessStatus
    @CompanyId INT,
    @UserId    INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT IsConfigured, UnlockMinutes, IsLockedOut, LockedMinutesLeft, AttemptsLeft FROM dbo.fn_DoctorIp_AccessState(@CompanyId, @UserId);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_DoctorIp_VerifyAccessCode
    @CompanyId INT,
    @UserId    INT,
    @Code      NVARCHAR(100),
    @IpAddress NVARCHAR(64) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Configured BIT, @Unlock INT, @LockMin INT, @Locked BIT, @LockLeft INT, @Left INT;
    SELECT @Configured = IsConfigured, @Unlock = UnlockMinutes, @LockMin = LockMinutes, @Locked = IsLockedOut,
           @LockLeft = LockedMinutesLeft, @Left = AttemptsLeft
    FROM dbo.fn_DoctorIp_AccessState(@CompanyId, @UserId);

    IF @Configured = 0
    BEGIN
        SELECT 'NOT_CONFIGURED' AS Result, 0 AS UnlockMinutes, 0 AS AttemptsLeft, 0 AS LockedMinutesLeft;
        RETURN;
    END
    IF @Locked = 1
    BEGIN
        INSERT INTO dbo.DoctorIpAccessLog (CompanyId, UserId, Event_Type, Ip_Address) VALUES (@CompanyId, @UserId, 'LOCKED_OUT', @IpAddress);
        SELECT 'LOCKED' AS Result, 0 AS UnlockMinutes, 0 AS AttemptsLeft, @LockLeft AS LockedMinutesLeft;
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM dbo.DoctorIpAccessSetting
               WHERE CompanyId = @CompanyId
                 AND Code_Hash = HASHBYTES('SHA2_256', Code_Salt + CAST(ISNULL(@Code, N'') AS VARBINARY(200))))
    BEGIN
        INSERT INTO dbo.DoctorIpAccessLog (CompanyId, UserId, Event_Type, Ip_Address) VALUES (@CompanyId, @UserId, 'UNLOCK_OK', @IpAddress);
        SELECT 'OK' AS Result, @Unlock AS UnlockMinutes, 0 AS AttemptsLeft, 0 AS LockedMinutesLeft;
        RETURN;
    END

    INSERT INTO dbo.DoctorIpAccessLog (CompanyId, UserId, Event_Type, Ip_Address) VALUES (@CompanyId, @UserId, 'UNLOCK_FAIL', @IpAddress);
    SET @Left = @Left - 1;
    SELECT CASE WHEN @Left <= 0 THEN 'LOCKED' ELSE 'INVALID' END AS Result, 0 AS UnlockMinutes,
           CASE WHEN @Left > 0 THEN @Left ELSE 0 END AS AttemptsLeft,
           CASE WHEN @Left <= 0 THEN @LockMin ELSE 0 END AS LockedMinutesLeft;
END
GO

-- Sets or changes the code. When a code already exists, the current code must be supplied.
CREATE OR ALTER PROCEDURE dbo.usp_DoctorIp_SetAccessCode
    @CompanyId   INT,
    @NewCode     NVARCHAR(100),
    @CurrentCode NVARCHAR(100) = NULL,
    @UserId      INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @NewCode IS NULL OR LEN(@NewCode) < 6
    BEGIN
        RAISERROR('The access code must be at least 6 characters.', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM dbo.DoctorIpAccessSetting WHERE CompanyId = @CompanyId)
       AND NOT EXISTS (SELECT 1 FROM dbo.DoctorIpAccessSetting
                       WHERE CompanyId = @CompanyId
                         AND Code_Hash = HASHBYTES('SHA2_256', Code_Salt + CAST(ISNULL(@CurrentCode, N'') AS VARBINARY(200))))
    BEGIN
        RAISERROR('The current access code is not correct.', 16, 1);
        RETURN;
    END

    DECLARE @Salt VARBINARY(16) = CRYPT_GEN_RANDOM(16);
    DECLARE @Hash VARBINARY(32) = HASHBYTES('SHA2_256', @Salt + CAST(@NewCode AS VARBINARY(200)));

    MERGE dbo.DoctorIpAccessSetting AS t
    USING (SELECT @CompanyId AS CompanyId) AS s ON t.CompanyId = s.CompanyId
    WHEN MATCHED THEN UPDATE SET Code_Salt = @Salt, Code_Hash = @Hash, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHEN NOT MATCHED THEN INSERT (CompanyId, Code_Salt, Code_Hash, ModifiedBy) VALUES (@CompanyId, @Salt, @Hash, @UserId);

    INSERT INTO dbo.DoctorIpAccessLog (CompanyId, UserId, Event_Type) VALUES (@CompanyId, ISNULL(@UserId, 0), 'CODE_SET');
END
GO

-- 3. Lookups -------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_DoctorIp_GetSpecialities
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.SpecialityId AS Id, s.SpecialityName AS Name,
           (SELECT COUNT(*) FROM dbo.DoctorMaster d
             WHERE (d.PrimarySpecialityId = s.SpecialityId OR d.SecondarySpecialityId = s.SpecialityId)
               AND d.IsReferralDoctor = 1 AND d.IsActive = 1
               AND (@CompanyId IS NULL OR d.CompanyId = @CompanyId)) AS ReferralDoctorCount
    FROM dbo.DoctorSpecialityMaster s
    WHERE s.IsActive = 1 AND (@CompanyId IS NULL OR s.CompanyId = @CompanyId)
    ORDER BY s.SpecialityName;
END
GO

-- Referral doctors of a speciality (primary or secondary). DoctorMaster has no IsDeleted column;
-- IsActive = 1 is the "not removed" rule for doctors.
CREATE OR ALTER PROCEDURE dbo.usp_DoctorIp_GetDoctors
    @SpecialityId INT,
    @CompanyId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT d.DoctorId AS Id, ISNULL(d.NamePrefix + ' ', '') + d.FullName AS Name
    FROM dbo.DoctorMaster d
    WHERE (d.PrimarySpecialityId = @SpecialityId OR d.SecondarySpecialityId = @SpecialityId)
      AND d.IsReferralDoctor = 1 AND d.IsActive = 1
      AND (@CompanyId IS NULL OR d.CompanyId = @CompanyId)
    ORDER BY d.FullName;
END
GO

-- Tests and profiles that can carry a commission (billable, active). Pure packages have no
-- Test_ID / department / category and are not included.
CREATE OR ALTER PROCEDURE dbo.usp_DoctorIp_GetItems
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT m.Test_ID,
           m.Test_Code,
           m.Test_Name,
           CASE WHEN m.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END AS Item_Type,
           ISNULL(m.Department_ID, c.Department_ID) AS Department_ID,
           dep.DeptName AS Department_Name,
           m.Category_ID,
           c.Category_Name,
           m.SubCategory_ID AS Sub_Category_ID,
           sc.SubCategory_Name AS Sub_Category_Name,
           m.MRP
    FROM dbo.LabInvestigationMaster m
    LEFT JOIN dbo.LabTestCategoryMaster c ON c.Category_ID = m.Category_ID
    LEFT JOIN dbo.LabTestSubCategoryMaster sc ON sc.SubCategory_ID = m.SubCategory_ID
    LEFT JOIN dbo.DepartmentMaster dep ON dep.DeptId = ISNULL(m.Department_ID, c.Department_ID)
    WHERE m.IsDeleted = 0 AND m.Status = 1 AND m.Is_Billable = 1
      AND (@CompanyId IS NULL OR m.CompanyId = @CompanyId)
    ORDER BY dep.DeptName, c.Category_Name, m.Test_Name;
END
GO

-- 4. CRUD ----------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_DoctorIp_GetList
    @CompanyId INT = NULL,
    @BranchId  INT = NULL,
    @Status    BIT = NULL,
    @Search    NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT h.Doctor_IP_Hdr_ID,
           h.Doctor_ID,
           ISNULL(d.NamePrefix + ' ', '') + d.FullName AS Doctor_Name,
           h.Speciality_ID,
           s.SpecialityName AS Speciality_Name,
           h.Branch_ID,
           b.BranchName AS Branch_Name,
           h.Effective_From,
           h.Effective_To,
           h.IsActive,
           (SELECT COUNT(*) FROM dbo.Doctor_IP_Dtl x WHERE x.Doctor_IP_Hdr_ID = h.Doctor_IP_Hdr_ID) AS Item_Count,
           (SELECT CAST(AVG(x.Commission_Rate) AS DECIMAL(18,2)) FROM dbo.Doctor_IP_Dtl x WHERE x.Doctor_IP_Hdr_ID = h.Doctor_IP_Hdr_ID) AS Avg_Rate,
           h.CreatedDate,
           h.UpdatedDate
    FROM dbo.Doctor_IP_Hdr h
    JOIN dbo.DoctorMaster d ON d.DoctorId = h.Doctor_ID
    LEFT JOIN dbo.DoctorSpecialityMaster s ON s.SpecialityId = h.Speciality_ID
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = h.Branch_ID
    WHERE h.IsDeleted = 0
      AND (@CompanyId IS NULL OR h.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR h.Branch_ID = @BranchId)
      AND (@Status IS NULL OR h.IsActive = @Status)
      AND (@Search IS NULL OR LTRIM(RTRIM(@Search)) = ''
           OR d.FullName LIKE '%' + LTRIM(RTRIM(@Search)) + '%'
           OR s.SpecialityName LIKE '%' + LTRIM(RTRIM(@Search)) + '%')
    ORDER BY d.FullName, h.Effective_From DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_DoctorIp_GetById
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT h.Doctor_IP_Hdr_ID, h.CompanyId, h.Doctor_ID,
           ISNULL(d.NamePrefix + ' ', '') + d.FullName AS Doctor_Name,
           h.Speciality_ID, s.SpecialityName AS Speciality_Name,
           h.Branch_ID, b.BranchName AS Branch_Name,
           h.Effective_From, h.Effective_To, h.IsActive,
           h.Created_By, h.CreatedDate, h.Updated_By, h.UpdatedDate
    FROM dbo.Doctor_IP_Hdr h
    JOIN dbo.DoctorMaster d ON d.DoctorId = h.Doctor_ID
    LEFT JOIN dbo.DoctorSpecialityMaster s ON s.SpecialityId = h.Speciality_ID
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = h.Branch_ID
    WHERE h.Doctor_IP_Hdr_ID = @Id AND h.IsDeleted = 0;

    SELECT x.Doctor_IP_Dtl_ID, x.Doctor_IP_Hdr_ID, x.Test_ID,
           m.Test_Code, m.Test_Name,
           CASE WHEN m.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END AS Item_Type,
           x.Department_ID, dep.DeptName AS Department_Name,
           x.Category_ID, c.Category_Name,
           x.Sub_Category_ID, sc.SubCategory_Name AS Sub_Category_Name,
           m.MRP, x.Commission_Rate
    FROM dbo.Doctor_IP_Dtl x
    JOIN dbo.LabInvestigationMaster m ON m.Test_ID = x.Test_ID
    LEFT JOIN dbo.DepartmentMaster dep ON dep.DeptId = x.Department_ID
    LEFT JOIN dbo.LabTestCategoryMaster c ON c.Category_ID = x.Category_ID
    LEFT JOIN dbo.LabTestSubCategoryMaster sc ON sc.SubCategory_ID = x.Sub_Category_ID
    WHERE x.Doctor_IP_Hdr_ID = @Id
    ORDER BY dep.DeptName, c.Category_Name, m.Test_Name;
END
GO

-- Header + details in one transaction. @DetailsJson: [{"Test_ID":1,"Commission_Rate":20.00}, ...]
-- Department / category / sub-category are taken from the test master, not from the client.
CREATE OR ALTER PROCEDURE dbo.usp_DoctorIp_Save
    @Id            INT = 0,
    @CompanyId     INT = 1,
    @Doctor_ID     INT,
    @Speciality_ID INT = NULL,
    @Branch_ID     INT,
    @Effective_From DATE,
    @Effective_To   DATE,
    @IsActive      BIT = 1,
    @DetailsJson   NVARCHAR(MAX),
    @UserId        INT = NULL,
    @NewId         INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @NewId = NULLIF(@Id, 0);

    IF @Effective_To < @Effective_From
    BEGIN RAISERROR('Effective To must be on or after Effective From.', 16, 1); RETURN; END

    IF NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @Doctor_ID AND IsReferralDoctor = 1 AND IsActive = 1)
    BEGIN RAISERROR('Select an active referral doctor.', 16, 1); RETURN; END

    IF @NewId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.Doctor_IP_Hdr WHERE Doctor_IP_Hdr_ID = @NewId AND IsDeleted = 0)
    BEGIN RAISERROR('Doctor IP record not found.', 16, 1); RETURN; END

    IF @IsActive = 1 AND EXISTS (
        SELECT 1 FROM dbo.Doctor_IP_Hdr
        WHERE Doctor_ID = @Doctor_ID AND Branch_ID = @Branch_ID AND IsDeleted = 0 AND IsActive = 1
          AND Doctor_IP_Hdr_ID <> ISNULL(@NewId, 0)
          AND Effective_From <= @Effective_To AND Effective_To >= @Effective_From)
    BEGIN RAISERROR('This doctor already has an active Doctor IP for this branch in an overlapping period.', 16, 1); RETURN; END

    IF @DetailsJson IS NULL OR ISJSON(@DetailsJson) = 0
    BEGIN RAISERROR('Add at least one test with a commission %%.', 16, 1); RETURN; END

    DECLARE @D TABLE (Test_ID BIGINT PRIMARY KEY, Commission_Rate DECIMAL(18,2));
    INSERT INTO @D (Test_ID, Commission_Rate)
    SELECT j.Test_ID, MAX(j.Commission_Rate)
    FROM OPENJSON(@DetailsJson) WITH (Test_ID BIGINT '$.Test_ID', Commission_Rate DECIMAL(18,2) '$.Commission_Rate') j
    WHERE j.Test_ID IS NOT NULL
    GROUP BY j.Test_ID;

    IF NOT EXISTS (SELECT 1 FROM @D)
    BEGIN RAISERROR('Add at least one test with a commission %%.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM @D WHERE Commission_Rate IS NULL OR Commission_Rate < 0 OR Commission_Rate > 100)
    BEGIN RAISERROR('Commission %% must be between 0 and 100 for every test.', 16, 1); RETURN; END

    BEGIN TRANSACTION;
    BEGIN TRY
        IF @NewId IS NULL
        BEGIN
            INSERT INTO dbo.Doctor_IP_Hdr (CompanyId, Doctor_ID, Speciality_ID, Branch_ID, Effective_From, Effective_To, IsActive, Created_By)
            VALUES (@CompanyId, @Doctor_ID, @Speciality_ID, @Branch_ID, @Effective_From, @Effective_To, ISNULL(@IsActive, 1), @UserId);
            SET @NewId = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            UPDATE dbo.Doctor_IP_Hdr
               SET Doctor_ID = @Doctor_ID, Speciality_ID = @Speciality_ID, Branch_ID = @Branch_ID,
                   Effective_From = @Effective_From, Effective_To = @Effective_To, IsActive = ISNULL(@IsActive, 1),
                   Updated_By = @UserId, UpdatedDate = GETDATE()
             WHERE Doctor_IP_Hdr_ID = @NewId;
            DELETE FROM dbo.Doctor_IP_Dtl WHERE Doctor_IP_Hdr_ID = @NewId;
        END

        INSERT INTO dbo.Doctor_IP_Dtl (Doctor_IP_Hdr_ID, Department_ID, Category_ID, Sub_Category_ID, Test_ID, Commission_Rate)
        SELECT @NewId, ISNULL(m.Department_ID, c.Department_ID), m.Category_ID, m.SubCategory_ID, d.Test_ID, d.Commission_Rate
        FROM @D d
        JOIN dbo.LabInvestigationMaster m ON m.Test_ID = d.Test_ID AND m.IsDeleted = 0
        LEFT JOIN dbo.LabTestCategoryMaster c ON c.Category_ID = m.Category_ID;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_DoctorIp_ToggleStatus
    @Id INT, @IsActive BIT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Doctor INT, @Branch INT, @From DATE, @To DATE;
    SELECT @Doctor = Doctor_ID, @Branch = Branch_ID, @From = Effective_From, @To = Effective_To
    FROM dbo.Doctor_IP_Hdr WHERE Doctor_IP_Hdr_ID = @Id AND IsDeleted = 0;
    IF @Doctor IS NULL BEGIN RAISERROR('Doctor IP record not found.', 16, 1); RETURN; END

    IF @IsActive = 1 AND EXISTS (
        SELECT 1 FROM dbo.Doctor_IP_Hdr
        WHERE Doctor_ID = @Doctor AND Branch_ID = @Branch AND IsDeleted = 0 AND IsActive = 1
          AND Doctor_IP_Hdr_ID <> @Id AND Effective_From <= @To AND Effective_To >= @From)
    BEGIN RAISERROR('Cannot activate: another active Doctor IP for this doctor and branch overlaps this period.', 16, 1); RETURN; END

    UPDATE dbo.Doctor_IP_Hdr SET IsActive = @IsActive, Updated_By = @UserId, UpdatedDate = GETDATE() WHERE Doctor_IP_Hdr_ID = @Id;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_DoctorIp_Delete
    @Id INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.Doctor_IP_Hdr WHERE Doctor_IP_Hdr_ID = @Id AND IsDeleted = 0)
    BEGIN RAISERROR('Doctor IP record not found or already deleted.', 16, 1); RETURN; END
    UPDATE dbo.Doctor_IP_Hdr SET IsDeleted = 1, IsActive = 0, Updated_By = @UserId, UpdatedDate = GETDATE() WHERE Doctor_IP_Hdr_ID = @Id;
END
GO

-- 5. Authorization: hidden page under IPD Master ------------------------------
DECLARE @co INT, @menu INT, @page INT, @ctl INT;
DECLARE @Controls TABLE (Code VARCHAR(30), Title NVARCHAR(150), Sort INT);
INSERT INTO @Controls VALUES ('ADD', 'Add Doctor IP', 20), ('EDIT', 'Edit Doctor IP', 30), ('DETAILS', 'View details', 35),
                             ('STATUS', 'Activate / Deactivate', 50), ('DELETE', 'Delete Doctor IP', 40);
DECLARE @Map TABLE (Method VARCHAR(10), Action NVARCHAR(150), Control VARCHAR(30));
INSERT INTO @Map VALUES
 ('GET', 'Index', 'VIEW'), ('GET', 'Unlock', 'VIEW'), ('POST', 'Unlock', 'VIEW'), ('POST', 'Lock', 'VIEW'),
 ('GET', 'SetAccessCode', 'VIEW'), ('POST', 'SetAccessCode', 'VIEW'),
 ('GET', 'GetDoctors', 'VIEW'), ('GET', 'GetItems', 'VIEW'), ('GET', 'GetCategories', 'VIEW'), ('GET', 'GetSubCategories', 'VIEW'),
 ('GET', 'GetCopySource', 'VIEW'),
 ('GET', 'Create', 'ADD'), ('POST', 'Create', 'ADD'), ('GET', 'Copy', 'ADD'),
 ('GET', 'Edit', 'EDIT'), ('POST', 'Edit', 'EDIT'),
 ('GET', 'Details', 'DETAILS'),
 ('POST', 'ToggleStatus', 'STATUS'),
 ('POST', 'Delete', 'DELETE');

DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'MASTER.IPD_MASTER' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'MASTER.DOCTORIP', @Title = N'Doctor IP',
             @Controller = N'DoctorIp', @Action = N'Index', @Show_In_Menu = 0, @Sort_Order = 900, @Icon = N'bi bi-shield-lock me-2', @Page_ID = @page OUTPUT;

        DECLARE @c VARCHAR(30), @t NVARCHAR(150), @s INT;
        DECLARE ctl CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Sort FROM @Controls;
        OPEN ctl; FETCH NEXT FROM ctl INTO @c, @t, @s;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @c, @Title = @t, @Sort_Order = @s, @Control_ID = @ctl OUTPUT;
            FETCH NEXT FROM ctl INTO @c, @t, @s;
        END
        CLOSE ctl; DEALLOCATE ctl;

        DECLARE @m VARCHAR(10), @a NVARCHAR(150), @k VARCHAR(30);
        DECLARE mp CURSOR LOCAL FAST_FORWARD FOR SELECT Method, Action, Control FROM @Map;
        OPEN mp; FETCH NEXT FROM mp INTO @m, @a, @k;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @ctl = NULL;
            SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = @k;
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = @m,
                 @Controller = N'DoctorIp', @Action = @a, @Source = 'SEED';
            FETCH NEXT FROM mp INTO @m, @a, @k;
        END
        CLOSE mp; DEALLOCATE mp;
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

-- 6. Initial access code -------------------------------------------------------
-- Not seeded here on purpose: a code committed to source control would not be confidential.
-- A Super Admin sets it from the Doctor IP unlock screen, or run once per company:
--   EXEC dbo.usp_DoctorIp_SetAccessCode @CompanyId = 1, @NewCode = N'<new code>';

PRINT 'Script 2176 applied: Doctor IP master.';
GO
