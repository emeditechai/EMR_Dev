-- ============================================================================
-- Migration: 2229_emr_refer_doctor_followup.sql
-- Description: OPD EMR (Doctor Dashboard > EMR Clinical Consultation):
--   1. Refer To Doctor (optional): speciality + doctor of that speciality, saved on the consultation and printed on
--      the prescription.
--   2. Follow-Up Date (optional), printed on the prescription; reminder by e-mail and WhatsApp 7 days and 1 day before
--      it, when Hospital Settings > OPD Configuration > "Follow up Notification Required" is Yes for the branch
--      (default No = no reminders). The reminder job (EMR.Web FollowUpReminderService) records when each reminder
--      went out, so none is ever sent twice.
--   Columns are added to the existing tables (all nullable / default No; existing rows unchanged). The two look-ups
--   used by the screen are mapped to the Doctor Dashboard's VIEW. No grant changes. Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.EmrPatientConsultation', 'ReferToSpecialityId') IS NULL
    ALTER TABLE dbo.EmrPatientConsultation ADD ReferToSpecialityId INT NULL;
IF COL_LENGTH('dbo.EmrPatientConsultation', 'ReferToDoctorId') IS NULL
    ALTER TABLE dbo.EmrPatientConsultation ADD ReferToDoctorId INT NULL;
IF COL_LENGTH('dbo.EmrPatientConsultation', 'FollowUpDate') IS NULL
    ALTER TABLE dbo.EmrPatientConsultation ADD FollowUpDate DATE NULL;
-- when the follow-up date was set / last changed: the 7-day reminder goes only when it was set at least 7 days ahead
IF COL_LENGTH('dbo.EmrPatientConsultation', 'FollowUpSetOn') IS NULL
    ALTER TABLE dbo.EmrPatientConsultation ADD FollowUpSetOn DATETIME NULL;
IF COL_LENGTH('dbo.EmrPatientConsultation', 'FollowUpReminder7SentOn') IS NULL
    ALTER TABLE dbo.EmrPatientConsultation ADD FollowUpReminder7SentOn DATETIME NULL;
IF COL_LENGTH('dbo.EmrPatientConsultation', 'FollowUpReminder1SentOn') IS NULL
    ALTER TABLE dbo.EmrPatientConsultation ADD FollowUpReminder1SentOn DATETIME NULL;
GO

IF COL_LENGTH('dbo.HospitalSettings', 'OpdFollowUpNotificationRequired') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD OpdFollowUpNotificationRequired BIT NOT NULL
        CONSTRAINT DF_HospitalSettings_OpdFollowUpNotificationRequired DEFAULT (0);
GO

-- the reminder job looks up consultations by follow-up date
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_EmrPatientConsultation_FollowUpDate' AND object_id = OBJECT_ID('dbo.EmrPatientConsultation'))
    CREATE INDEX IX_EmrPatientConsultation_FollowUpDate ON dbo.EmrPatientConsultation (FollowUpDate)
        INCLUDE (FollowUpSetOn, FollowUpReminder7SentOn, FollowUpReminder1SentOn) WHERE FollowUpDate IS NOT NULL;
GO

DECLARE @page INT, @ctl INT;
DECLARE pg CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'OPD.DOCTORDASHBOARD';
OPEN pg; FETCH NEXT FROM pg INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET', @Controller = N'OPD', @Action = N'EmrReferSpecialities', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET', @Controller = N'OPD', @Action = N'EmrReferDoctors', @Source = 'SEED';
    FETCH NEXT FROM pg INTO @page;
END
CLOSE pg; DEALLOCATE pg;

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2229 applied: EMR refer-to doctor, follow-up date and follow-up reminders.';
GO
