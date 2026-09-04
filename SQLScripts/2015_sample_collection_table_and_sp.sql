-- ============================================================
-- 2015_sample_collection_table_and_sp.sql
-- Creates SampleCollection table and stored procedure to populate it
-- from LabOrder, expanding profile tests into individual investigations.
-- ============================================================

-- ── 1. Create SampleCollection Table ───────────────────────────
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'SampleCollection')
BEGIN
    CREATE TABLE dbo.SampleCollection (
        samplecollectionID      BIGINT IDENTITY(1,1) PRIMARY KEY,
        Laborderid              INT             NOT NULL,
        BranchID                INT             NOT NULL,
        CompanyID               INT             NOT NULL,
        PatientID               INT             NOT NULL,
        TokenNo                 NVARCHAR(50)    NULL,
        InvestigationID         INT             NOT NULL,
        DepartmentID            INT             NULL,
        DepartmentD             INT             NULL,
        TestcategoryID          INT             NULL,
        TestsubcategoryID       INT             NULL,
        TestsubcategotyID       INT             NULL,
        Orderdate               DATETIME        NOT NULL,
        Bookingdatetime         DATETIME        NULL,
        Is_Active               BIT             NOT NULL DEFAULT 1,
        Samplecollectiondate    DATE            NULL,
        Samplecollectiontime    TIME(0)         NULL,
        Iscancelled             BIT             NOT NULL DEFAULT 0,
        CreatedBy               INT             NULL,
        CreatedDate             DATETIME        NOT NULL DEFAULT GETDATE(),
        ModifiedBy              INT             NULL,
        ModifiedDate            DATETIME        NULL,
        CONSTRAINT FK_SampleCollection_LabOrder FOREIGN KEY (Laborderid) REFERENCES dbo.LabOrder(LabOrderId),
        CONSTRAINT FK_SampleCollection_Patient  FOREIGN KEY (PatientID)  REFERENCES dbo.PatientMaster(PatientId),
        CONSTRAINT FK_SampleCollection_Branch   FOREIGN KEY (BranchID)   REFERENCES dbo.BranchMaster(BranchID)
    );

    CREATE INDEX IX_SampleCollection_Laborderid ON dbo.SampleCollection(Laborderid);
    CREATE INDEX IX_SampleCollection_PatientID ON dbo.SampleCollection(PatientID);
    CREATE INDEX IX_SampleCollection_BranchID ON dbo.SampleCollection(BranchID);
    CREATE INDEX IX_SampleCollection_InvestigationID ON dbo.SampleCollection(InvestigationID);
END
GO

