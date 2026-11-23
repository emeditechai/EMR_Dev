-- ============================================================================================================
-- Migration: 2401_lab_phlebotomist_preprinted_barcode.sql
-- Master > Lab Master > Phlebotomist Barcode Assignment: pre-printed tube barcodes generated in series for a phlebotomist
-- (Users.IsPhlebotomist = 1), same flow as Franchise Barcode Assignment (SQLScripts/2151): generate, view, print labels,
-- cancel a series (voids the unused codes). The phlebotomist app (later) validates and consumes them.
--   LabPhleboBarcodeSeries / LabPhleboBarcodePool
--   Barcode: <BranchCode>-PB<user id, 4 digits>-<FY 2 digits>-<6-digit sequence>[-F / -PP / -U], e.g. HO-PB0028-26-000001;
--   the sequence continues across the phlebotomist's series. Status 1 Available, 2 Used, 3 Voided.
--   usp_Api_LabPhleboBarcode_Phlebotomists / _Generate / _GetList / _Cancel / _GetBarcodes / _ValidateConsume (for the app)
--   Page MASTER.LABPHLEBOBARCODES (VIEW, GENERATE, CANCEL, PRINT). No role is granted here.
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.LabPhleboBarcodeSeries', 'U') IS NULL
CREATE TABLE dbo.LabPhleboBarcodeSeries
(
    SeriesId           INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LabPhleboBarcodeSeries PRIMARY KEY,
    CompanyId          INT            NOT NULL,
    BranchId           INT            NOT NULL,
    PhlebotomistId     INT            NOT NULL,
    SeriesCode         NVARCHAR(20)   NOT NULL CONSTRAINT UQ_LabPhleboBarcodeSeries_Code UNIQUE,
    FinancialYear      NVARCHAR(10)   NOT NULL,
    StartNumber        INT            NOT NULL,
    EndNumber          INT            NOT NULL,
    Quantity           INT            NOT NULL,
    Status             NVARCHAR(20)   NOT NULL CONSTRAINT DF_LabPhleboBarcodeSeries_Status DEFAULT ('Active'),
    SampleCategoryCode NVARCHAR(10)   NULL,
    GeneratedBy        INT            NULL,
    GeneratedDate      DATETIME       NOT NULL CONSTRAINT DF_LabPhleboBarcodeSeries_Gen DEFAULT (GETDATE()),
    CancelledBy        INT            NULL,
    CancelledDate      DATETIME       NULL,
    CancelReason       NVARCHAR(500)  NULL
);
GO
IF OBJECT_ID('dbo.LabPhleboBarcodePool', 'U') IS NULL
CREATE TABLE dbo.LabPhleboBarcodePool
(
    BarcodeId          BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LabPhleboBarcodePool PRIMARY KEY,
    SeriesId           INT            NOT NULL CONSTRAINT FK_LabPhleboBarcodePool_Series REFERENCES dbo.LabPhleboBarcodeSeries (SeriesId),
    PhlebotomistId     INT            NOT NULL,
    BarcodeNo          NVARCHAR(50)   NOT NULL CONSTRAINT UQ_LabPhleboBarcodePool_No UNIQUE,
    SequenceNo         INT            NOT NULL,
    Status             TINYINT        NOT NULL CONSTRAINT DF_LabPhleboBarcodePool_Status DEFAULT (1),   -- 1 Available, 2 Used, 3 Voided
    LabOrderId         INT            NULL,
    SamplecollectionID BIGINT         NULL,
    UsedBy             INT            NULL,
    UsedDate           DATETIME       NULL,
    VoidedBy           INT            NULL,
    VoidedDate         DATETIME       NULL,
    VoidReason         NVARCHAR(500)  NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LabPhleboBarcodePool_Series')
    CREATE INDEX IX_LabPhleboBarcodePool_Series ON dbo.LabPhleboBarcodePool (SeriesId, Status);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LabPhleboBarcodePool_Phlebo')
    CREATE INDEX IX_LabPhleboBarcodePool_Phlebo ON dbo.LabPhleboBarcodePool (PhlebotomistId, Status);
GO

-- phlebotomists of the branch (Users.IsPhlebotomist = 1) with their barcode counts
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabPhleboBarcode_Phlebotomists
    @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.Id AS PhlebotomistId, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS Name, u.Username,
           'PB' + RIGHT('0000' + CAST(u.Id AS VARCHAR(10)), 4) AS PhleboCode,
           COALESCE(NULLIF(LTRIM(RTRIM(u.PhoneNumber)), ''), NULLIF(LTRIM(RTRIM(u.Phone)), '')) AS Mobile,
           ISNULL(c.Available, 0) AS AvailableCount, ISNULL(c.Used, 0) AS UsedCount, ISNULL(c.Series, 0) AS SeriesCount
      FROM dbo.Users u
      OUTER APPLY (SELECT SUM(CASE WHEN p.Status = 1 THEN 1 ELSE 0 END) AS Available, SUM(CASE WHEN p.Status = 2 THEN 1 ELSE 0 END) AS Used,
                          (SELECT COUNT(*) FROM dbo.LabPhleboBarcodeSeries s WHERE s.PhlebotomistId = u.Id AND s.BranchId = @BranchId) AS Series
                     FROM dbo.LabPhleboBarcodePool p JOIN dbo.LabPhleboBarcodeSeries s ON s.SeriesId = p.SeriesId AND s.BranchId = @BranchId
                    WHERE p.PhlebotomistId = u.Id) c
     WHERE u.IsActive = 1 AND ISNULL(u.IsPhlebotomist, 0) = 1 AND ISNULL(u.CompanyId, @CompanyId) = @CompanyId
       AND EXISTS (SELECT 1 FROM dbo.UserBranches ub WHERE ub.UserId = u.Id AND ub.BranchID = @BranchId AND ub.IsActive = 1)
     ORDER BY Name;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabPhleboBarcode_Generate
    @CompanyId INT, @BranchId INT, @PhlebotomistId INT, @Quantity INT, @SampleCategoryCode NVARCHAR(10) = NULL, @CreatedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @Quantity IS NULL OR @Quantity <= 0 OR @Quantity > 10000
    BEGIN RAISERROR('Quantity must be between 1 and 10000.', 16, 1); RETURN; END
    SET @SampleCategoryCode = NULLIF(LTRIM(RTRIM(UPPER(ISNULL(@SampleCategoryCode, '')))), '');
    IF @SampleCategoryCode IS NOT NULL AND @SampleCategoryCode NOT IN ('F', 'PP', 'U')
    BEGIN RAISERROR('Sample Category must be Fasting (F), PP (PP), Urine (U), or left blank.', 16, 1); RETURN; END
    IF NOT EXISTS (SELECT 1 FROM dbo.Users u WHERE u.Id = @PhlebotomistId AND u.IsActive = 1 AND ISNULL(u.IsPhlebotomist, 0) = 1
                     AND EXISTS (SELECT 1 FROM dbo.UserBranches ub WHERE ub.UserId = u.Id AND ub.BranchID = @BranchId AND ub.IsActive = 1))
    BEGIN RAISERROR('Choose an active phlebotomist of this branch (User Master > Is Phlebotomist).', 16, 1); RETURN; END

    DECLARE @BranchCode NVARCHAR(20) = 'HO';
    SELECT @BranchCode = ISNULL(NULLIF(RTRIM(LTRIM(BranchCode)), ''), 'HO') FROM dbo.Branchmaster WHERE BranchID = @BranchId;
    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @FYStart INT = CASE WHEN MONTH(@Today) >= 4 THEN YEAR(@Today) ELSE YEAR(@Today) - 1 END;
    DECLARE @FY2 NVARCHAR(10) = RIGHT(CAST(@FYStart AS NVARCHAR(4)), 2);
    DECLARE @Code NVARCHAR(10) = 'PB' + RIGHT('0000' + CAST(@PhlebotomistId AS VARCHAR(10)), 4);
    DECLARE @Suffix NVARCHAR(10) = CASE WHEN @SampleCategoryCode IS NULL THEN '' ELSE '-' + @SampleCategoryCode END;
    DECLARE @Prefix NVARCHAR(40) = @BranchCode + '-' + @Code + '-' + @FY2 + '-';

    BEGIN TRANSACTION;
    BEGIN TRY
        -- the sequence continues across every series of this phlebotomist
        DECLARE @StartNumber INT;
        SELECT @StartNumber = ISNULL(MAX(EndNumber), 0) + 1 FROM dbo.LabPhleboBarcodeSeries WITH (UPDLOCK, HOLDLOCK) WHERE PhlebotomistId = @PhlebotomistId;
        DECLARE @EndNumber INT = @StartNumber + @Quantity - 1;

        DECLARE @NextNum INT = (SELECT ISNULL(MAX(SeriesId), 0) + 1 FROM dbo.LabPhleboBarcodeSeries WITH (UPDLOCK, HOLDLOCK));
        DECLARE @SeriesCode NVARCHAR(20) = 'PBS' + RIGHT('0000' + CAST(@NextNum AS NVARCHAR(10)), 4);
        WHILE EXISTS (SELECT 1 FROM dbo.LabPhleboBarcodeSeries WHERE SeriesCode = @SeriesCode)
        BEGIN SET @NextNum += 1; SET @SeriesCode = 'PBS' + RIGHT('0000' + CAST(@NextNum AS NVARCHAR(10)), 4); END

        INSERT dbo.LabPhleboBarcodeSeries (CompanyId, BranchId, PhlebotomistId, SeriesCode, FinancialYear, StartNumber, EndNumber, Quantity, SampleCategoryCode, GeneratedBy)
        VALUES (@CompanyId, @BranchId, @PhlebotomistId, @SeriesCode, @FY2, @StartNumber, @EndNumber, @Quantity, @SampleCategoryCode, @CreatedBy);
        DECLARE @SeriesId INT = SCOPE_IDENTITY();

        ;WITH Seq AS (SELECT TOP (@Quantity) @StartNumber - 1 + ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N
                        FROM sys.all_objects a1 CROSS JOIN sys.all_objects a2)
        INSERT dbo.LabPhleboBarcodePool (SeriesId, PhlebotomistId, BarcodeNo, SequenceNo, Status)
        SELECT @SeriesId, @PhlebotomistId, @Prefix + RIGHT('000000' + CAST(N AS NVARCHAR(10)), 6) + @Suffix, N, 1 FROM Seq;

        -- a code the lab or a franchise already uses is never handed out twice
        IF EXISTS (SELECT 1 FROM dbo.LabPhleboBarcodePool p WHERE p.SeriesId = @SeriesId
                     AND (EXISTS (SELECT 1 FROM dbo.SampleCollection sc WHERE sc.BarcodeNo = p.BarcodeNo)
                          OR EXISTS (SELECT 1 FROM dbo.LabFranchiseBarcodePool f WHERE f.BarcodeNo = p.BarcodeNo)))
            THROW 50001, 'Some of these barcode numbers are already in use - not generated.', 1;
        COMMIT TRANSACTION;

        SELECT @SeriesId AS SeriesId, @SeriesCode AS SeriesCode, @SampleCategoryCode AS SampleCategoryCode,
               @Prefix + RIGHT('000000' + CAST(@StartNumber AS NVARCHAR(10)), 6) + @Suffix AS StartBarcode,
               @Prefix + RIGHT('000000' + CAST(@EndNumber AS NVARCHAR(10)), 6) + @Suffix AS EndBarcode, @Quantity AS Quantity;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabPhleboBarcode_GetList
    @BranchId INT, @PhlebotomistId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.SeriesId, s.SeriesCode, s.PhlebotomistId, 'PB' + RIGHT('0000' + CAST(s.PhlebotomistId AS VARCHAR(10)), 4) AS PhleboCode, s.BranchId, b.BranchCode, s.FinancialYear, s.StartNumber, s.EndNumber, s.Quantity, s.Status,
           s.SampleCategoryCode,
           CASE s.SampleCategoryCode WHEN 'F' THEN 'Fasting' WHEN 'PP' THEN 'PP (Post Prandial)' WHEN 'U' THEN 'Urine' ELSE 'General' END AS SampleCategoryName,
           s.GeneratedDate, ISNULL(NULLIF(LTRIM(RTRIM(gu.FullName)), ''), gu.Username) AS GeneratedByName,
           s.CancelledDate, ISNULL(NULLIF(LTRIM(RTRIM(cu.FullName)), ''), cu.Username) AS CancelledByName, s.CancelReason,
           (SELECT TOP 1 BarcodeNo FROM dbo.LabPhleboBarcodePool x WHERE x.SeriesId = s.SeriesId ORDER BY x.SequenceNo) AS StartBarcode,
           (SELECT TOP 1 BarcodeNo FROM dbo.LabPhleboBarcodePool x WHERE x.SeriesId = s.SeriesId ORDER BY x.SequenceNo DESC) AS EndBarcode,
           ISNULL(p.AvailableCount, 0) AS AvailableCount, ISNULL(p.UsedCount, 0) AS UsedCount, ISNULL(p.VoidedCount, 0) AS VoidedCount
      FROM dbo.LabPhleboBarcodeSeries s
      LEFT JOIN dbo.Branchmaster b ON b.BranchID = s.BranchId
      LEFT JOIN dbo.Users gu ON gu.Id = s.GeneratedBy
      LEFT JOIN dbo.Users cu ON cu.Id = s.CancelledBy
      OUTER APPLY (SELECT SUM(CASE WHEN bp.Status = 1 THEN 1 ELSE 0 END) AS AvailableCount, SUM(CASE WHEN bp.Status = 2 THEN 1 ELSE 0 END) AS UsedCount,
                          SUM(CASE WHEN bp.Status = 3 THEN 1 ELSE 0 END) AS VoidedCount
                     FROM dbo.LabPhleboBarcodePool bp WHERE bp.SeriesId = s.SeriesId) p
     WHERE s.BranchId = @BranchId AND s.PhlebotomistId = @PhlebotomistId
     ORDER BY s.SeriesId DESC;
END
GO

-- voids only the still-available codes of a series (used codes keep their history)
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabPhleboBarcode_Cancel
    @BranchId INT, @SeriesId INT, @Reason NVARCHAR(500), @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NULLIF(LTRIM(RTRIM(@Reason)), '') IS NULL BEGIN RAISERROR('A cancellation reason is required.', 16, 1); RETURN; END
    IF NOT EXISTS (SELECT 1 FROM dbo.LabPhleboBarcodeSeries WHERE SeriesId = @SeriesId AND BranchId = @BranchId AND Status = 'Active')
    BEGIN RAISERROR('Series not found or already cancelled.', 16, 1); RETURN; END
    UPDATE dbo.LabPhleboBarcodePool SET Status = 3, VoidedDate = GETDATE(), VoidedBy = @UserId, VoidReason = @Reason WHERE SeriesId = @SeriesId AND Status = 1;
    UPDATE dbo.LabPhleboBarcodeSeries SET Status = 'Cancelled', CancelledDate = GETDATE(), CancelledBy = @UserId, CancelReason = @Reason WHERE SeriesId = @SeriesId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabPhleboBarcode_GetBarcodes
    @BranchId INT, @SeriesId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT p.BarcodeId, p.BarcodeNo, p.SequenceNo, p.Status,
           CASE p.Status WHEN 1 THEN 'Available' WHEN 2 THEN 'Used' WHEN 3 THEN 'Voided' ELSE 'Unknown' END AS StatusName,
           s.SeriesCode, s.Status AS SeriesStatus, s.SampleCategoryCode, p.PhlebotomistId,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS PhlebotomistName,
           lo.BillNo, im.Test_Name, p.UsedDate, p.VoidedDate, p.VoidReason
      FROM dbo.LabPhleboBarcodePool p
      JOIN dbo.LabPhleboBarcodeSeries s ON s.SeriesId = p.SeriesId AND s.BranchId = @BranchId
      LEFT JOIN dbo.Users u ON u.Id = p.PhlebotomistId
      LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = p.LabOrderId
      LEFT JOIN dbo.SampleCollection sc ON sc.samplecollectionID = p.SamplecollectionID
      LEFT JOIN dbo.LabInvestigationMaster im ON im.Test_ID = sc.InvestigationID
     WHERE p.SeriesId = @SeriesId
     ORDER BY p.SequenceNo;
END
GO

-- for the phlebotomist app (later): the barcode must be this phlebotomist's, Available, of an Active series; it is marked
-- Used for the sample. Success = 0 with the reason otherwise. Re-using the same barcode for the same sample is fine.
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabPhleboBarcode_ValidateConsume
    @BarcodeNo NVARCHAR(50), @PhlebotomistId INT, @LabOrderId INT = NULL, @SamplecollectionID BIGINT = NULL, @UserId INT = NULL,
    @Success BIT OUTPUT, @ErrorMessage NVARCHAR(500) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Success = 0; SET @ErrorMessage = NULL;
    SET @BarcodeNo = UPPER(LTRIM(RTRIM(@BarcodeNo)));
    DECLARE @Id BIGINT, @Status TINYINT, @Owner INT, @SeriesStatus NVARCHAR(20), @UsedFor BIGINT;
    SELECT @Id = p.BarcodeId, @Status = p.Status, @Owner = p.PhlebotomistId, @SeriesStatus = s.Status, @UsedFor = p.SamplecollectionID
      FROM dbo.LabPhleboBarcodePool p WITH (UPDLOCK, ROWLOCK) JOIN dbo.LabPhleboBarcodeSeries s ON s.SeriesId = p.SeriesId
     WHERE p.BarcodeNo = @BarcodeNo;
    IF @Id IS NULL BEGIN SET @ErrorMessage = N'This barcode was not issued to any phlebotomist.'; RETURN; END
    IF @Owner <> @PhlebotomistId BEGIN SET @ErrorMessage = N'This barcode is assigned to another phlebotomist.'; RETURN; END
    IF @Status = 2 AND @UsedFor = @SamplecollectionID BEGIN SET @Success = 1; RETURN; END
    IF @Status = 2 BEGIN SET @ErrorMessage = N'This barcode is already used.'; RETURN; END
    IF @Status = 3 OR @SeriesStatus <> 'Active' BEGIN SET @ErrorMessage = N'This barcode was cancelled.'; RETURN; END
    UPDATE dbo.LabPhleboBarcodePool SET Status = 2, LabOrderId = @LabOrderId, SamplecollectionID = @SamplecollectionID, UsedBy = @UserId, UsedDate = GETDATE()
     WHERE BarcodeId = @Id AND Status = 1;
    SET @Success = 1;
END
GO

-- Page under Master > Lab Master (next to Franchise Barcode Assignment)
DECLARE @co INT, @menu INT, @page INT, @view INT, @gen INT, @can INT, @prn INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'MASTER.LAB_MASTER' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'MASTER.LABPHLEBOBARCODES',
             @Title = N'Phlebotomist Barcode Assignment', @Controller = N'LabPhleboBarcodes', @Action = N'Index',
             @Show_In_Menu = 1, @Sort_Order = 125, @Icon = N'bi bi-upc-scan me-2', @Page_ID = @page OUTPUT;
        SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
        SET @gen = NULL; SET @can = NULL; SET @prn = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'GENERATE', @Title = N'Generate series', @Sort_Order = 20, @Control_ID = @gen OUTPUT;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'CANCEL', @Title = N'Cancel series', @Sort_Order = 30, @Control_ID = @can OUTPUT;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'PRINT', @Title = N'Print labels', @Sort_Order = 40, @Control_ID = @prn OUTPUT;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'LabPhleboBarcodes', @Action = N'Index',               @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'LabPhleboBarcodes', @Action = N'GetSeriesListJson',   @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'LabPhleboBarcodes', @Action = N'GetSeriesBarcodesJson', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @gen,  @App = 'WEB', @Http_Method = 'POST', @Controller = N'LabPhleboBarcodes', @Action = N'GenerateSeries',      @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @can,  @App = 'WEB', @Http_Method = 'POST', @Controller = N'LabPhleboBarcodes', @Action = N'CancelSeries',        @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @prn,  @App = 'WEB', @Http_Method = 'GET',  @Controller = N'LabPhleboBarcodes', @Action = N'PrintLabels',         @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2401 applied: Phlebotomist pre-printed barcode assignment.';
GO
