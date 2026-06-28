-- =====================================================================
-- Script: 50_emr_patient_consultation.sql
-- Purpose: Create EmrPatientConsultation table to store patient-wise
--          EMR consultation record with dynanmic fields stored as JSON
-- =====================================================================

USE Dev_EMR;
GO

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'EmrPatientConsultation' AND TABLE_SCHEMA = 'dbo')
BEGIN
    CREATE TABLE [dbo].[EmrPatientConsultation] (
        [ConsultationId]   INT             IDENTITY(1,1)   NOT NULL,
        [OPDServiceId]     INT                             NOT NULL,
        [PatientId]        INT                             NOT NULL,
        [DoctorId]         INT                             NOT NULL,
        [TemplateId]       INT                             NOT NULL,
        [OPDBillNo]        NVARCHAR(50)                    NOT NULL,
        [PatientCode]      NVARCHAR(50)                    NOT NULL,
        [PatientName]      NVARCHAR(150)                   NOT NULL,
        [Gender]           NVARCHAR(20)                    NULL,
        [Age]              NVARCHAR(20)                    NULL,
        [MobileNumber]     NVARCHAR(20)                    NULL,
        [VisitDate]        DATETIME                        NOT NULL,
        [VisitType]        NVARCHAR(20)                    NOT NULL, -- 'New' or 'Follow-up'
        [ConsultationType] NVARCHAR(20)                    NOT NULL, -- 'Walking' or 'Video'
        [EmrDataJson]      NVARCHAR(MAX)                   NOT NULL,
        [CreatedBy]        INT                             NOT NULL,
        [CreatedDate]      DATETIME                        NOT NULL        DEFAULT GETDATE(),
        [ModifiedBy]       INT                             NULL,
        [ModifiedDate]     DATETIME                        NULL,
        CONSTRAINT [PK_EmrPatientConsultation] PRIMARY KEY CLUSTERED ([ConsultationId] ASC)
    );
    PRINT 'Table EmrPatientConsultation created.';
END
ELSE
    PRINT 'Table EmrPatientConsultation already exists.';
GO
