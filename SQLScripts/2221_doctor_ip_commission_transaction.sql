-- ============================================================================
-- Migration: 2221_doctor_ip_commission_transaction.sql
-- Description: Doctor IP commission transaction - computes referral doctor commission
--   from lab orders using the rates in Doctor_IP_Hdr / Doctor_IP_Dtl.
--   * LabOrderItem.is_IPGenerated (added if missing): NULL / 0 = pending, 1 = commission computed.
--   * Doctor_IP_Commission_Hdr / Doctor_IP_Commission_Dtl - one header per doctor per run,
--     one detail row per lab order item (order id, test, billed amount, rate, commission).
--   * Doctor = LabOrder.RefDoctorId (DoctorMaster), basis = LabOrderItem.Price.
--     LabOrderItem.Type 'I' matches Doctor IP Test / Profile rows, 'P' matches Package rows
--     (InvestigationId is then a package id, which overlaps with test ids).
--   * SPs: GetPending, Calculate, GetList, GetDetail, GetDueSchedules.
--   * Authorization: page MASTER.DOCTORIP_COMMISSION under MASTER.IPD_MASTER, Show_In_Menu = 0.
--   Run after 2220 (Doctor IP packages).
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- 1. Flag on LabOrderItem ----------------------------------------------------
IF COL_LENGTH('dbo.LabOrderItem', 'is_IPGenerated') IS NULL
    ALTER TABLE dbo.LabOrderItem ADD is_IPGenerated BIT NULL;
GO