-- ── 2. Create Stored Procedure to Populate SampleCollection ────
CREATE OR ALTER PROCEDURE dbo.usp_CreateSampleCollectionFromLabOrder
    @LabOrderId INT,
    @BranchId   INT = NULL,
    @CompanyId  INT = NULL,
    @CreatedBy  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PatientId       INT;
    DECLARE @OrderDate       DATETIME;
    DECLARE @BookingDateTime DATETIME;
    DECLARE @TokenNo         NVARCHAR(50);
    DECLARE @OrderBranch     INT;

    SELECT 
        @PatientId       = PatientId,
        @OrderDate       = OrderDate,
        @BookingDateTime = BookingDate,
        @TokenNo         = TokenNo,
        @OrderBranch     = BranchId
    FROM dbo.LabOrder
    WHERE LabOrderId = @LabOrderId;

    IF @PatientId IS NULL
    BEGIN
        RAISERROR('LabOrder with ID %d was not found.', 16, 1, @LabOrderId);
        RETURN;
    END

    IF @BranchId IS NULL OR @BranchId <= 0
        SET @BranchId = @OrderBranch;

    IF @CompanyId IS NULL OR @CompanyId <= 0
        SET @CompanyId = 1;

    -- If records already exist for this order, update TokenNo / Bookingdatetime if needed and return
    IF EXISTS (SELECT 1 FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId)
    BEGIN
        UPDATE dbo.SampleCollection
        SET 
            TokenNo = ISNULL(@TokenNo, TokenNo),
            Bookingdatetime = ISNULL(@BookingDateTime, Bookingdatetime)
        WHERE Laborderid = @LabOrderId 
          AND (
              (@TokenNo IS NOT NULL AND (TokenNo IS NULL OR TokenNo <> @TokenNo))
              OR (@BookingDateTime IS NOT NULL AND (Bookingdatetime IS NULL OR Bookingdatetime <> @BookingDateTime))
          );

        SELECT COUNT(1) AS RowsCount FROM dbo.SampleCollection WHERE Laborderid = @LabOrderId;
        RETURN;
    END

    -- Temporary table to hold resolved individual investigation tests
    CREATE TABLE #TestsToInsert (
        InvestigationId INT,
        DepartmentId    INT,
        CategoryId      INT,
        SubCategoryId   INT
    );

    -- 1. Profiles: expand into their child tests based on LabInvestigationProfileDetail
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId)
    SELECT DISTINCT
        t.Test_ID,
        t.Department_ID,
        t.Category_ID,
        t.SubCategory_ID
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.LabInvestigationProfileHeader h 
        ON (h.Test_ID = loi.InvestigationId OR h.Profile_Name = (SELECT TOP 1 Test_Name FROM dbo.LabInvestigationMaster WHERE Test_ID = loi.InvestigationId))
       AND h.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationProfileDetail d 
        ON d.Profile_ID = h.Profile_ID 
       AND d.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationMaster t 
        ON t.Test_ID = d.Test_ID 
       AND t.Status = 1 
       AND t.IsDeleted = 0
    WHERE loi.LabOrderId = @LabOrderId 
      AND loi.IsActive = 1;

    -- 2. Non-profile regular individual tests
    INSERT INTO #TestsToInsert (InvestigationId, DepartmentId, CategoryId, SubCategoryId)
    SELECT DISTINCT
        t.Test_ID,
        t.Department_ID,
        t.Category_ID,
        t.SubCategory_ID
    FROM dbo.LabOrderItem loi
    INNER JOIN dbo.LabInvestigationMaster t 
        ON t.Test_ID = loi.InvestigationId 
       AND t.Status = 1 
       AND t.IsDeleted = 0
    WHERE loi.LabOrderId = @LabOrderId 
      AND loi.IsActive = 1
      AND NOT EXISTS (
          SELECT 1 
          FROM dbo.LabInvestigationProfileHeader h 
          WHERE (h.Test_ID = loi.InvestigationId OR h.Profile_Name = t.Test_Name) 
            AND h.IsDeleted = 0
      );

    -- Insert into SampleCollection table
    INSERT INTO dbo.SampleCollection (
        Laborderid,
        BranchID,
        CompanyID,
        PatientID,
        TokenNo,
        InvestigationID,
        DepartmentID,
        DepartmentD,
        TestcategoryID,
        TestsubcategoryID,
        TestsubcategotyID,
        Orderdate,
        Bookingdatetime,
        Is_Active,
        Samplecollectiondate,
        Samplecollectiontime,
        Iscancelled,
        CreatedBy,
        CreatedDate
    )
    SELECT 
        @LabOrderId,
        @BranchId,
        @CompanyId,
        @PatientId,
        @TokenNo,
        ti.InvestigationId,
        ti.DepartmentId,
        ti.DepartmentId, -- DepartmentD alias
        ti.CategoryId,
        ti.SubCategoryId,
        ti.SubCategoryId, -- TestsubcategotyID alias
        @OrderDate,
        @BookingDateTime,
        1,
        NULL,
        NULL,
        0,
        @CreatedBy,
        GETDATE()
    FROM #TestsToInsert ti;

    DECLARE @InsertedCount INT = @@ROWCOUNT;

    DROP TABLE #TestsToInsert;

    SELECT @InsertedCount AS RowsCount;
END
GO

-- ── 3. Update Token Assignment SP to also sync SampleCollection ──
CREATE OR ALTER PROCEDURE dbo.usp_LAB_AssignTokenOnPayment
    @LabOrderId     INT,
    @TokenNo        NVARCHAR(20)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @BranchId        INT;
    DECLARE @AppointmentDate DATE;
    DECLARE @ExistingToken   NVARCHAR(20);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT  @BranchId        = BranchId,
                @AppointmentDate = CAST(OrderDate AS DATE),
                @ExistingToken   = TokenNo
        FROM    dbo.LabOrder WITH (UPDLOCK, ROWLOCK)
        WHERE   LabOrderId = @LabOrderId;

        IF @ExistingToken IS NOT NULL
        BEGIN
            SET @TokenNo = @ExistingToken;

            -- Sync SampleCollection TokenNo
            UPDATE dbo.SampleCollection
            SET TokenNo = @ExistingToken
            WHERE Laborderid = @LabOrderId AND (TokenNo IS NULL OR TokenNo <> @ExistingToken);

            COMMIT TRANSACTION;
            RETURN;
        END

        EXEC dbo.usp_LAB_GetNextTokenNo @BranchId, @AppointmentDate, @TokenNo OUTPUT;

        UPDATE dbo.LabOrder
        SET    TokenNo = @TokenNo
        WHERE  LabOrderId = @LabOrderId;

        -- Sync SampleCollection TokenNo
        UPDATE dbo.SampleCollection
        SET TokenNo = @TokenNo
        WHERE Laborderid = @LabOrderId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END
GO
