-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2450  LAB > B2C Bill Estimate (billing simulator)
--   An estimate of a B2C LAB bill: same tests / profiles / packages (the branch's B2C rate list, fn_LabBookableItems) and
--   misc charges (LabMiscChargeMaster, GST on top after discount) as LAB > B2C Booking, with the same discounts:
--     * overall % or ₹ on the discountable amount (tests the B2C rate card allows a discount on + discountable misc
--       charges), spread over those lines in proportion to price, the last line taking the remainder;
--     * department-wise: a % or ₹ per department head (and one "Packages" head), only on discountable tests
--       (the LabDepartmentDiscount rules of the B2C bill).
--   Membership card (as the B2C bill, SQLScripts/2241): a registered patient with a live card gets the plan's benefits
--   (rules on discountable tests, Free Home Collection), worked out by the existing usp_Membership_LabBenefits, which the
--   API calls and passes in as @MemberDisc. A benefit on tests blocks a manual discount; lines with a benefit are left out
--   of the manual-discount base. Points are not redeemed on an estimate (that needs the card holder's OTP at billing).
--   Every price and discount is worked out here (usp_LabEstimate_Compute) - the screen only sends item ids, quantities
--   and the discount asked for. No bill, payment, sample or ledger entry is made; existing flows are not touched.
--   Tables LabEstimate, LabEstimateItem, LabEstimateDeptDiscount. Number EST/<branch code>/<FY>/<00001>.
--   PublicToken: the link sent to the patient (print / PDF without sign-in). Page LAB.LABESTIMATE
--   (VIEW, ADD, DISCOUNT, SEND, CANCEL). A test already inside an added profile / package is refused (as B2C Booking).
--   No role grants. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO
IF OBJECT_ID('dbo.LabEstimate') IS NULL
CREATE TABLE dbo.LabEstimate (
    EstimateId      INT IDENTITY(1,1) CONSTRAINT PK_LabEstimate PRIMARY KEY,
    CompanyId       INT NOT NULL,
    BranchId        INT NOT NULL,
    EstimateNo      VARCHAR(40) NOT NULL,
    FinancialYear   VARCHAR(7) NOT NULL,
    SeqNo           INT NOT NULL,
    EstimateDate    DATETIME NOT NULL CONSTRAINT DF_LabEstimate_Date DEFAULT (GETDATE()),
    ValidTill       DATE NOT NULL,
    PatientId       INT NULL CONSTRAINT FK_LabEstimate_Patient REFERENCES dbo.PatientMaster (PatientId),
    Salutation      NVARCHAR(20) NULL,
    PatientName     NVARCHAR(200) NOT NULL,
    Gender          NVARCHAR(20) NULL,
    AgeYears        INT NULL,
    Mobile          VARCHAR(15) NOT NULL,
    EmailId         NVARCHAR(150) NULL,
    RefDoctorId     INT NULL,
    RefDoctorName   NVARCHAR(200) NULL,
    GrossAmount     DECIMAL(18,2) NOT NULL,
    DiscountType    CHAR(1) NULL CONSTRAINT CK_LabEstimate_DiscType CHECK (DiscountType IN ('P','F','D')),
    DiscountValue   DECIMAL(18,2) NOT NULL CONSTRAINT DF_LabEstimate_DiscValue DEFAULT (0),
    DiscountAmount  DECIMAL(18,2) NOT NULL CONSTRAINT DF_LabEstimate_DiscAmt DEFAULT (0),
    MembershipCardNo NVARCHAR(30) NULL,
    MembershipPlan  NVARCHAR(150) NULL,
    MembershipDiscount DECIMAL(18,2) NOT NULL CONSTRAINT DF_LabEstimate_MemDisc DEFAULT (0),
    GstAmount       DECIMAL(18,2) NOT NULL CONSTRAINT DF_LabEstimate_Gst DEFAULT (0),
    NetAmount       DECIMAL(18,2) NOT NULL,
    Remarks         NVARCHAR(500) NULL,
    Status          VARCHAR(10) NOT NULL CONSTRAINT DF_LabEstimate_Status DEFAULT ('ACTIVE') CONSTRAINT CK_LabEstimate_Status CHECK (Status IN ('ACTIVE','CANCELLED')),
    PublicToken     UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_LabEstimate_Token DEFAULT (NEWID()),
    SentCount       INT NOT NULL CONSTRAINT DF_LabEstimate_Sent DEFAULT (0),
    LastSentTo      VARCHAR(15) NULL,
    LastSentDate    DATETIME NULL,
    CreatedBy       INT NULL, CreatedDate DATETIME NOT NULL CONSTRAINT DF_LabEstimate_Created DEFAULT (GETDATE()),
    CancelledBy     INT NULL, CancelledDate DATETIME NULL, CancelReason NVARCHAR(250) NULL,
    CONSTRAINT UX_LabEstimate_No UNIQUE (EstimateNo),
    CONSTRAINT UX_LabEstimate_Seq UNIQUE (BranchId, FinancialYear, SeqNo)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_LabEstimate_Token' AND object_id = OBJECT_ID('dbo.LabEstimate'))
    CREATE UNIQUE INDEX UX_LabEstimate_Token ON dbo.LabEstimate (PublicToken);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LabEstimate_Branch' AND object_id = OBJECT_ID('dbo.LabEstimate'))
    CREATE INDEX IX_LabEstimate_Branch ON dbo.LabEstimate (BranchId, EstimateDate);
GO
IF OBJECT_ID('dbo.LabEstimateItem') IS NULL
CREATE TABLE dbo.LabEstimateItem (
    EstimateItemId  INT IDENTITY(1,1) CONSTRAINT PK_LabEstimateItem PRIMARY KEY,
    EstimateId      INT NOT NULL CONSTRAINT FK_LabEstimateItem_Estimate REFERENCES dbo.LabEstimate (EstimateId),
    LineSeq          INT NOT NULL,
    ItemKind        CHAR(1) NOT NULL CONSTRAINT CK_LabEstimateItem_Kind CHECK (ItemKind IN ('T','R','P','M')),   -- Test, pRofile, Package, Misc
    ItemId          INT NOT NULL,
    ItemCode        NVARCHAR(50) NULL,
    ItemName        NVARCHAR(250) NOT NULL,
    GroupKey        VARCHAR(20) NULL,
    GroupName       NVARCHAR(150) NULL,
    SampleType      NVARCHAR(100) NULL,
    TatHours        DECIMAL(9,2) NULL,
    Qty             INT NOT NULL,
    Rate            DECIMAL(18,2) NOT NULL,
    Amount          DECIMAL(18,2) NOT NULL,
    DiscountAllowed BIT NOT NULL,
    DiscountAmount  DECIMAL(18,2) NOT NULL,
    MemberDiscount  DECIMAL(18,2) NOT NULL CONSTRAINT DF_LabEstimateItem_Mem DEFAULT (0),
    MemberRule      NVARCHAR(200) NULL,
    NetAmount       DECIMAL(18,2) NOT NULL,
    GstPercent      DECIMAL(9,2) NOT NULL,
    GstAmount       DECIMAL(18,2) NOT NULL,
    LineTotal       DECIMAL(18,2) NOT NULL
);
GO
IF OBJECT_ID('dbo.LabEstimateDeptDiscount') IS NULL
CREATE TABLE dbo.LabEstimateDeptDiscount (
    EstimateId      INT NOT NULL CONSTRAINT FK_LabEstimateDept_Estimate REFERENCES dbo.LabEstimate (EstimateId),
    GroupKey        VARCHAR(20) NOT NULL,
    GroupName       NVARCHAR(150) NOT NULL,
    DiscType        CHAR(1) NOT NULL,
    DiscValue       DECIMAL(18,2) NOT NULL,
    DiscAmount      DECIMAL(18,2) NOT NULL,
    CONSTRAINT PK_LabEstimateDeptDiscount PRIMARY KEY (EstimateId, GroupKey)
);
GO

-- ── tests inside a profile / package (the B2C Booking add-test checks) ─────────────────────────────────────────
-- fn_LabEstimate_Includes: every test inside a profile (Is_Profile_Test -> profile header Profile_Type 1, by Test_ID or name,
-- as B2C Booking's GetProfileDetails) or a package (Profile_Type 2), nested profiles included.
CREATE OR ALTER FUNCTION dbo.fn_LabEstimate_Includes (@Kind CHAR(1), @Id INT)   -- T = test / profile (Test_ID), P = package (Profile_ID)
RETURNS TABLE
AS RETURN
WITH root AS (
    SELECT h.Profile_ID FROM dbo.LabInvestigationProfileHeader h
    WHERE @Kind = 'P' AND h.Profile_ID = @Id AND h.IsDeleted = 0 AND h.Profile_Type = 2
    UNION
    SELECT h.Profile_ID FROM dbo.LabInvestigationMaster t
    JOIN dbo.LabInvestigationProfileHeader h ON (h.Test_ID = t.Test_ID OR h.Profile_Name = t.Test_Name) AND h.Profile_Type = 1 AND h.IsDeleted = 0
    WHERE @Kind = 'T' AND t.Test_ID = @Id AND ISNULL(t.Is_Profile_Test, 0) = 1),
tree AS (
    SELECT d.Test_ID, CAST(1 AS INT) AS Lvl FROM root r JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = r.Profile_ID AND d.IsDeleted = 0
    UNION ALL
    SELECT d.Test_ID, tr.Lvl + 1 FROM tree tr
    JOIN dbo.LabInvestigationMaster t ON t.Test_ID = tr.Test_ID AND ISNULL(t.Is_Profile_Test, 0) = 1
    JOIN dbo.LabInvestigationProfileHeader h ON (h.Test_ID = t.Test_ID OR h.Profile_Name = t.Test_Name) AND h.Profile_Type = 1 AND h.IsDeleted = 0
    JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = h.Profile_ID AND d.IsDeleted = 0
    WHERE tr.Lvl < 5 AND d.Test_ID <> tr.Test_ID)
SELECT DISTINCT tr.Test_ID AS TestId, t.Test_Name AS TestName, CAST(ISNULL(t.Is_Profile_Test, 0) AS BIT) AS IsProfile
FROM tree tr JOIN dbo.LabInvestigationMaster t ON t.Test_ID = tr.Test_ID;
GO

-- the tests inside one item, for the screen
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabEstimate_Includes @Kind CHAR(1), @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TestId, TestName, IsProfile FROM dbo.fn_LabEstimate_Includes(UPPER(@Kind), @Id) ORDER BY TestName;
END;
GO

-- ── the pricing / discount engine ─────────────────────────────────────────────────────────────────────────────
-- The caller creates #EL (lines) and #EH (department heads) and gets them filled. THROWs (50000+) with a clear message.
--   @Items    [{ "kind": "T"|"P"|"M", "id": n, "qty": n }]   T = test or profile (LabInvestigationMaster), P = package, M = misc charge
--   @DiscType NULL / 'P' / 'F' (overall) / 'D' (department-wise: @DeptDisc [{ "key": "D12"|"PKG", "type": "P"|"F", "value": n }])
CREATE OR ALTER PROCEDURE dbo.usp_LabEstimate_Compute
    @CompanyId INT, @BranchId INT, @Items NVARCHAR(MAX), @DiscType CHAR(1) = NULL, @DiscValue DECIMAL(18,2) = 0, @DeptDisc NVARCHAR(MAX) = NULL,
    @MemberDisc NVARCHAR(MAX) = NULL   -- [{ "line": LineSeq, "disc": n, "rule": "..." }] from usp_Membership_LabBenefits (the API)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @msg NVARCHAR(400);
    SET @DiscType = NULLIF(UPPER(LTRIM(RTRIM(@DiscType))), '');
    SET @DiscValue = ISNULL(@DiscValue, 0);
    IF ISJSON(ISNULL(@Items, '')) <> 1 THROW 56201, 'Add at least one test.', 1;

    DECLARE @In TABLE (Seq INT IDENTITY(1,1), Kind CHAR(1), Id INT, Qty INT);
    INSERT @In (Kind, Id, Qty)
    SELECT UPPER(LEFT(LTRIM(j.kind), 1)), j.id, ISNULL(j.qty, 1) FROM OPENJSON(@Items) WITH (kind VARCHAR(5) '$.kind', id INT '$.id', qty INT '$.qty') j;
    IF NOT EXISTS (SELECT 1 FROM @In WHERE Kind IN ('T','P')) THROW 56202, 'Add at least one test, profile or package.', 1;
    IF EXISTS (SELECT 1 FROM @In WHERE Kind NOT IN ('T','P','M') OR Id IS NULL OR Id <= 0) THROW 56203, 'An item of the estimate could not be read. Remove it and add it again.', 1;
    IF EXISTS (SELECT 1 FROM @In WHERE Qty < 1 OR Qty > 99 OR (Kind <> 'M' AND Qty <> 1)) THROW 56204, 'A test is added once; a misc charge quantity is 1 to 99.', 1;
    IF EXISTS (SELECT Kind, Id FROM @In GROUP BY Kind, Id HAVING COUNT(1) > 1) THROW 56205, 'An item is in the estimate twice. Remove the duplicate.', 1;
    IF (SELECT COUNT(1) FROM @In) > 200 THROW 56206, 'An estimate can have up to 200 items.', 1;

    DECLARE @B TABLE (Item_Type VARCHAR(20), Item_ID INT, Rate DECIMAL(18,2), DiscAllowed BIT, PRIMARY KEY (Item_Type, Item_ID));
    INSERT @B SELECT Item_Type, Item_ID, B2CRate, ISNULL(B2CDiscountAllowed, 0) FROM dbo.fn_LabBookableItems(@BranchId, 'B2C', NULL);

    INSERT #EL (LineSeq, ItemKind, ItemId, ItemCode, ItemName, GroupKey, GroupName, SampleType, TatHours, Qty, Rate, DiscountAllowed, GstPercent, Bookable)
    SELECT i.Seq, CASE WHEN ISNULL(t.Is_Profile_Test, 0) = 1 THEN 'R' ELSE 'T' END, i.Id, t.Test_Code, ISNULL(t.Test_Name, N'Test ' + CAST(i.Id AS NVARCHAR(10))),
           'D' + CAST(ISNULL(t.Department_ID, 0) AS VARCHAR(10)), ISNULL(dm.DeptName, N'Other'), st.Sample_Name, t.TAT_Hours, 1,
           ISNULL(b.Rate, 0), ISNULL(b.DiscAllowed, 0), 0,
           CAST(CASE WHEN t.Test_ID IS NOT NULL AND t.Status = 1 AND t.IsDeleted = 0 AND t.Is_Billable = 1 AND b.Item_ID IS NOT NULL THEN 1 ELSE 0 END AS BIT)
    FROM @In i
    LEFT JOIN dbo.LabInvestigationMaster t ON t.Test_ID = i.Id
    LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = t.Department_ID
    LEFT JOIN dbo.LabSampleTypeMaster st ON st.Sample_Type_ID = t.Sample_Type_ID
    LEFT JOIN @B b ON b.Item_ID = i.Id AND b.Item_Type = CASE WHEN t.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END
    WHERE i.Kind = 'T'
    UNION ALL
    SELECT i.Seq, 'P', i.Id, h.Profile_Code, ISNULL(h.Profile_Name, N'Package ' + CAST(i.Id AS NVARCHAR(10))), 'PKG', N'Packages', NULL, h.Profile_TAT_Hours, 1,
           ISNULL(b.Rate, 0), ISNULL(b.DiscAllowed, 0), 0,
           CAST(CASE WHEN h.Profile_ID IS NOT NULL AND h.Status = 1 AND h.IsDeleted = 0 AND h.Profile_Type = 2 AND b.Item_ID IS NOT NULL THEN 1 ELSE 0 END AS BIT)
    FROM @In i
    LEFT JOIN dbo.LabInvestigationProfileHeader h ON h.Profile_ID = i.Id
    LEFT JOIN @B b ON b.Item_ID = i.Id AND b.Item_Type = 'Package'
    WHERE i.Kind = 'P'
    UNION ALL
    SELECT i.Seq, 'M', i.Id, NULL, ISNULL(m.Charge_Name, N'Charge ' + CAST(i.Id AS NVARCHAR(10))), NULL, NULL, NULL, NULL, i.Qty,
           ISNULL(m.Amount, 0), ISNULL(m.Is_Discountable, 0), CASE WHEN m.Is_GST_Required = 1 THEN ISNULL(m.GST_Percentage, 0) ELSE 0 END,
           CAST(CASE WHEN m.Misc_Charge_ID IS NOT NULL AND m.Status = 1 AND m.IsDeleted = 0 AND m.CompanyId = @CompanyId THEN 1 ELSE 0 END AS BIT)
    FROM @In i
    LEFT JOIN dbo.LabMiscChargeMaster m ON m.Misc_Charge_ID = i.Id
    WHERE i.Kind = 'M';

    SELECT @msg = STRING_AGG(CAST(ItemName AS NVARCHAR(MAX)), N', ') FROM #EL WHERE Bookable = 0;
    IF @msg IS NOT NULL BEGIN SET @msg = N'Not on this branch''s B2C rate list (or inactive): ' + LEFT(@msg, 300) + N'. Remove them.'; THROW 56207, @msg, 1; END;
    SELECT @msg = STRING_AGG(CAST(ItemName AS NVARCHAR(MAX)), N', ') FROM #EL WHERE Rate <= 0 AND ItemKind <> 'M';
    IF @msg IS NOT NULL BEGIN SET @msg = N'These tests have a price of Rs 0.00 and cannot be estimated: ' + LEFT(@msg, 300) + N'. Set their rate first, or remove them.'; THROW 56208, @msg, 1; END;

    -- a test / profile already inside another profile or package of the estimate is refused (B2C Booking blocks it too)
    SELECT TOP 1 @msg = N'''' + a.ItemName + N''' is already included in the ' + CASE b.ItemKind WHEN 'P' THEN N'package' ELSE N'profile' END
                      + N' ''' + b.ItemName + N'''. Remove one of them.'
    FROM #EL a JOIN #EL b ON b.LineSeq <> a.LineSeq AND b.ItemKind IN ('R', 'P')
    WHERE a.ItemKind IN ('T', 'R')
      AND EXISTS (SELECT 1 FROM dbo.fn_LabEstimate_Includes(CASE b.ItemKind WHEN 'P' THEN 'P' ELSE 'T' END, b.ItemId) x WHERE x.TestId = a.ItemId)
    ORDER BY a.LineSeq;
    IF @msg IS NOT NULL THROW 56220, @msg, 1;

    UPDATE #EL SET Amount = Rate * Qty, DiscountAmount = 0, MemberDiscount = 0, MemberRule = NULL;

    -- membership benefits (worked out by usp_Membership_LabBenefits): at most the line amount
    IF ISJSON(ISNULL(@MemberDisc, '')) = 1
        UPDATE l SET MemberDiscount = CASE WHEN j.disc > l.Amount THEN l.Amount ELSE j.disc END, MemberRule = LEFT(j.[rule], 200)
        FROM #EL l JOIN OPENJSON(@MemberDisc) WITH (line INT '$.line', disc DECIMAL(18,2) '$.disc', [rule] NVARCHAR(400) '$.rule') j ON j.line = l.LineSeq
        WHERE j.disc > 0;
    -- as the B2C bill: a membership benefit on tests blocks a manual discount
    IF EXISTS (SELECT 1 FROM #EL WHERE ItemKind <> 'M' AND MemberDiscount > 0) AND (@DiscType = 'D' OR (@DiscType IN ('P','F') AND @DiscValue > 0))
        THROW 56219, 'This patient''s membership benefit already discounts the tests on this estimate, so a manual discount cannot be added.', 1;

    -- department heads (tests by department + Packages); misc charges take no department discount
    INSERT #EH (GroupKey, GroupName, Tests, Eligible, NonEligible)
    SELECT GroupKey, MAX(GroupName), COUNT(1), SUM(CASE WHEN DiscountAllowed = 1 AND MemberDiscount = 0 THEN Amount ELSE 0 END), SUM(CASE WHEN DiscountAllowed = 0 OR MemberDiscount > 0 THEN Amount ELSE 0 END)
    FROM #EL WHERE ItemKind <> 'M' GROUP BY GroupKey;

    DECLARE @Eligible DECIMAL(18,2) = (SELECT ISNULL(SUM(Amount), 0) FROM #EL WHERE DiscountAllowed = 1 AND MemberDiscount = 0 AND Amount > 0);
    IF @DiscType IS NOT NULL AND @DiscType NOT IN ('P','F','D') THROW 56209, 'Choose a % or ₹ discount, or department-wise.', 1;

    IF @DiscType IN ('P','F') AND @DiscValue > 0
    BEGIN
        IF @DiscValue < 0 OR (@DiscType = 'P' AND @DiscValue > 100) THROW 56210, 'The discount must be 0 to 100 %, or a ₹ amount of 0 or more.', 1;
        IF @Eligible <= 0 THROW 56211, 'None of these items allows a discount (B2C rate card / misc charge settings).', 1;
        IF @DiscType = 'F' AND @DiscValue > @Eligible BEGIN SET @msg = N'At most ₹' + FORMAT(@Eligible, 'N2') + N' can be discounted (the discountable amount).'; THROW 56212, @msg, 1; END;
        DECLARE @Disc DECIMAL(18,2) = ROUND(CASE WHEN @DiscType = 'P' THEN @Eligible * @DiscValue / 100 ELSE @DiscValue END, 2);
        -- spread in proportion to price, the last eligible line taking the remainder (as the B2C payment modal)
        ;WITH e AS (SELECT LineSeq, Amount, ROW_NUMBER() OVER (ORDER BY LineSeq DESC) AS rn FROM #EL WHERE DiscountAllowed = 1 AND MemberDiscount = 0 AND Amount > 0)
        UPDATE l SET DiscountAmount = CASE WHEN e.rn = 1 THEN 0 ELSE ROUND(@Disc * e.Amount / @Eligible, 2) END
        FROM #EL l JOIN e ON e.LineSeq = l.LineSeq;
        UPDATE l SET DiscountAmount = @Disc - ISNULL((SELECT SUM(DiscountAmount) FROM #EL x WHERE x.DiscountAllowed = 1 AND x.MemberDiscount = 0 AND x.Amount > 0 AND x.LineSeq <> l.LineSeq), 0)
        FROM #EL l WHERE l.LineSeq = (SELECT MAX(LineSeq) FROM #EL WHERE DiscountAllowed = 1 AND MemberDiscount = 0 AND Amount > 0);
    END
    ELSE IF @DiscType = 'D'
    BEGIN
        IF ISJSON(ISNULL(@DeptDisc, '')) <> 1 THROW 56213, 'Enter a discount for at least one department.', 1;
        DECLARE @D TABLE (GroupKey VARCHAR(20), DType CHAR(1), DValue DECIMAL(18,2));
        INSERT @D SELECT LTRIM(RTRIM(j.[key])), UPPER(LEFT(LTRIM(ISNULL(j.[type], 'P')), 1)), ISNULL(j.[value], 0)
        FROM OPENJSON(@DeptDisc) WITH ([key] VARCHAR(20) '$.key', [type] VARCHAR(2) '$.type', [value] DECIMAL(18,2) '$.value') j;
        IF EXISTS (SELECT 1 FROM @D d WHERE NOT EXISTS (SELECT 1 FROM #EH h WHERE h.GroupKey = d.GroupKey))
            THROW 56214, 'The department discount does not match the tests of the estimate. Open it again.', 1;
        IF EXISTS (SELECT GroupKey FROM @D GROUP BY GroupKey HAVING COUNT(1) > 1) THROW 56215, 'A department appears twice in the discount.', 1;
        IF EXISTS (SELECT 1 FROM @D WHERE DType NOT IN ('P','F') OR DValue < 0 OR (DType = 'P' AND DValue > 100))
            THROW 56216, 'A department discount must be 0 to 100 %, or a ₹ amount of 0 or more.', 1;
        SELECT TOP 1 @msg = h.GroupName + N': at most ₹' + FORMAT(h.Eligible, 'N2') + N' can be discounted.'
        FROM @D d JOIN #EH h ON h.GroupKey = d.GroupKey WHERE d.DType = 'F' AND d.DValue > h.Eligible;
        IF @msg IS NOT NULL THROW 56217, @msg, 1;
        UPDATE h SET DType = d.DType, DValue = d.DValue FROM #EH h JOIN @D d ON d.GroupKey = h.GroupKey;
        -- % : each eligible line round(price x % / 100, 2); ₹ : spread over the head's eligible lines by price, last takes the remainder
        UPDATE l SET DiscountAmount = ROUND(l.Amount * h.DValue / 100, 2)
        FROM #EL l JOIN #EH h ON h.GroupKey = l.GroupKey
        WHERE h.DType = 'P' AND h.DValue > 0 AND l.DiscountAllowed = 1 AND l.MemberDiscount = 0 AND l.Amount > 0 AND l.ItemKind <> 'M';
        ;WITH e AS (SELECT l.LineSeq, l.Amount, h.DValue, h.Eligible, ROW_NUMBER() OVER (PARTITION BY l.GroupKey ORDER BY l.LineSeq DESC) AS rn
                    FROM #EL l JOIN #EH h ON h.GroupKey = l.GroupKey
                    WHERE h.DType = 'F' AND h.DValue > 0 AND l.DiscountAllowed = 1 AND l.MemberDiscount = 0 AND l.Amount > 0 AND l.ItemKind <> 'M')
        UPDATE l SET DiscountAmount = CASE WHEN e.rn = 1 THEN 0 ELSE ROUND(e.DValue * e.Amount / e.Eligible, 2) END
        FROM #EL l JOIN e ON e.LineSeq = l.LineSeq;
        UPDATE l SET DiscountAmount = h.DValue - ISNULL((SELECT SUM(x.DiscountAmount) FROM #EL x WHERE x.GroupKey = l.GroupKey AND x.DiscountAllowed = 1 AND x.MemberDiscount = 0 AND x.Amount > 0 AND x.LineSeq <> l.LineSeq AND x.ItemKind <> 'M'), 0)
        FROM #EL l JOIN #EH h ON h.GroupKey = l.GroupKey
        WHERE h.DType = 'F' AND h.DValue > 0 AND l.ItemKind <> 'M'
          AND l.LineSeq = (SELECT MAX(x.LineSeq) FROM #EL x WHERE x.GroupKey = l.GroupKey AND x.DiscountAllowed = 1 AND x.MemberDiscount = 0 AND x.Amount > 0 AND x.ItemKind <> 'M');
        UPDATE h SET DAmount = ISNULL((SELECT SUM(DiscountAmount) FROM #EL l WHERE l.GroupKey = h.GroupKey AND l.ItemKind <> 'M'), 0) FROM #EH h;
        IF NOT EXISTS (SELECT 1 FROM #EL WHERE DiscountAmount > 0) THROW 56218, 'Enter a discount for at least one department.', 1;
    END

    UPDATE #EL SET DiscountAmount = CASE WHEN DiscountAmount > Amount - MemberDiscount THEN Amount - MemberDiscount WHEN DiscountAmount < 0 THEN 0 ELSE DiscountAmount END;
    -- misc GST on the amount after discount: CGST = SGST = ROUND(net x % / 200, 2), as the B2C bill
    UPDATE #EL SET NetAmount = Amount - DiscountAmount - MemberDiscount;
    UPDATE #EL SET GstAmount = 2 * ROUND(NetAmount * GstPercent / 200, 2);
    UPDATE #EL SET LineTotal = NetAmount + GstAmount;
END;
GO

-- the shapes of #EL / #EH (one place, used by Calc and Save)
CREATE OR ALTER PROCEDURE dbo.usp_LabEstimate_TempDdl AS SELECT 1;   -- marker only; the tables are declared in each caller
GO

-- simulate: RS1 lines, RS2 department heads, RS3 totals (nothing is saved)
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabEstimate_Calc
    @CompanyId INT, @BranchId INT, @Items NVARCHAR(MAX), @DiscType CHAR(1) = NULL, @DiscValue DECIMAL(18,2) = 0, @DeptDisc NVARCHAR(MAX) = NULL,
    @MemberDisc NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #EL (LineSeq INT PRIMARY KEY, ItemKind CHAR(1), ItemId INT, ItemCode NVARCHAR(50), ItemName NVARCHAR(250), GroupKey VARCHAR(20), GroupName NVARCHAR(150),
        SampleType NVARCHAR(100), TatHours DECIMAL(9,2), Qty INT, Rate DECIMAL(18,2), Amount DECIMAL(18,2), DiscountAllowed BIT, DiscountAmount DECIMAL(18,2),
        MemberDiscount DECIMAL(18,2) NOT NULL DEFAULT 0, MemberRule NVARCHAR(200) NULL, NetAmount DECIMAL(18,2), GstPercent DECIMAL(9,2), GstAmount DECIMAL(18,2), LineTotal DECIMAL(18,2), Bookable BIT);
    CREATE TABLE #EH (GroupKey VARCHAR(20) PRIMARY KEY, GroupName NVARCHAR(150), Tests INT, Eligible DECIMAL(18,2), NonEligible DECIMAL(18,2),
        DType CHAR(1) NULL, DValue DECIMAL(18,2) NULL, DAmount DECIMAL(18,2) NULL);
    BEGIN TRY
        EXEC dbo.usp_LabEstimate_Compute @CompanyId, @BranchId, @Items, @DiscType, @DiscValue, @DeptDisc, @MemberDisc;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() >= 50000 BEGIN SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; RETURN; END;
        THROW;
    END CATCH
    SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(400)) AS Error,
           SUM(Amount) AS GrossAmount, SUM(CASE WHEN DiscountAllowed = 1 AND MemberDiscount = 0 THEN Amount ELSE 0 END) AS EligibleAmount,
           SUM(DiscountAmount) AS DiscountAmount, SUM(MemberDiscount) AS MemberDiscount, SUM(CASE WHEN ItemKind <> 'M' THEN MemberDiscount ELSE 0 END) AS MemberTestDiscount, SUM(GstAmount) AS GstAmount, SUM(LineTotal) AS NetAmount,
           SUM(CASE WHEN ItemKind <> 'M' THEN 1 ELSE 0 END) AS TestCount, MAX(TatHours) AS MaxTatHours
    FROM #EL;
    SELECT LineSeq, ItemKind, ItemId, ItemCode, ItemName, GroupKey, GroupName, SampleType, TatHours, Qty, Rate, Amount, DiscountAllowed,
           DiscountAmount, MemberDiscount, MemberRule, NetAmount, GstPercent, GstAmount, LineTotal FROM #EL ORDER BY LineSeq;
    SELECT GroupKey, GroupName, Tests, Eligible, NonEligible, DType, DValue, ISNULL(DAmount, 0) AS DAmount FROM #EH ORDER BY CASE WHEN GroupKey = 'PKG' THEN 1 ELSE 0 END, GroupName;
END;
GO
DROP PROCEDURE IF EXISTS dbo.usp_LabEstimate_TempDdl;
GO

-- save: the same computation, then the estimate. @CanDiscount from the screen's DISCOUNT right.
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabEstimate_Save
    @CompanyId INT, @BranchId INT, @UserId INT,
    @PatientId INT = NULL, @Salutation NVARCHAR(20) = NULL, @PatientName NVARCHAR(200), @Gender NVARCHAR(20) = NULL, @AgeYears INT = NULL,
    @Mobile VARCHAR(15), @EmailId NVARCHAR(150) = NULL, @RefDoctorId INT = NULL,
    @Items NVARCHAR(MAX), @DiscType CHAR(1) = NULL, @DiscValue DECIMAL(18,2) = 0, @DeptDisc NVARCHAR(MAX) = NULL,
    @CanDiscount BIT = 0, @ValidDays INT = 7, @Remarks NVARCHAR(500) = NULL,
    @MemberDisc NVARCHAR(MAX) = NULL, @MemberCardNo NVARCHAR(30) = NULL, @MemberPlan NVARCHAR(150) = NULL   -- set by the API only
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    CREATE TABLE #EL (LineSeq INT PRIMARY KEY, ItemKind CHAR(1), ItemId INT, ItemCode NVARCHAR(50), ItemName NVARCHAR(250), GroupKey VARCHAR(20), GroupName NVARCHAR(150),
        SampleType NVARCHAR(100), TatHours DECIMAL(9,2), Qty INT, Rate DECIMAL(18,2), Amount DECIMAL(18,2), DiscountAllowed BIT, DiscountAmount DECIMAL(18,2),
        MemberDiscount DECIMAL(18,2) NOT NULL DEFAULT 0, MemberRule NVARCHAR(200) NULL, NetAmount DECIMAL(18,2), GstPercent DECIMAL(9,2), GstAmount DECIMAL(18,2), LineTotal DECIMAL(18,2), Bookable BIT);
    CREATE TABLE #EH (GroupKey VARCHAR(20) PRIMARY KEY, GroupName NVARCHAR(150), Tests INT, Eligible DECIMAL(18,2), NonEligible DECIMAL(18,2),
        DType CHAR(1) NULL, DValue DECIMAL(18,2) NULL, DAmount DECIMAL(18,2) NULL);
    DECLARE @tc INT = @@TRANCOUNT, @began BIT = 0;
    BEGIN TRY
        SET @PatientName = LTRIM(RTRIM(ISNULL(@PatientName, N'')));
        SET @Mobile = LTRIM(RTRIM(ISNULL(@Mobile, '')));
        SET @EmailId = NULLIF(LOWER(LTRIM(RTRIM(@EmailId))), N'');
        SET @Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N'');
        SET @Gender = NULLIF(LTRIM(RTRIM(@Gender)), N'');
        SET @DiscType = NULLIF(UPPER(LTRIM(RTRIM(@DiscType))), '');
        IF NOT EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @BranchId AND CompanyId = @CompanyId) THROW 56230, 'Your branch could not be found - sign in again.', 1;
        IF @PatientId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.PatientMaster WHERE PatientId = @PatientId) THROW 56231, 'The patient was not found.', 1;
        IF LEN(@PatientName) < 2 THROW 56232, 'Enter the patient''s name.', 1;
        IF LEN(@Mobile) <> 10 OR @Mobile LIKE '%[^0-9]%' OR LEFT(@Mobile, 1) NOT IN ('6','7','8','9') THROW 56233, 'Enter a valid 10-digit mobile number (starting with 6, 7, 8 or 9).', 1;
        IF @EmailId IS NOT NULL AND (@EmailId NOT LIKE N'_%@_%._%' OR @EmailId LIKE N'% %') THROW 56234, 'Enter a valid e-mail ID.', 1;
        IF @AgeYears IS NOT NULL AND (@AgeYears < 0 OR @AgeYears > 130) THROW 56235, 'Enter an age between 0 and 130.', 1;
        IF @Gender IS NOT NULL AND @Gender NOT IN (N'Male', N'Female', N'Other') THROW 56236, 'Choose the gender.', 1;
        IF @ValidDays IS NULL OR @ValidDays NOT BETWEEN 1 AND 90 THROW 56237, 'The estimate can be valid for 1 to 90 days.', 1;
        IF @RefDoctorId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @RefDoctorId) THROW 56238, 'The referring doctor was not found.', 1;
        IF ISNULL(@CanDiscount, 0) = 0 AND (@DiscType = 'D' OR (@DiscType IN ('P','F') AND ISNULL(@DiscValue, 0) > 0))
            THROW 56239, 'You do not have permission to give a discount on the estimate.', 1;

        EXEC dbo.usp_LabEstimate_Compute @CompanyId, @BranchId, @Items, @DiscType, @DiscValue, @DeptDisc, @MemberDisc;
        IF NOT EXISTS (SELECT 1 FROM #EL WHERE DiscountAmount > 0) BEGIN SET @DiscType = NULL; SET @DiscValue = 0; END;

        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN est_sp;
        SET @began = 1;
        DECLARE @fyStart TINYINT = ISNULL((SELECT FinancialYearStartMonth FROM dbo.Acc_Settings WHERE CompanyId = @CompanyId), 4);
        DECLARE @fy VARCHAR(7) = dbo.fn_Acc_FinancialYear(CAST(GETDATE() AS DATE), @fyStart);
        DECLARE @code NVARCHAR(20) = (SELECT ISNULL(NULLIF(LTRIM(RTRIM(BranchCode)), N''), CAST(BranchID AS NVARCHAR(10))) FROM dbo.Branchmaster WHERE BranchID = @BranchId);
        DECLARE @seq INT = ISNULL((SELECT MAX(SeqNo) FROM dbo.LabEstimate WITH (UPDLOCK, HOLDLOCK) WHERE BranchId = @BranchId AND FinancialYear = @fy), 0) + 1;
        DECLARE @no VARCHAR(40) = 'EST/' + @code + '/' + @fy + '/' + RIGHT('00000' + CAST(@seq AS VARCHAR(10)), CASE WHEN @seq > 99999 THEN LEN(@seq) ELSE 5 END);
        DECLARE @docName NVARCHAR(200) = (SELECT LTRIM(RTRIM(ISNULL(NamePrefix + ' ', '') + FullName)) FROM dbo.DoctorMaster WHERE DoctorId = @RefDoctorId);

        INSERT dbo.LabEstimate (CompanyId, BranchId, EstimateNo, FinancialYear, SeqNo, ValidTill, PatientId, Salutation, PatientName, Gender, AgeYears, Mobile, EmailId,
                                RefDoctorId, RefDoctorName, GrossAmount, DiscountType, DiscountValue, DiscountAmount, MembershipCardNo, MembershipPlan, MembershipDiscount, GstAmount, NetAmount, Remarks, CreatedBy)
        SELECT @CompanyId, @BranchId, @no, @fy, @seq, DATEADD(DAY, @ValidDays - 1, CAST(GETDATE() AS DATE)), @PatientId, NULLIF(LTRIM(RTRIM(@Salutation)), N''), @PatientName,
               @Gender, @AgeYears, @Mobile, @EmailId, @RefDoctorId, @docName, SUM(Amount), @DiscType, CASE WHEN @DiscType = 'D' THEN SUM(DiscountAmount) ELSE ISNULL(@DiscValue, 0) END,
               SUM(DiscountAmount), CASE WHEN SUM(MemberDiscount) > 0 THEN @MemberCardNo END, CASE WHEN SUM(MemberDiscount) > 0 THEN @MemberPlan END, SUM(MemberDiscount),
               SUM(GstAmount), SUM(LineTotal), @Remarks, @UserId
        FROM #EL;
        DECLARE @id INT = CAST(SCOPE_IDENTITY() AS INT);
        INSERT dbo.LabEstimateItem (EstimateId, LineSeq, ItemKind, ItemId, ItemCode, ItemName, GroupKey, GroupName, SampleType, TatHours, Qty, Rate, Amount,
                                    DiscountAllowed, DiscountAmount, MemberDiscount, MemberRule, NetAmount, GstPercent, GstAmount, LineTotal)
        SELECT @id, ROW_NUMBER() OVER (ORDER BY CASE ItemKind WHEN 'M' THEN 1 ELSE 0 END, LineSeq), ItemKind, ItemId, ItemCode, ItemName, GroupKey, GroupName, SampleType, TatHours,
               Qty, Rate, Amount, DiscountAllowed, DiscountAmount, MemberDiscount, MemberRule, NetAmount, GstPercent, GstAmount, LineTotal FROM #EL;
        IF @DiscType = 'D'
            INSERT dbo.LabEstimateDeptDiscount (EstimateId, GroupKey, GroupName, DiscType, DiscValue, DiscAmount)
            SELECT @id, GroupKey, GroupName, DType, DValue, ISNULL(DAmount, 0) FROM #EH WHERE DType IS NOT NULL AND DValue > 0;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(400)) AS Error, @id AS EstimateId, @no AS EstimateNo,
               (SELECT PublicToken FROM dbo.LabEstimate WHERE EstimateId = @id) AS PublicToken,
               (SELECT NetAmount FROM dbo.LabEstimate WHERE EstimateId = @id) AS NetAmount;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 AND @began = 1 ROLLBACK TRAN est_sp;
        IF ERROR_NUMBER() IN (2601, 2627) SELECT CAST(0 AS BIT) AS Success, N'Another estimate was saved at the same moment. Press Save again.' AS Error;
        ELSE IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- one estimate (by id within the branch, or by its public token): RS1 header + branch, RS2 lines, RS3 department discounts
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabEstimate_Get @EstimateId INT = NULL, @BranchId INT = NULL, @Token UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = CASE WHEN @Token IS NOT NULL THEN (SELECT EstimateId FROM dbo.LabEstimate WHERE PublicToken = @Token)
                           ELSE (SELECT EstimateId FROM dbo.LabEstimate WHERE EstimateId = @EstimateId AND BranchId = @BranchId) END;
    SELECT e.EstimateId, e.EstimateNo, e.EstimateDate, e.ValidTill, CAST(CASE WHEN e.ValidTill < CAST(GETDATE() AS DATE) THEN 1 ELSE 0 END AS BIT) AS IsExpired,
           e.PatientId, p.PatientCode, e.Salutation, e.PatientName, e.Gender, e.AgeYears, e.Mobile, e.EmailId, e.RefDoctorId, e.RefDoctorName,
           e.GrossAmount, e.DiscountType, e.DiscountValue, e.DiscountAmount, e.MembershipCardNo, e.MembershipPlan, e.MembershipDiscount, e.GstAmount, e.NetAmount, e.Remarks, e.Status, e.PublicToken,
           e.SentCount, e.LastSentTo, e.LastSentDate, e.CreatedDate, u.FullName AS CreatedByName, e.CancelledDate, uc.FullName AS CancelledByName, e.CancelReason,
           e.BranchId, b.BranchName, b.BranchCode, b.Address AS BranchAddress, b.City AS BranchCity, b.State AS BranchState, b.Pincode AS BranchPincode, e.CompanyId
    FROM dbo.LabEstimate e
    JOIN dbo.Branchmaster b ON b.BranchID = e.BranchId
    LEFT JOIN dbo.PatientMaster p ON p.PatientId = e.PatientId
    LEFT JOIN dbo.Users u ON u.Id = e.CreatedBy
    LEFT JOIN dbo.Users uc ON uc.Id = e.CancelledBy
    WHERE e.EstimateId = @id;
    SELECT LineSeq, ItemKind, ItemId, ItemCode, ItemName, GroupKey, GroupName, SampleType, TatHours, Qty, Rate, Amount, DiscountAllowed, DiscountAmount,
           MemberDiscount, MemberRule, NetAmount, GstPercent, GstAmount, LineTotal
    FROM dbo.LabEstimateItem WHERE EstimateId = @id ORDER BY LineSeq;
    SELECT GroupKey, GroupName, DiscType, DiscValue, DiscAmount FROM dbo.LabEstimateDeptDiscount WHERE EstimateId = @id ORDER BY GroupName;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabEstimate_List
    @BranchId INT, @FromDate DATE, @ToDate DATE, @Search NVARCHAR(100) = NULL, @Status VARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N''); SET @Status = NULLIF(UPPER(@Status), '');
    SELECT TOP 500 e.EstimateId, e.EstimateNo, e.EstimateDate, e.ValidTill, e.PatientName, e.Mobile, e.Gender, e.AgeYears, e.RefDoctorName,
           (SELECT COUNT(1) FROM dbo.LabEstimateItem i WHERE i.EstimateId = e.EstimateId AND i.ItemKind <> 'M') AS TestCount,
           e.GrossAmount, e.DiscountAmount + e.MembershipDiscount AS DiscountAmount, e.MembershipCardNo, e.NetAmount, e.Status,
           CASE WHEN e.Status = 'CANCELLED' THEN 'CANCELLED' WHEN e.ValidTill < CAST(GETDATE() AS DATE) THEN 'EXPIRED' ELSE 'ACTIVE' END AS DisplayStatus,
           e.SentCount, e.LastSentDate, u.FullName AS CreatedByName
    FROM dbo.LabEstimate e LEFT JOIN dbo.Users u ON u.Id = e.CreatedBy
    WHERE e.BranchId = @BranchId AND e.EstimateDate >= @FromDate AND e.EstimateDate < DATEADD(DAY, 1, CAST(@ToDate AS DATETIME))
      AND (@Search IS NULL OR e.EstimateNo LIKE N'%' + @Search + N'%' OR e.PatientName LIKE N'%' + @Search + N'%' OR e.Mobile LIKE N'%' + @Search + N'%')
      AND (@Status IS NULL OR (@Status = 'CANCELLED' AND e.Status = 'CANCELLED')
           OR (@Status = 'EXPIRED' AND e.Status = 'ACTIVE' AND e.ValidTill < CAST(GETDATE() AS DATE))
           OR (@Status = 'ACTIVE' AND e.Status = 'ACTIVE' AND e.ValidTill >= CAST(GETDATE() AS DATE)))
    ORDER BY e.EstimateDate DESC, e.EstimateId DESC;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabEstimate_Cancel @BranchId INT, @UserId INT, @EstimateId INT, @Reason NVARCHAR(250)
AS
BEGIN
    SET NOCOUNT ON;
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
    IF @Reason IS NULL BEGIN SELECT CAST(0 AS BIT) AS Success, N'Enter the reason for cancelling.' AS Error, @EstimateId AS EstimateId; RETURN; END;
    UPDATE dbo.LabEstimate SET Status = 'CANCELLED', CancelledBy = @UserId, CancelledDate = GETDATE(), CancelReason = @Reason
    WHERE EstimateId = @EstimateId AND BranchId = @BranchId AND Status = 'ACTIVE';
    IF @@ROWCOUNT = 0 SELECT CAST(0 AS BIT) AS Success, N'The estimate was not found or is already cancelled.' AS Error, @EstimateId AS EstimateId;
    ELSE SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(400)) AS Error, @EstimateId AS EstimateId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabEstimate_MarkSent @BranchId INT, @EstimateId INT, @SentTo VARCHAR(15)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.LabEstimate SET SentCount = SentCount + 1, LastSentTo = @SentTo, LastSentDate = GETDATE()
    WHERE EstimateId = @EstimateId AND BranchId = @BranchId;
    SELECT CAST(CASE WHEN @@ROWCOUNT = 1 THEN 1 ELSE 0 END AS BIT) AS Success, CAST(NULL AS NVARCHAR(400)) AS Error, @EstimateId AS EstimateId;
END;
GO

-- form helper: referring doctors (patients are found with the same search as B2C Booking, IPatientService)
DROP PROCEDURE IF EXISTS dbo.usp_Api_LabEstimate_PatientSearch;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabEstimate_Doctors @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT d.DoctorId, LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)) AS DoctorName
    FROM dbo.DoctorMaster d WHERE d.IsActive = 1 AND (d.CompanyId = @CompanyId OR d.CompanyId IS NULL)
    ORDER BY d.FullName;
END;
GO

-- ── page LAB > B2C Bill Estimate ────────────────────────────────────────────────────────────────────────────
DECLARE @co INT = 1, @menu INT = (SELECT Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'LAB'), @page INT, @view INT, @ctl INT;
IF @menu IS NULL THROW 51500, 'Menu LAB is missing.', 1;
EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'LAB.LABESTIMATE', @Title = N'B2C Bill Estimate',
     @Controller = N'LabEstimate', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 21, @Icon = N'bi bi-calculator me-2',
     @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
IF @view IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'VIEW', @Title = N'Open page, simulate, list and print', @Sort_Order = 10, @Control_ID = @view OUTPUT;
DECLARE @a NVARCHAR(60);
DECLARE v CURSOR LOCAL FAST_FORWARD FOR SELECT a FROM (VALUES (N'Index'), (N'Tests'), (N'MiscCharges'), (N'Doctors'), (N'Patients'), (N'Patient'), (N'Includes'), (N'List'), (N'Get'), (N'Print'), (N'Pdf')) x(a);
OPEN v; FETCH NEXT FROM v INTO @a;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'LabEstimate', @Action = @a, @Source = 'SEED';
    FETCH NEXT FROM v INTO @a;
END
CLOSE v; DEALLOCATE v;
-- simulate (Calc) is a POST under VIEW: nothing is saved; the discount in it is checked against DISCOUNT in the controller
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'POST', @Controller = N'LabEstimate', @Action = N'Calc', @Source = 'SEED';
DECLARE @c TABLE (Code VARCHAR(30), Title NVARCHAR(150), Sort INT, Act NVARCHAR(60));
INSERT @c VALUES ('ADD', N'Generate an estimate', 20, N'Save'), ('DISCOUNT', N'Give a discount (overall / department-wise)', 25, NULL),
                 ('SEND', N'Send the estimate to the patient''s mobile', 30, N'Send'), ('CANCEL', N'Cancel an estimate', 40, N'Cancel');
DECLARE @cc VARCHAR(30), @ct NVARCHAR(150), @cs INT, @ca NVARCHAR(60);
DECLARE k CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Sort, Act FROM @c;
OPEN k; FETCH NEXT FROM k INTO @cc, @ct, @cs, @ca;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = @cc;
    IF @ctl IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @cc, @Title = @ct, @Sort_Order = @cs, @Control_ID = @ctl OUTPUT;
    IF @ca IS NOT NULL EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'LabEstimate', @Action = @ca, @Source = 'SEED';
    FETCH NEXT FROM k INTO @cc, @ct, @cs, @ca;
END
CLOSE k; DEALLOCATE k;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT '2450 LAB B2C bill estimate - done.';
GO