-- 2. Transaction tables --------------------------------------------------------
IF OBJECT_ID('dbo.Doctor_IP_Commission_Hdr', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Doctor_IP_Commission_Hdr
    (
        Commission_Hdr_ID      BIGINT IDENTITY(1,1) PRIMARY KEY,
        CompanyId              INT NOT NULL DEFAULT 1,
        Doctor_ID              INT NOT NULL,
        Branch_ID              INT NOT NULL,
        Doctor_IP_Hdr_ID       INT NOT NULL REFERENCES dbo.Doctor_IP_Hdr (Doctor_IP_Hdr_ID),
        Frequency_Of_Disbursal VARCHAR(20) NULL,
        Period_From            DATE NOT NULL,
        Period_To              DATE NOT NULL,
        Total_Orders           INT NOT NULL DEFAULT 0,
        Total_Items            INT NOT NULL DEFAULT 0,
        Total_Billed_Amount    DECIMAL(18,2) NOT NULL DEFAULT 0,
        Total_Commission       DECIMAL(18,2) NOT NULL DEFAULT 0,
        Computed_Date          DATETIME NOT NULL DEFAULT GETDATE(),
        Computed_By            INT NULL,
        Source                 VARCHAR(10) NOT NULL DEFAULT 'MANUAL',
        IsDeleted              BIT NOT NULL DEFAULT 0
    );
    CREATE INDEX IX_Doctor_IP_Commission_Hdr_Doctor ON dbo.Doctor_IP_Commission_Hdr (Doctor_ID, Branch_ID, IsDeleted);
END
GO

IF OBJECT_ID('dbo.Doctor_IP_Commission_Dtl', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Doctor_IP_Commission_Dtl
    (
        Commission_Dtl_ID BIGINT IDENTITY(1,1) PRIMARY KEY,
        Commission_Hdr_ID BIGINT NOT NULL REFERENCES dbo.Doctor_IP_Commission_Hdr (Commission_Hdr_ID),
        LabOrderId        INT NOT NULL,
        LabOrderItemId    INT NOT NULL,
        Order_Date        DATETIME NOT NULL,
        PatientId         INT NOT NULL,
        Item_Type         VARCHAR(10) NOT NULL DEFAULT 'Test',
        Test_ID           BIGINT NOT NULL,
        Billed_Amount     DECIMAL(18,2) NOT NULL,
        Commission_Rate   DECIMAL(18,2) NOT NULL,
        Commission_Amount DECIMAL(18,2) NOT NULL
    );
    CREATE INDEX IX_Doctor_IP_Commission_Dtl_Hdr ON dbo.Doctor_IP_Commission_Dtl (Commission_Hdr_ID);
    CREATE INDEX IX_Doctor_IP_Commission_Dtl_Order ON dbo.Doctor_IP_Commission_Dtl (LabOrderId);
    -- An order item can earn commission only once.
    CREATE UNIQUE INDEX UX_Doctor_IP_Commission_Dtl_Item ON dbo.Doctor_IP_Commission_Dtl (LabOrderItemId);
END
GO

IF COL_LENGTH('dbo.Doctor_IP_Commission_Dtl', 'Item_Type') IS NULL
    ALTER TABLE dbo.Doctor_IP_Commission_Dtl ADD Item_Type VARCHAR(10) NOT NULL DEFAULT 'Test';
GO

-- 3. Eligible order items (shared by GetPending and Calculate) -----------------
CREATE OR ALTER FUNCTION dbo.fn_DoctorIpCommission_Eligible
(
    @BranchId INT, @DoctorId INT, @FromDate DATE, @ToDate DATE, @CompanyId INT
)
RETURNS TABLE
AS
RETURN
    SELECT h.Doctor_IP_Hdr_ID, h.CompanyId, h.Doctor_ID, h.Branch_ID, h.Frequency_Of_Disbursal,
           lo.LabOrderId, lo.OrderDate AS Order_Date, lo.PatientId,
           loi.LabOrderItemId, d.Item_Type, CAST(loi.InvestigationId AS BIGINT) AS Test_ID,
           CAST(loi.Price AS DECIMAL(18,2)) AS Billed_Amount,
           d.Commission_Rate,
           CAST(ROUND(loi.Price * d.Commission_Rate / 100.0, 2) AS DECIMAL(18,2)) AS Commission_Amount
    FROM dbo.LabOrderItem loi
    JOIN dbo.LabOrder lo ON lo.LabOrderId = loi.LabOrderId
    JOIN dbo.Doctor_IP_Hdr h ON h.Doctor_ID = lo.RefDoctorId AND h.Branch_ID = lo.BranchId
                            AND h.IsActive = 1 AND h.IsDeleted = 0
                            AND CAST(lo.OrderDate AS DATE) BETWEEN h.Effective_From AND h.Effective_To
    JOIN dbo.Doctor_IP_Dtl d ON d.Doctor_IP_Hdr_ID = h.Doctor_IP_Hdr_ID AND d.Test_ID = loi.InvestigationId
                            AND ((loi.Type = 'P' AND d.Item_Type = 'Package') OR (loi.Type = 'I' AND d.Item_Type <> 'Package'))
    WHERE ISNULL(loi.is_IPGenerated, 0) = 0
      AND loi.IsActive = 1
      AND lo.IsActive = 1
      AND lo.BranchId = @BranchId
      AND (@DoctorId IS NULL OR lo.RefDoctorId = @DoctorId)
      AND (@CompanyId IS NULL OR h.CompanyId = @CompanyId)
      AND (@FromDate IS NULL OR CAST(lo.OrderDate AS DATE) >= @FromDate)
      AND (@ToDate IS NULL OR CAST(lo.OrderDate AS DATE) <= @ToDate);
GO

-- 4. Procedures ----------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_DoctorIpCommission_GetPending
    @BranchId INT, @DoctorId INT = NULL, @FromDate DATE = NULL, @ToDate DATE = NULL, @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT e.Doctor_ID, dm.FullName AS Doctor_Name, MAX(e.Frequency_Of_Disbursal) AS Frequency_Of_Disbursal,
           COUNT(DISTINCT e.LabOrderId) AS Pending_Orders, COUNT(*) AS Pending_Items,
           SUM(e.Billed_Amount) AS Pending_Amount, SUM(e.Commission_Amount) AS Estimated_Commission,
           MIN(e.Order_Date) AS First_Order_Date, MAX(e.Order_Date) AS Last_Order_Date
    FROM dbo.fn_DoctorIpCommission_Eligible(@BranchId, @DoctorId, @FromDate, @ToDate, @CompanyId) e
    JOIN dbo.DoctorMaster dm ON dm.DoctorId = e.Doctor_ID
    GROUP BY e.Doctor_ID, dm.FullName
    ORDER BY dm.FullName;
END
GO

-- Computes commission for every pending order item in the period. Items already flagged
-- is_IPGenerated = 1 are ignored, so running it again for the same period is safe.
CREATE OR ALTER PROCEDURE dbo.usp_DoctorIpCommission_Calculate
    @BranchId INT, @DoctorId INT = NULL, @FromDate DATE, @ToDate DATE,
    @CompanyId INT = NULL, @UserId INT = NULL, @Source VARCHAR(10) = 'MANUAL'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @ToDate < @FromDate
    BEGIN
        RAISERROR('To Date must be on or after From Date.', 16, 1);
        RETURN;
    END

    CREATE TABLE #Eligible
    (
        Doctor_IP_Hdr_ID INT, CompanyId INT, Doctor_ID INT, Branch_ID INT, Frequency_Of_Disbursal VARCHAR(20),
        LabOrderId INT, Order_Date DATETIME, PatientId INT, LabOrderItemId INT PRIMARY KEY, Item_Type VARCHAR(10), Test_ID BIGINT,
        Billed_Amount DECIMAL(18,2), Commission_Rate DECIMAL(18,2), Commission_Amount DECIMAL(18,2)
    );
    DECLARE @Hdr TABLE (Commission_Hdr_ID BIGINT, Doctor_IP_Hdr_ID INT);

    BEGIN TRANSACTION;

    -- Claim the pending items first, so a manual run and the scheduled run cannot both take them.
    UPDATE loi SET is_IPGenerated = 1
    OUTPUT e.Doctor_IP_Hdr_ID, e.CompanyId, e.Doctor_ID, e.Branch_ID, e.Frequency_Of_Disbursal, e.LabOrderId, e.Order_Date,
           e.PatientId, e.LabOrderItemId, e.Item_Type, e.Test_ID, e.Billed_Amount, e.Commission_Rate, e.Commission_Amount
    INTO #Eligible
    FROM dbo.LabOrderItem loi
    JOIN dbo.fn_DoctorIpCommission_Eligible(@BranchId, @DoctorId, @FromDate, @ToDate, @CompanyId) e ON e.LabOrderItemId = loi.LabOrderItemId
    WHERE ISNULL(loi.is_IPGenerated, 0) = 0;

    INSERT INTO dbo.Doctor_IP_Commission_Hdr
        (CompanyId, Doctor_ID, Branch_ID, Doctor_IP_Hdr_ID, Frequency_Of_Disbursal, Period_From, Period_To,
         Total_Orders, Total_Items, Total_Billed_Amount, Total_Commission, Computed_By, Source)
    OUTPUT inserted.Commission_Hdr_ID, inserted.Doctor_IP_Hdr_ID INTO @Hdr
    SELECT CompanyId, Doctor_ID, Branch_ID, Doctor_IP_Hdr_ID, MAX(Frequency_Of_Disbursal), @FromDate, @ToDate,
           COUNT(DISTINCT LabOrderId), COUNT(*), SUM(Billed_Amount), SUM(Commission_Amount), @UserId, @Source
    FROM #Eligible
    GROUP BY CompanyId, Doctor_ID, Branch_ID, Doctor_IP_Hdr_ID;

    INSERT INTO dbo.Doctor_IP_Commission_Dtl
        (Commission_Hdr_ID, LabOrderId, LabOrderItemId, Order_Date, PatientId, Item_Type, Test_ID, Billed_Amount, Commission_Rate, Commission_Amount)
    SELECT x.Commission_Hdr_ID, e.LabOrderId, e.LabOrderItemId, e.Order_Date, e.PatientId, e.Item_Type, e.Test_ID,
           e.Billed_Amount, e.Commission_Rate, e.Commission_Amount
    FROM #Eligible e
    JOIN @Hdr x ON x.Doctor_IP_Hdr_ID = e.Doctor_IP_Hdr_ID;

    COMMIT TRANSACTION;

    SELECT e.Doctor_ID, dm.FullName AS Doctor_Name, COUNT(DISTINCT e.LabOrderId) AS Orders_Computed,
           COUNT(*) AS Items_Computed, SUM(e.Commission_Amount) AS Total_Commission
    FROM #Eligible e
    JOIN dbo.DoctorMaster dm ON dm.DoctorId = e.Doctor_ID
    GROUP BY e.Doctor_ID, dm.FullName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_DoctorIpCommission_GetList
    @BranchId INT = NULL, @DoctorId INT = NULL, @FromDate DATE = NULL, @ToDate DATE = NULL, @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ch.Commission_Hdr_ID, ch.Doctor_ID, dm.FullName AS Doctor_Name, ch.Branch_ID, b.BranchName AS Branch_Name,
           ch.Doctor_IP_Hdr_ID, ch.Frequency_Of_Disbursal, ch.Period_From, ch.Period_To,
           ch.Total_Orders, ch.Total_Items, ch.Total_Billed_Amount, ch.Total_Commission,
           ch.Computed_Date, ch.Source, ISNULL(u.FullName, 'System') AS Computed_By_Name
    FROM dbo.Doctor_IP_Commission_Hdr ch
    JOIN dbo.DoctorMaster dm ON dm.DoctorId = ch.Doctor_ID
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = ch.Branch_ID
    LEFT JOIN dbo.Users u ON u.Id = ch.Computed_By
    WHERE ch.IsDeleted = 0
      AND (@BranchId IS NULL OR ch.Branch_ID = @BranchId)
      AND (@DoctorId IS NULL OR ch.Doctor_ID = @DoctorId)
      AND (@CompanyId IS NULL OR ch.CompanyId = @CompanyId)
      AND (@FromDate IS NULL OR ch.Period_To >= @FromDate)
      AND (@ToDate IS NULL OR ch.Period_From <= @ToDate)
    ORDER BY ch.Computed_Date DESC, ch.Commission_Hdr_ID DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_DoctorIpCommission_GetDetail
    @CommissionHdrId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ch.Commission_Hdr_ID, ch.Doctor_ID, dm.FullName AS Doctor_Name, ch.Branch_ID, b.BranchName AS Branch_Name,
           ch.Doctor_IP_Hdr_ID, ch.Frequency_Of_Disbursal, ch.Period_From, ch.Period_To,
           ch.Total_Orders, ch.Total_Items, ch.Total_Billed_Amount, ch.Total_Commission,
           ch.Computed_Date, ch.Source, ISNULL(u.FullName, 'System') AS Computed_By_Name
    FROM dbo.Doctor_IP_Commission_Hdr ch
    JOIN dbo.DoctorMaster dm ON dm.DoctorId = ch.Doctor_ID
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = ch.Branch_ID
    LEFT JOIN dbo.Users u ON u.Id = ch.Computed_By
    WHERE ch.Commission_Hdr_ID = @CommissionHdrId AND ch.IsDeleted = 0;

    SELECT cd.Commission_Dtl_ID, cd.LabOrderId, lo.BillNo, cd.Order_Date,
           LTRIM(RTRIM(ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS Patient_Name,
           cd.Item_Type, cd.Test_ID, ISNULL(m.Test_Code, ph.Profile_Code) AS Test_Code,
           ISNULL(ISNULL(m.Test_Name, ph.Profile_Name), 'Unknown') AS Test_Name,
           cd.Billed_Amount, cd.Commission_Rate, cd.Commission_Amount
    FROM dbo.Doctor_IP_Commission_Dtl cd
    JOIN dbo.LabOrder lo ON lo.LabOrderId = cd.LabOrderId
    LEFT JOIN dbo.PatientMaster p ON p.PatientId = cd.PatientId
    LEFT JOIN dbo.LabInvestigationMaster m ON cd.Item_Type <> 'Package' AND m.Test_ID = cd.Test_ID
    LEFT JOIN dbo.LabInvestigationProfileHeader ph ON cd.Item_Type = 'Package' AND ph.Profile_ID = cd.Test_ID
    WHERE cd.Commission_Hdr_ID = @CommissionHdrId
    ORDER BY cd.Order_Date, cd.LabOrderId, ISNULL(m.Test_Name, ph.Profile_Name);
END
GO

-- Doctor IP set-ups whose disbursal period closed yesterday, with that period.
--   Daily: every day (yesterday)            Weekly: Monday (previous Monday - Sunday)
--   Monthly: 1st (previous month)           Quarterly: 1st of Jan / Apr / Jul / Oct (previous quarter)
--   Annually: 1st January (previous year)
CREATE OR ALTER PROCEDURE dbo.usp_DoctorIpCommission_GetDueSchedules
    @Today DATE, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @MonthStart DATE = DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1);
    DECLARE @IsMonday BIT = CASE WHEN DATEDIFF(DAY, '19000101', @Today) % 7 = 0 THEN 1 ELSE 0 END; -- 1900-01-01 was a Monday

    SELECT h.Doctor_IP_Hdr_ID, h.CompanyId, h.Doctor_ID, h.Branch_ID, h.Frequency_Of_Disbursal, p.Period_From, p.Period_To
    FROM dbo.Doctor_IP_Hdr h
    CROSS APPLY (SELECT CASE h.Frequency_Of_Disbursal
                            WHEN 'Daily'     THEN DATEADD(DAY, -1, @Today)
                            WHEN 'Weekly'    THEN DATEADD(DAY, -7, @Today)
                            WHEN 'Monthly'   THEN DATEADD(MONTH, -1, @MonthStart)
                            WHEN 'Quarterly' THEN DATEADD(MONTH, -3, @MonthStart)
                            WHEN 'Annually'  THEN DATEADD(YEAR, -1, @MonthStart)
                        END AS Period_From,
                        DATEADD(DAY, -1, @Today) AS Period_To) p
    WHERE h.IsActive = 1 AND h.IsDeleted = 0
      AND (@BranchId IS NULL OR h.Branch_ID = @BranchId)
      AND h.Effective_From <= p.Period_To AND h.Effective_To >= p.Period_From
      AND (   h.Frequency_Of_Disbursal = 'Daily'
           OR (h.Frequency_Of_Disbursal = 'Weekly'    AND @IsMonday = 1)
           OR (h.Frequency_Of_Disbursal = 'Monthly'   AND DAY(@Today) = 1)
           OR (h.Frequency_Of_Disbursal = 'Quarterly' AND DAY(@Today) = 1 AND MONTH(@Today) IN (1, 4, 7, 10))
           OR (h.Frequency_Of_Disbursal = 'Annually'  AND DAY(@Today) = 1 AND MONTH(@Today) = 1));
END
GO

-- 5. Authorization: hidden page under IPD Master --------------------------------
DECLARE @co INT, @menu INT, @page INT, @ctl INT;
DECLARE @Controls TABLE (Code VARCHAR(30), Title NVARCHAR(150), Sort INT);
INSERT INTO @Controls VALUES ('CALCULATE', 'Calculate commission', 20), ('DETAILS', 'View details', 35);
DECLARE @Map TABLE (Method VARCHAR(10), Action NVARCHAR(150), Control VARCHAR(30));
INSERT INTO @Map VALUES ('GET', 'Index', 'VIEW'), ('POST', 'Calculate', 'CALCULATE'), ('GET', 'Details', 'DETAILS');

DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'MASTER.IPD_MASTER' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'MASTER.DOCTORIP_COMMISSION', @Title = N'Doctor IP Commission',
             @Controller = N'DoctorIpCommission', @Action = N'Index', @Show_In_Menu = 0, @Sort_Order = 910, @Icon = N'bi bi-calculator me-2', @Page_ID = @page OUTPUT;

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
                 @Controller = N'DoctorIpCommission', @Action = @a, @Source = 'SEED';
            FETCH NEXT FROM mp INTO @m, @a, @k;
        END
        CLOSE mp; DEALLOCATE mp;
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO
