-- ============================================================================
-- Script: 2085_clear_rejection_reason_on_recollect_or_collect.sql
-- Description: When sample is collected (Status 2) in Sample Collection,
--              clear RejectionReasonId and RejectionReason so it returns to a clean state.
-- ============================================================================

CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_UpdateStatus
    @SampleCollectionId  BIGINT,
    @CollectionstatusID  INT,
    @SampleCollectionDate DATE = NULL,
    @SampleCollectionTime TIME(0) = NULL,
    @UserId              INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @SampleCollectionId IS NULL OR @SampleCollectionId <= 0
    BEGIN
        RAISERROR('Valid SampleCollectionId is required.', 16, 1);
        RETURN;
    END

    IF @CollectionstatusID IS NULL OR @CollectionstatusID <= 0
    BEGIN
        RAISERROR('Valid CollectionstatusID is required.', 16, 1);
        RETURN;
    END

    DECLARE @LabOrderId       INT;
    DECLARE @ProfileId        INT;
    DECLARE @ProfileName      NVARCHAR(200);
    DECLARE @BranchId         INT;
    DECLARE @GeneratedBarcode NVARCHAR(50);
    DECLARE @BookingDate      DATE;

    SELECT 
        @LabOrderId  = sc.Laborderid,
        @ProfileId   = sc.ProfileId,
        @ProfileName = sc.ProfileName,
        @BranchId    = ISNULL(lo.BranchId, ISNULL(sc.BranchID, 1)),
        @BookingDate = CAST(ISNULL(lo.BookingDate, lo.OrderDate) AS DATE)
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
    WHERE sc.samplecollectionID = @SampleCollectionId;

    IF @LabOrderId IS NULL
    BEGIN
        RAISERROR('Sample record not found.', 16, 1);
        RETURN;
    END

    IF @CollectionstatusID = 2 AND @BookingDate IS NOT NULL AND @BookingDate <> CAST(GETDATE() AS DATE)
    BEGIN
        DECLARE @BDateStr VARCHAR(10) = CONVERT(VARCHAR(10), @BookingDate, 120);
        RAISERROR('Sample collection is only permitted on the booking date (%s).', 16, 1, @BDateStr);
        RETURN;
    END

    IF @CollectionstatusID = 2
    BEGIN
        IF @SampleCollectionDate IS NULL
            SET @SampleCollectionDate = CAST(GETDATE() AS DATE);
        IF @SampleCollectionTime IS NULL
            SET @SampleCollectionTime = CAST(GETDATE() AS TIME(0));

        IF @ProfileId IS NOT NULL OR @ProfileName IS NOT NULL
        BEGIN
            SELECT TOP 1 @GeneratedBarcode = BarcodeNo 
            FROM dbo.SampleCollection 
            WHERE Laborderid = @LabOrderId 
              AND (
                  (@ProfileId IS NOT NULL AND ProfileId = @ProfileId)
                  OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND ProfileName = @ProfileName)
              )
              AND BarcodeNo IS NOT NULL;

            IF @GeneratedBarcode IS NULL
            BEGIN
                EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @GeneratedBarcode OUTPUT;
            END

            UPDATE sc
            SET 
                CollectionstatusID   = 2,
                Samplecollectiondate = @SampleCollectionDate,
                Samplecollectiontime = @SampleCollectionTime,
                BarcodeNo            = ISNULL(sc.BarcodeNo, @GeneratedBarcode),
                RejectionReasonId    = NULL,
                RejectionReason      = NULL,
                ModifiedBy           = @UserId,
                ModifiedDate         = GETDATE()
            FROM dbo.SampleCollection sc
            WHERE sc.samplecollectionID = @SampleCollectionId;
        END
        ELSE
        BEGIN
            SELECT @GeneratedBarcode = BarcodeNo FROM dbo.SampleCollection WHERE samplecollectionID = @SampleCollectionId;

            IF @GeneratedBarcode IS NULL
            BEGIN
                EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @GeneratedBarcode OUTPUT;
            END

            UPDATE sc
            SET 
                CollectionstatusID   = 2,
                Samplecollectiondate = @SampleCollectionDate,
                Samplecollectiontime = @SampleCollectionTime,
                BarcodeNo            = @GeneratedBarcode,
                RejectionReasonId    = NULL,
                RejectionReason      = NULL,
                ModifiedBy           = @UserId,
                ModifiedDate         = GETDATE()
            FROM dbo.SampleCollection sc
            WHERE sc.samplecollectionID = @SampleCollectionId;
        END

        -- Clear rejection in labentrydetails as well
        UPDATE led
        SET led.RejectionReasonId = NULL,
            led.RejectionReason = NULL
        FROM dbo.labentrydetails led
        INNER JOIN dbo.SampleCollection sc ON sc.Laborderid = led.laborderid AND sc.InvestigationID = led.investigationid
        WHERE sc.samplecollectionID = @SampleCollectionId;
    END
    ELSE IF @CollectionstatusID = 1
    BEGIN
        UPDATE sc
        SET 
            CollectionstatusID   = 1,
            Samplecollectiondate = NULL,
            Samplecollectiontime = NULL,
            BarcodeNo            = NULL,
            RejectionReasonId    = NULL,
            RejectionReason      = NULL,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.samplecollectionID = @SampleCollectionId;
    END
    ELSE
    BEGIN
        UPDATE sc
        SET 
            CollectionstatusID   = @CollectionstatusID,
            Samplecollectiondate = @SampleCollectionDate,
            Samplecollectiontime = @SampleCollectionTime,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.samplecollectionID = @SampleCollectionId;
    END
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_SampleCollection_UpdateProfileStatus
    @LabOrderId          INT,
    @ProfileId           INT = NULL,
    @ProfileName         NVARCHAR(200) = NULL,
    @CollectionstatusID  INT,
    @SampleCollectionDate DATE = NULL,
    @SampleCollectionTime TIME(0) = NULL,
    @UserId              INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @LabOrderId IS NULL OR @LabOrderId <= 0
    BEGIN
        RAISERROR('Valid LabOrderId is required.', 16, 1);
        RETURN;
    END

    IF @CollectionstatusID IS NULL OR @CollectionstatusID <= 0
    BEGIN
        RAISERROR('Valid CollectionstatusID is required.', 16, 1);
        RETURN;
    END

    DECLARE @BranchId    INT = 1;
    DECLARE @BookingDate DATE;

    SELECT TOP 1 
        @BranchId    = ISNULL(lo.BranchId, ISNULL(sc.BranchID, 1)),
        @BookingDate = CAST(ISNULL(lo.BookingDate, lo.OrderDate) AS DATE)
    FROM dbo.SampleCollection sc
    LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
    WHERE sc.Laborderid = @LabOrderId;

    IF @CollectionstatusID = 2 AND @BookingDate IS NOT NULL AND @BookingDate <> CAST(GETDATE() AS DATE)
    BEGIN
        DECLARE @BDateStr2 VARCHAR(10) = CONVERT(VARCHAR(10), @BookingDate, 120);
        RAISERROR('Sample collection is only permitted on the booking date (%s).', 16, 1, @BDateStr2);
        RETURN;
    END

    IF @CollectionstatusID = 2
    BEGIN
        IF @SampleCollectionDate IS NULL
            SET @SampleCollectionDate = CAST(GETDATE() AS DATE);
        IF @SampleCollectionTime IS NULL
            SET @SampleCollectionTime = CAST(GETDATE() AS TIME(0));

        DECLARE @ExistingBarcode NVARCHAR(50);
        SELECT TOP 1 @ExistingBarcode = sc.BarcodeNo
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND (
              (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
              OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
          )
          AND sc.BarcodeNo IS NOT NULL;

        IF @ExistingBarcode IS NULL
        BEGIN
            EXEC dbo.usp_Lab_GetNextBarcodeNo @BranchId = @BranchId, @BarcodeNo = @ExistingBarcode OUTPUT;
        END

        UPDATE sc
        SET 
            CollectionstatusID   = 2,
            Samplecollectiondate = @SampleCollectionDate,
            Samplecollectiontime = @SampleCollectionTime,
            BarcodeNo            = ISNULL(sc.BarcodeNo, @ExistingBarcode),
            RejectionReasonId    = NULL,
            RejectionReason      = NULL,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1
          AND sc.Iscancelled = 0
          AND (
              (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
              OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
          );

        -- Clear rejection in labentrydetails as well
        UPDATE led
        SET led.RejectionReasonId = NULL,
            led.RejectionReason = NULL
        FROM dbo.labentrydetails led
        INNER JOIN dbo.SampleCollection sc ON sc.Laborderid = led.laborderid AND sc.InvestigationID = led.investigationid
        WHERE sc.Laborderid = @LabOrderId
          AND (
              (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
              OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
          );
    END
    ELSE IF @CollectionstatusID = 1
    BEGIN
        UPDATE sc
        SET 
            CollectionstatusID   = 1,
            Samplecollectiondate = NULL,
            Samplecollectiontime = NULL,
            BarcodeNo            = NULL,
            RejectionReasonId    = NULL,
            RejectionReason      = NULL,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1
          AND sc.Iscancelled = 0
          AND (
              (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
              OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
          );
    END
    ELSE
    BEGIN
        UPDATE sc
        SET 
            CollectionstatusID   = @CollectionstatusID,
            Samplecollectiondate = @SampleCollectionDate,
            Samplecollectiontime = @SampleCollectionTime,
            ModifiedBy           = @UserId,
            ModifiedDate         = GETDATE()
        FROM dbo.SampleCollection sc
        WHERE sc.Laborderid = @LabOrderId
          AND sc.Is_Active = 1
          AND sc.Iscancelled = 0
          AND (
              (@ProfileId IS NOT NULL AND sc.ProfileId = @ProfileId)
              OR (@ProfileId IS NULL AND @ProfileName IS NOT NULL AND sc.ProfileName = @ProfileName)
          );
    END
END;
GO
