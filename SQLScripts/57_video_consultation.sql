-- ============================================================
-- Script: 57_video_consultation.sql
-- Description: Creates tbl_VideoConsultation for storing
--              Whereby meeting details per OPD booking.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'tbl_VideoConsultation')
BEGIN
    CREATE TABLE tbl_VideoConsultation (
        ConsultationId      INT IDENTITY(1,1) PRIMARY KEY,
        OPDServiceId        INT NOT NULL,
        DoctorId            INT NOT NULL,
        PatientId           INT NOT NULL,
        WherebyMeetingId    NVARCHAR(50)  NOT NULL,
        DoctorHostUrl       NVARCHAR(500) NOT NULL,
        PatientRoomUrl      NVARCHAR(500) NOT NULL,
        RoomNamePrefix      NVARCHAR(100) NOT NULL,
        MeetingStartDate    DATETIME NOT NULL,
        MeetingEndDate      DATETIME NOT NULL,
        GraceTimeMinutes    INT NOT NULL DEFAULT 15,
        Status              NVARCHAR(20)  NOT NULL DEFAULT 'Scheduled',
        DoctorEmailSent     BIT NOT NULL DEFAULT 0,
        PatientEmailSent    BIT NOT NULL DEFAULT 0,
        CreatedDate         DATETIME NOT NULL DEFAULT GETDATE(),
        CreatedBy           NVARCHAR(100) NOT NULL,
        ErrorMessage        NVARCHAR(MAX) NULL
    );

    PRINT 'tbl_VideoConsultation created successfully.';
END
ELSE
BEGIN
    PRINT 'tbl_VideoConsultation already exists. Skipping.';
END
GO
