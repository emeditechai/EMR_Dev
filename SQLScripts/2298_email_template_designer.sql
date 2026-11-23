-- ============================================================================================================
-- Migration: 2298_email_template_designer.sql
-- Utility > Email Templates: templates are designed on screen (heading, message, details table, note, closing,
-- merge fields picked from a list, live preview, test email) instead of typed as HTML. The design is kept in
-- EmailTemplates.DesignJson; HtmlBody is still the email the OPD sending code uses, built from the design on save.
-- The two standard templates (unchanged since script 2294) get their design so they open in the designer.
-- Templates edited as HTML by hand keep DesignJson NULL and stay editable as HTML. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
IF COL_LENGTH('dbo.EmailTemplates', 'DesignJson') IS NULL
    ALTER TABLE dbo.EmailTemplates ADD DesignJson NVARCHAR(MAX) NULL;
GO

UPDATE dbo.EmailTemplates
   SET DesignJson = N'{"heading":"Booking Confirmation","message":"<p>Dear <strong>{{PatientName}}</strong>,</p><p>Your appointment at <strong>{{HospitalName}}</strong> has been scheduled. Here are your booking details:</p>","rows":[{"label":"Consulting Doctor","value":"{{DoctorName}}","highlight":false},{"label":"Appointment Date","value":"{{VisitDate}}","highlight":false},{"label":"Slot Time","value":"{{SlotTime}}","highlight":false},{"label":"Token Number","value":"{{TokenNo}}","highlight":true},{"label":"Total Paid / Fee","value":"Rs. {{TotalAmount}}","highlight":false}],"noteText":"Please arrive at least 15 minutes before your slot for registration and vitals checks.","noteStyle":"info","closing":"Warm regards,","signature":"{{HospitalName}} Team"}'
 WHERE TemplateName = N'Booking Confirmation' AND DesignJson IS NULL
   AND HtmlBody LIKE N'<h2 style="margin:0 0 16px;font-size:20px;line-height:1.3;color:#1b1530;">Booking Confirmation</h2>%';
PRINT CONCAT('Booking Confirmation designs set: ', @@ROWCOUNT);

UPDATE dbo.EmailTemplates
   SET DesignJson = N'{"heading":"Your prescription is ready","message":"<p>Dear <strong>{{PatientName}}</strong>,</p><p>Thank you for visiting <strong>{{HospitalName}}</strong>. Your consultation is complete and your prescription is attached to this email.</p>","rows":[{"label":"Consulting Doctor","value":"{{DoctorName}}","highlight":false},{"label":"Date of Visit","value":"{{VisitDate}}","highlight":false},{"label":"Queue Token","value":"{{TokenNo}}","highlight":false}],"noteText":"Keep the attached prescription for your records and future visits.","noteStyle":"info","closing":"Wishing you a speedy recovery,","signature":"{{HospitalName}} Team"}'
 WHERE TemplateName = N'Prescription Delivery' AND DesignJson IS NULL
   AND HtmlBody LIKE N'<h2 style="margin:0 0 16px;font-size:20px;line-height:1.3;color:#1b1530;">Your prescription is ready</h2>%';
PRINT CONCAT('Prescription Delivery designs set: ', @@ROWCOUNT);
GO

-- the designer's preview and test email belong to the Email Templates page
DECLARE @page INT;
DECLARE pg CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'UTILITY.EMAILTEMPLATE';
OPEN pg; FETCH NEXT FROM pg INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'EmailTemplate', @Action = N'Preview',  @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'EmailTemplate', @Action = N'SendTest', @Source = 'SEED';
    FETCH NEXT FROM pg INTO @page;
END
CLOSE pg; DEALLOCATE pg;
GO
PRINT 'Script 2298 applied: email template designer.';
GO
