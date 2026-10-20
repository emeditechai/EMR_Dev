-- ============================================================================================================
-- Migration: 2310_billing_submission_retry_safe.sql
-- One bill per booking: LAB B2C booking and OPD registration create the bill (bill no.) and then save the payment
-- in one request. When the payment was refused (e.g. a split payment that did not add up), the bill stayed behind
-- without payment / token and "Collect" again created a second bill for the same booking.
-- Every booking form now sends a request key (one per booking). The first request claims the key and records the
-- bill it creates; a retry with the same key reuses that bill (same bill no.; the token is issued on that bill when
-- its payment saves) and only retries the payment - or, when the payment had in fact been saved, returns the
-- saved bill. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'dbo.BillingSubmission', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.BillingSubmission (
        RequestKey      UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_BillingSubmission PRIMARY KEY,
        ModuleCode      VARCHAR(10)      NOT NULL,           -- 'LAB' / 'OPD'
        ModuleRefId     INT              NULL,               -- LabOrderId / OPDServiceId once the bill exists
        BillNo          NVARCHAR(50)     NULL,
        PatientId       INT              NULL,
        ItemsSignature  NVARCHAR(1000)   NULL,               -- the billed items, to refuse a retry with other items
        Stage           VARCHAR(10)      NOT NULL CONSTRAINT DF_BillingSubmission_Stage DEFAULT ('CLAIMED'),  -- CLAIMED / CREATED / READY
        CreatedBy       INT              NULL,
        CreatedDate     DATETIME         NOT NULL CONSTRAINT DF_BillingSubmission_Created DEFAULT (GETDATE()),
        UpdatedDate     DATETIME         NOT NULL CONSTRAINT DF_BillingSubmission_Updated DEFAULT (GETDATE())
    );
    CREATE INDEX IX_BillingSubmission_Created ON dbo.BillingSubmission (CreatedDate);
END
GO

-- Claim a booking request.
--   NEW    : first request (or a stale claim that never created a bill) - go ahead and create the bill
--   EXISTS : a bill was already created for this booking - reuse it (HasPayment = its payment is saved already)
--   BUSY   : the same booking is being saved right now by another request (double click)
--   INVALID: the key belongs to another user / module
CREATE OR ALTER PROCEDURE dbo.usp_Api_BillingSubmission_Claim
    @RequestKey UNIQUEIDENTIFIER,
    @ModuleCode VARCHAR(10),
    @UserId     INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status VARCHAR(10);

    BEGIN TRANSACTION;

    -- housekeeping: keys are only needed while a booking is being saved / retried
    DELETE FROM dbo.BillingSubmission WHERE CreatedDate < DATEADD(DAY, -3, GETDATE());

    DECLARE @Mod VARCHAR(10), @RefId INT, @By INT, @Updated DATETIME, @Stage VARCHAR(10);
    SELECT @Mod = ModuleCode, @RefId = ModuleRefId, @By = CreatedBy, @Updated = UpdatedDate, @Stage = Stage
      FROM dbo.BillingSubmission WITH (UPDLOCK, HOLDLOCK)
     WHERE RequestKey = @RequestKey;

    IF @Mod IS NULL
    BEGIN
        INSERT INTO dbo.BillingSubmission (RequestKey, ModuleCode, CreatedBy) VALUES (@RequestKey, @ModuleCode, @UserId);
        SET @Status = 'NEW';
    END
    ELSE IF @Mod <> @ModuleCode OR ISNULL(@By, -1) <> ISNULL(@UserId, -1)
        SET @Status = 'INVALID';
    ELSE IF @RefId IS NOT NULL
        SET @Status = 'EXISTS';
    ELSE IF @Updated < DATEADD(MINUTE, -3, GETDATE())
    BEGIN
        -- an earlier request stopped before it created a bill: take it over
        UPDATE dbo.BillingSubmission SET UpdatedDate = GETDATE(), Stage = 'CLAIMED' WHERE RequestKey = @RequestKey;
        SET @Status = 'NEW';
    END
    ELSE
        SET @Status = 'BUSY';

    COMMIT TRANSACTION;

    SELECT @Status AS Status,
           s.ModuleRefId, s.BillNo, s.PatientId, s.ItemsSignature, s.Stage,
           CAST(CASE WHEN s.ModuleRefId IS NOT NULL AND EXISTS (
                     SELECT 1 FROM dbo.PaymentHeader ph
                      WHERE ph.ModuleCode = s.ModuleCode AND ph.ModuleRefId = s.ModuleRefId AND ph.IsActive = 1)
                THEN 1 ELSE 0 END AS BIT) AS HasPayment,
           CASE s.ModuleCode WHEN 'LAB' THEN (SELECT lo.TokenNo FROM dbo.LabOrder lo WHERE lo.LabOrderId = s.ModuleRefId)
                             WHEN 'OPD' THEN (SELECT o.TokenNo FROM dbo.PatientOPDService o WHERE o.OPDServiceId = s.ModuleRefId) END AS TokenNo
      FROM (SELECT 1 AS x) d
      LEFT JOIN dbo.BillingSubmission s ON s.RequestKey = @RequestKey;
END
GO

-- Record the bill created for a booking request (Stage CREATED right after the bill, READY once its setup is done).
CREATE OR ALTER PROCEDURE dbo.usp_Api_BillingSubmission_Update
    @RequestKey     UNIQUEIDENTIFIER,
    @ModuleRefId    INT,
    @BillNo         NVARCHAR(50)   = NULL,
    @PatientId      INT            = NULL,
    @ItemsSignature NVARCHAR(1000) = NULL,
    @Stage          VARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.BillingSubmission
       SET ModuleRefId    = @ModuleRefId,
           BillNo         = ISNULL(@BillNo, BillNo),
           PatientId      = ISNULL(@PatientId, PatientId),
           ItemsSignature = ISNULL(@ItemsSignature, ItemsSignature),
           Stage          = @Stage,
           UpdatedDate    = GETDATE()
     WHERE RequestKey = @RequestKey;
END
GO

-- A request that stopped before creating a bill (validation message) frees its key, so the retry can claim it.
CREATE OR ALTER PROCEDURE dbo.usp_Api_BillingSubmission_Release
    @RequestKey UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dbo.BillingSubmission WHERE RequestKey = @RequestKey AND ModuleRefId IS NULL;
END
GO

-- EMR.Api api/billing-submissions: allowed wherever LAB B2C booking / OPD registration may save a bill with payment
DECLARE @bp INT, @bc INT;
DECLARE bs CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT Page_ID, Control_ID FROM dbo.PageEndpointMap
     WHERE App = 'WEB' AND ((Controller = N'LabOrderBooking' AND Action = N'SaveBookingWithPayment')
                         OR (Controller = N'OPD' AND Action = N'SaveRegistrationWithPayment'));
OPEN bs; FETCH NEXT FROM bs INTO @bp, @bc;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @bp, @Control_ID = @bc, @App = 'API', @Http_Method = 'POST', @Controller = N'BillingSubmissions', @Action = N'Claim',   @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @bp, @Control_ID = @bc, @App = 'API', @Http_Method = 'POST', @Controller = N'BillingSubmissions', @Action = N'Update',  @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @bp, @Control_ID = @bc, @App = 'API', @Http_Method = 'POST', @Controller = N'BillingSubmissions', @Action = N'Release', @Source = 'SEED';
    FETCH NEXT FROM bs INTO @bp, @bc;
END
CLOSE bs; DEALLOCATE bs;
GO

PRINT 'Script 2310 applied: one bill per booking (retry-safe LAB B2C booking / OPD registration with payment).';
GO
