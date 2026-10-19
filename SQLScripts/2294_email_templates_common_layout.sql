-- ============================================================================================================
-- Migration: 2294_email_templates_common_layout.sql
-- Every email now goes out in the common eCare360Plus+ layout (header with the brand plate, white card, standard
-- footer - EMR.Web/Services/EmailLayout.cs), which wraps the template at send time. The two OPD templates seeded by
-- insert_templates.sql carried their own coloured header and card, so they would show a card inside the card: their
-- body is replaced with content only, in the same style. The placeholders ({{PatientName}}, {{DoctorName}}, ...) are
-- unchanged. A template that was edited after seeding (its original header is gone) is left as it is.
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

UPDATE dbo.EmailTemplates
   SET HtmlBody = N'<h2 style="margin:0 0 16px;font-size:20px;line-height:1.3;color:#1b1530;">Booking Confirmation</h2>
<p style="margin:0 0 12px;">Dear <strong>{{PatientName}}</strong>,</p>
<p style="margin:0 0 12px;">Your appointment at <strong>{{HospitalName}}</strong> has been scheduled. Here are your booking details:</p>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#faf9fc;border:1px solid #eeebf3;border-radius:8px;margin:4px 0 18px;border-collapse:separate;">
  <tr><td style="padding:8px 16px;color:#6b6880;font-size:13px;width:38%;">Consulting Doctor</td><td style="padding:8px 16px;color:#1b1530;font-size:14px;font-weight:600;">{{DoctorName}}</td></tr>
  <tr><td style="padding:8px 16px;color:#6b6880;font-size:13px;">Appointment Date</td><td style="padding:8px 16px;color:#1b1530;font-size:14px;font-weight:600;">{{VisitDate}}</td></tr>
  <tr><td style="padding:8px 16px;color:#6b6880;font-size:13px;">Slot Time</td><td style="padding:8px 16px;color:#1b1530;font-size:14px;font-weight:600;">{{SlotTime}}</td></tr>
  <tr><td style="padding:8px 16px;color:#6b6880;font-size:13px;">Token Number</td><td style="padding:8px 16px;color:#ca2e6d;font-size:16px;font-weight:700;">{{TokenNo}}</td></tr>
  <tr><td style="padding:8px 16px;color:#6b6880;font-size:13px;">Total Paid / Fee</td><td style="padding:8px 16px;color:#1b1530;font-size:14px;font-weight:600;">Rs. {{TotalAmount}}</td></tr>
</table>
<div style="margin:0 0 16px;padding:12px 16px;background:#f5f1fa;border-left:4px solid #644098;border-radius:6px;color:#3b2a5c;font-size:13px;line-height:1.6;"><strong>Please note:</strong> arrive at least 15 minutes before your slot for registration and vitals checks.</div>
<p style="margin:0 0 12px;">Warm regards,<br/><strong>{{HospitalName}} Team</strong></p>',
       ModifiedDate = GETDATE()
 WHERE TemplateName = N'Booking Confirmation'
   AND HtmlBody LIKE N'%#667eea 0[%], #764ba2%';
PRINT CONCAT('Booking Confirmation templates updated: ', @@ROWCOUNT);
GO

UPDATE dbo.EmailTemplates
   SET HtmlBody = N'<h2 style="margin:0 0 16px;font-size:20px;line-height:1.3;color:#1b1530;">Your prescription is ready</h2>
<p style="margin:0 0 12px;">Dear <strong>{{PatientName}}</strong>,</p>
<p style="margin:0 0 12px;">Thank you for visiting <strong>{{HospitalName}}</strong>. Your consultation is complete and your prescription is attached to this email.</p>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#faf9fc;border:1px solid #eeebf3;border-radius:8px;margin:4px 0 18px;border-collapse:separate;">
  <tr><td style="padding:8px 16px;color:#6b6880;font-size:13px;width:38%;">Consulting Doctor</td><td style="padding:8px 16px;color:#1b1530;font-size:14px;font-weight:600;">{{DoctorName}}</td></tr>
  <tr><td style="padding:8px 16px;color:#6b6880;font-size:13px;">Date of Visit</td><td style="padding:8px 16px;color:#1b1530;font-size:14px;font-weight:600;">{{VisitDate}}</td></tr>
  <tr><td style="padding:8px 16px;color:#6b6880;font-size:13px;">Queue Token</td><td style="padding:8px 16px;color:#1b1530;font-size:14px;font-weight:600;">{{TokenNo}}</td></tr>
</table>
<div style="margin:0 0 16px;padding:12px 16px;background:#f5f1fa;border-left:4px solid #644098;border-radius:6px;color:#3b2a5c;font-size:13px;line-height:1.6;"><strong>Digital health record:</strong> keep the attached prescription for your records and future visits.</div>
<p style="margin:0 0 12px;">Wishing you a speedy recovery,<br/><strong>{{HospitalName}} Team</strong></p>',
       ModifiedDate = GETDATE()
 WHERE TemplateName = N'Prescription Delivery'
   AND HtmlBody LIKE N'%#11998e 0[%], #38ef7d%';
PRINT CONCAT('Prescription Delivery templates updated: ', @@ROWCOUNT);
GO
PRINT 'Script 2294 applied: email templates use the common eCare360Plus+ layout.';
GO
