-- =======================================================================
-- Script Name: Clear_OPD_Transactions.sql
-- Description: Clears ALL OPD Transaction data from Production/Dev DB
--              while preserving Master Data. Also reseeds Identities 
--              and Sequence Counters.
-- WARNING:     This script is IRREVERSIBLE. Please backup before running.
-- =======================================================================

BEGIN TRY
    SET QUOTED_IDENTIFIER ON;
    SET ANSI_NULLS ON;
    BEGIN TRANSACTION;

    PRINT 'Starting Data Deletion...';

    -- 1. Payment Data
    PRINT 'Deleting Payment Line Items...';
    DELETE FROM PaymentLineItem;
    
    PRINT 'Deleting Payment Details...';
    DELETE FROM PaymentDetail;
    
    PRINT 'Deleting Payment Headers...';
    DELETE FROM PaymentHeader;

    -- 2. Service/Booking Data
    PRINT 'Deleting Patient OPD Service Items...';
    DELETE FROM PatientOPDServiceItem;
    
    -- 3. Consultations & Vitals
    PRINT 'Deleting Emr Patient Consultations...';
    DELETE FROM EmrPatientConsultation;
    
    PRINT 'Deleting Patient Vitals...';
    DELETE FROM PatientVitals;
    
    PRINT 'Deleting Video Consultations...';
    DELETE FROM tbl_VideoConsultation;

    -- 4. Main Booking/Registration Data
    PRINT 'Deleting Patient OPD Services...';
    DELETE FROM PatientOPDService;
    
    PRINT 'Deleting Patient Master...';
    DELETE FROM PatientMaster;

    PRINT 'Data Deletion Completed.';

    -- =======================================================================
    -- RESEED IDENTITIES
    -- =======================================================================
    PRINT 'Reseeding Identities...';
    
    DBCC CHECKIDENT ('PaymentLineItem', RESEED, 0);
    DBCC CHECKIDENT ('PaymentDetail', RESEED, 0);
    DBCC CHECKIDENT ('PaymentHeader', RESEED, 0);
    DBCC CHECKIDENT ('PatientOPDServiceItem', RESEED, 0);
    DBCC CHECKIDENT ('EmrPatientConsultation', RESEED, 0);
    DBCC CHECKIDENT ('PatientVitals', RESEED, 0);
    DBCC CHECKIDENT ('PatientOPDService', RESEED, 0);
    DBCC CHECKIDENT ('PatientMaster', RESEED, 0);
    
    -- Try to reseed tbl_VideoConsultation if it has an identity column
    BEGIN TRY
        DBCC CHECKIDENT ('tbl_VideoConsultation', RESEED, 0);
    END TRY
    BEGIN CATCH
        -- Ignore if it doesn't have an identity column
    END CATCH

    PRINT 'Identities Reseeded.';

    -- =======================================================================
    -- RESET SEQUENCES & COUNTERS
    -- =======================================================================
    PRINT 'Resetting Sequence Counters...';
    
    DELETE FROM OPDBillSequence;
    DELETE FROM OPDTokenSequence;
    DELETE FROM PatientCodeCounter;

    PRINT 'Sequence Counters Reset.';

    COMMIT TRANSACTION;
    PRINT 'Script executed successfully. All transactions cleared.';

END TRY
BEGIN CATCH
    ROLLBACK TRANSACTION;
    
    PRINT 'An error occurred during execution. Rolling back...';
    PRINT 'Error Number: ' + CAST(ERROR_NUMBER() AS VARCHAR(10));
    PRINT 'Error Message: ' + ERROR_MESSAGE();
    PRINT 'Error Line: ' + CAST(ERROR_LINE() AS VARCHAR(10));
END CATCH
