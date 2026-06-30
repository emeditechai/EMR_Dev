INSERT INTO EmailTemplates (BranchId, TemplateName, Subject, HtmlBody, IsActive, CreatedBy, CreatedDate)
VALUES
(
    1,
    'Booking Confirmation',
    'Booking Confirmation at {{HospitalName}}',
    '<div style="font-family: Arial, sans-serif; padding: 20px; max-width: 600px; margin: 0 auto; border: 1px solid #e0e0e0; border-radius: 8px;">
        <h2 style="color: #2c3e50; border-bottom: 2px solid #3498db; padding-bottom: 10px;">Booking Confirmation</h2>
        <p>Dear <strong>{{PatientName}}</strong>,</p>
        <p>Your appointment has been successfully booked at <strong>{{HospitalName}}</strong>.</p>
        <table style="width: 100%; margin-top: 20px; border-collapse: collapse;">
            <tr>
                <td style="padding: 10px; border-bottom: 1px solid #eee;"><strong>Consulting Doctor:</strong></td>
                <td style="padding: 10px; border-bottom: 1px solid #eee;">{{DoctorName}}</td>
            </tr>
            <tr>
                <td style="padding: 10px; border-bottom: 1px solid #eee;"><strong>Date:</strong></td>
                <td style="padding: 10px; border-bottom: 1px solid #eee;">{{VisitDate}}</td>
            </tr>
            <tr>
                <td style="padding: 10px; border-bottom: 1px solid #eee;"><strong>Slot Time:</strong></td>
                <td style="padding: 10px; border-bottom: 1px solid #eee;">{{SlotTime}}</td>
            </tr>
            <tr>
                <td style="padding: 10px; border-bottom: 1px solid #eee;"><strong>Token Number:</strong></td>
                <td style="padding: 10px; border-bottom: 1px solid #eee; font-size: 1.2em; color: #e74c3c;"><strong>{{TokenNo}}</strong></td>
            </tr>
            <tr>
                <td style="padding: 10px;"><strong>Total Amount:</strong></td>
                <td style="padding: 10px;">{{TotalAmount}}</td>
            </tr>
        </table>
        <p style="margin-top: 30px; font-size: 0.9em; color: #7f8c8d;">Please arrive 15 minutes prior to your scheduled time.</p>
        <p style="margin-top: 20px;">Best Regards,<br/><strong>{{HospitalName}} Team</strong></p>
    </div>',
    1,
    1,
    GETUTCDATE()
),
(
    1,
    'Prescription Delivery',
    'Your Prescription from {{HospitalName}}',
    '<div style="font-family: Arial, sans-serif; padding: 20px; max-width: 600px; margin: 0 auto; border: 1px solid #e0e0e0; border-radius: 8px;">
        <h2 style="color: #27ae60; border-bottom: 2px solid #2ecc71; padding-bottom: 10px;">Your Prescription is Ready</h2>
        <p>Dear <strong>{{PatientName}}</strong>,</p>
        <p>Thank you for visiting <strong>{{HospitalName}}</strong> on {{VisitDate}}.</p>
        <p>Your consultation with <strong>{{DoctorName}}</strong> is now complete. Please find a secure link to your digital prescription attached to this email.</p>
        <div style="background-color: #f8f9fa; padding: 15px; border-left: 4px solid #27ae60; margin: 20px 0;">
            <strong>Token Number:</strong> {{TokenNo}}
        </div>
        <p>If you have any questions or require further assistance, please do not hesitate to contact our support desk.</p>
        <p>Wishing you a speedy recovery!</p>
        <p style="margin-top: 20px;">Best Regards,<br/><strong>{{HospitalName}} Team</strong></p>
    </div>',
    1,
    1,
    GETUTCDATE()
);
