-- ============================================================================================================
-- Migration: 2523_bank_directory.sql   (application database; needs 2522)
-- Master > General > Bank Master: a directory of standard Indian banks - the bank name, its IFSC bank code (the first 4
-- letters of every IFSC of that bank, as assigned by the RBI) and the category. The Bank Master form offers these names,
-- fills the bank name from a typed IFSC, and warns when the IFSC does not belong to the bank chosen.
--   dbo.BankDirectory, usp_Api_Bank_Directory. Endpoint Banks/Directory (page MASTER.BANKS, VIEW). Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
IF OBJECT_ID(N'dbo.BankDirectory', N'U') IS NULL
    CREATE TABLE dbo.BankDirectory
    (
        BankCode  CHAR(4)       NOT NULL CONSTRAINT PK_BankDirectory PRIMARY KEY,   -- IFSC bank code
        BankName  NVARCHAR(150) NOT NULL,
        Category  VARCHAR(20)   NOT NULL,   -- PUBLIC | PRIVATE | SMALL FINANCE | PAYMENTS | FOREIGN | COOPERATIVE
        SortOrder INT           NOT NULL CONSTRAINT DF_BankDirectory_Sort DEFAULT (100),
        IsActive  BIT           NOT NULL CONSTRAINT DF_BankDirectory_Active DEFAULT (1)
    );
GO
MERGE dbo.BankDirectory AS t
USING (VALUES
    ('SBIN', N'State Bank of India', 'PUBLIC', 10), ('PUNB', N'Punjab National Bank', 'PUBLIC', 11), ('BARB', N'Bank of Baroda', 'PUBLIC', 12),
    ('CNRB', N'Canara Bank', 'PUBLIC', 13), ('UBIN', N'Union Bank of India', 'PUBLIC', 14), ('BKID', N'Bank of India', 'PUBLIC', 15),
    ('IDIB', N'Indian Bank', 'PUBLIC', 16), ('CBIN', N'Central Bank of India', 'PUBLIC', 17), ('IOBA', N'Indian Overseas Bank', 'PUBLIC', 18),
    ('UCBA', N'UCO Bank', 'PUBLIC', 19), ('MAHB', N'Bank of Maharashtra', 'PUBLIC', 20), ('PSIB', N'Punjab & Sind Bank', 'PUBLIC', 21),
    ('HDFC', N'HDFC Bank', 'PRIVATE', 30), ('ICIC', N'ICICI Bank', 'PRIVATE', 31), ('UTIB', N'Axis Bank', 'PRIVATE', 32),
    ('KKBK', N'Kotak Mahindra Bank', 'PRIVATE', 33), ('INDB', N'IndusInd Bank', 'PRIVATE', 34), ('YESB', N'Yes Bank', 'PRIVATE', 35),
    ('IBKL', N'IDBI Bank', 'PRIVATE', 36), ('IDFB', N'IDFC FIRST Bank', 'PRIVATE', 37), ('FDRL', N'Federal Bank', 'PRIVATE', 38),
    ('RATN', N'RBL Bank', 'PRIVATE', 39), ('BDBL', N'Bandhan Bank', 'PRIVATE', 40), ('SIBL', N'South Indian Bank', 'PRIVATE', 41),
    ('KVBL', N'Karur Vysya Bank', 'PRIVATE', 42), ('CIUB', N'City Union Bank', 'PRIVATE', 43), ('TMBL', N'Tamilnad Mercantile Bank', 'PRIVATE', 44),
    ('KARB', N'Karnataka Bank', 'PRIVATE', 45), ('DCBL', N'DCB Bank', 'PRIVATE', 46), ('CSBK', N'CSB Bank', 'PRIVATE', 47),
    ('DLXB', N'Dhanlaxmi Bank', 'PRIVATE', 48), ('JAKA', N'Jammu & Kashmir Bank', 'PRIVATE', 49),
    ('AUBL', N'AU Small Finance Bank', 'SMALL FINANCE', 60), ('ESFB', N'Equitas Small Finance Bank', 'SMALL FINANCE', 61),
    ('UJVN', N'Ujjivan Small Finance Bank', 'SMALL FINANCE', 62),
    ('IPOS', N'India Post Payments Bank', 'PAYMENTS', 70), ('AIRP', N'Airtel Payments Bank', 'PAYMENTS', 71), ('PYTM', N'Paytm Payments Bank', 'PAYMENTS', 72),
    ('SCBL', N'Standard Chartered Bank', 'FOREIGN', 80), ('HSBC', N'HSBC Bank', 'FOREIGN', 81), ('CITI', N'Citibank', 'FOREIGN', 82),
    ('DBSS', N'DBS Bank India', 'FOREIGN', 83)
) s (Code, Name, Cat, Sort)
ON t.BankCode = s.Code
WHEN MATCHED THEN UPDATE SET BankName = s.Name, Category = s.Cat, SortOrder = s.Sort
WHEN NOT MATCHED THEN INSERT (BankCode, BankName, Category, SortOrder) VALUES (s.Code, s.Name, s.Cat, s.Sort);
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_Bank_Directory
AS
BEGIN
    SET NOCOUNT ON;
    SELECT BankCode, BankName, Category FROM dbo.BankDirectory WHERE IsActive = 1 ORDER BY SortOrder, BankName;
END
GO
DECLARE @p INT = (SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'MASTER.BANKS'), @v INT;
SELECT @v = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @p AND Control_Code = 'VIEW';
IF @p IS NOT NULL
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @p, @Control_ID = @v, @App = 'WEB', @Http_Method = 'GET', @Controller = N'Banks', @Action = N'Directory', @Source = 'SEED';
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
DECLARE @n INT = (SELECT COUNT(*) FROM dbo.BankDirectory);
PRINT 'Script 2523 applied: standard bank directory (' + CAST(@n AS VARCHAR(5)) + ' banks).';
GO
