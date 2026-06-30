-- Truncate and insert updated email templates
DELETE FROM EmailTemplates WHERE TemplateName IN ('Booking Confirmation', 'Prescription Delivery');

INSERT INTO EmailTemplates (BranchId, TemplateName, Subject, HtmlBody, IsActive, CreatedBy, CreatedDate)
VALUES
(
    1,
    'Booking Confirmation',
    'Booking Confirmation at {{HospitalName}}',
    '<div style="font-family: ''Segoe UI'', Roboto, Helvetica, Arial, sans-serif; background-color: #f4f6f8; padding: 30px 15px; color: #333;">
  <div style="max-width: 580px; margin: 0 auto; background-color: #ffffff; border-radius: 12px; box-shadow: 0 4px 15px rgba(0,0,0,0.05); overflow: hidden; border: 1px solid #eef2f5;">
    <!-- Header with deep indigo/purple gradient representing premium hospital brand -->
    <div style="background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); padding: 35px 30px; text-align: center;">
      <h1 style="color: #ffffff; margin: 0; font-size: 24px; font-weight: 600; letter-spacing: 0.5px;">Booking Confirmation</h1>
      <p style="color: #e2d9f3; margin: 5px 0 0 0; font-size: 14px;">Appointment details at {{HospitalName}}</p>
    </div>
    
    <!-- Body Content -->
    <div style="padding: 40px 30px;">
      <p style="margin-top: 0; font-size: 16px; line-height: 1.6; color: #4a5568;">Dear <strong>{{PatientName}}</strong>,</p>
      <p style="font-size: 15px; line-height: 1.6; color: #4a5568; margin-bottom: 25px;">Your appointment has been successfully scheduled. Below are your booking confirmation details:</p>
      
      <!-- Details Card -->
      <div style="background-color: #f8fafc; border: 1px solid #edf2f7; border-radius: 8px; padding: 20px; margin-bottom: 30px;">
        <table style="width: 100%; border-collapse: collapse;">
          <tr>
            <td style="padding: 10px 0; border-bottom: 1px solid #e2e8f0; color: #718096; font-size: 14px; width: 40%;">Consulting Doctor</td>
            <td style="padding: 10px 0; border-bottom: 1px solid #e2e8f0; color: #2d3748; font-size: 15px; font-weight: 600; text-align: right;">{{DoctorName}}</td>
          </tr>
          <tr>
            <td style="padding: 10px 0; border-bottom: 1px solid #e2e8f0; color: #718096; font-size: 14px;">Appointment Date</td>
            <td style="padding: 10px 0; border-bottom: 1px solid #e2e8f0; color: #2d3748; font-size: 15px; font-weight: 600; text-align: right;">{{VisitDate}}</td>
          </tr>
          <tr>
            <td style="padding: 10px 0; border-bottom: 1px solid #e2e8f0; color: #718096; font-size: 14px;">Slot Time</td>
            <td style="padding: 10px 0; border-bottom: 1px solid #e2e8f0; color: #2d3748; font-size: 15px; font-weight: 600; text-align: right;">{{SlotTime}}</td>
          </tr>
          <tr>
            <td style="padding: 10px 0; border-bottom: 1px solid #e2e8f0; color: #718096; font-size: 14px;">Token Number</td>
            <td style="padding: 10px 0; border-bottom: 1px solid #e2e8f0; color: #dd6b20; font-size: 16px; font-weight: 700; text-align: right;">{{TokenNo}}</td>
          </tr>
          <tr>
            <td style="padding: 10px 0; color: #718096; font-size: 14px;">Total Paid / Fee</td>
            <td style="padding: 10px 0; color: #2b6cb0; font-size: 16px; font-weight: 700; text-align: right;">₹ {{TotalAmount}}</td>
          </tr>
        </table>
      </div>
      
      <div style="background-color: #ebf8ff; border-left: 4px solid #3182ce; padding: 15px; border-radius: 4px; margin-bottom: 30px;">
        <p style="margin: 0; font-size: 13px; color: #2b6cb0; line-height: 1.5;">
          <strong>Important Instructions:</strong> Please arrive at least 15 minutes prior to your scheduled slot for registration and vitals checks.
        </p>
      </div>
      
      <p style="margin-top: 0; font-size: 15px; color: #4a5568; line-height: 1.6;">
        Warm regards,<br/>
        <span style="color: #764ba2; font-weight: 600;">{{HospitalName}} Team</span>
      </p>
    </div>
    
    <!-- Footer -->
    <div style="background-color: #f7fafc; padding: 20px; text-align: center; border-top: 1px solid #edf2f7;">
      <p style="margin: 0; font-size: 12px; color: #a0aec0;">This is an automated confirmation email. Please do not reply directly to this message.</p>
    </div>
  </div>
</div>',
    1,
    1,
    GETUTCDATE()
),
(
    1,
    'Prescription Delivery',
    'Your Prescription from {{HospitalName}}',
    '<div style="font-family: ''Segoe UI'', Roboto, Helvetica, Arial, sans-serif; background-color: #f4f6f8; padding: 30px 15px; color: #333;">
  <div style="max-width: 580px; margin: 0 auto; background-color: #ffffff; border-radius: 12px; box-shadow: 0 4px 15px rgba(0,0,0,0.05); overflow: hidden; border: 1px solid #eef2f5;">
    <!-- Header with deep green gradient representing health and successful consultation -->
    <div style="background: linear-gradient(135deg, #11998e 0%, #38ef7d 100%); padding: 35px 30px; text-align: center;">
      <h1 style="color: #ffffff; margin: 0; font-size: 24px; font-weight: 600; letter-spacing: 0.5px;">Your Prescription is Ready</h1>
      <p style="color: #e2fbe9; margin: 5px 0 0 0; font-size: 14px;">Consultation summary from {{HospitalName}}</p>
    </div>
    
    <!-- Body Content -->
    <div style="padding: 40px 30px;">
      <p style="margin-top: 0; font-size: 16px; line-height: 1.6; color: #4a5568;">Dear <strong>{{PatientName}}</strong>,</p>
      <p style="font-size: 15px; line-height: 1.6; color: #4a5568; margin-bottom: 25px;">Thank you for visiting us. Your consultation details have been finalized. Please find your digital prescription attached securely to this email as a PDF/HTML document.</p>
      
      <!-- Details Card -->
      <div style="background-color: #f8fafc; border: 1px solid #edf2f7; border-radius: 8px; padding: 20px; margin-bottom: 30px;">
        <table style="width: 100%; border-collapse: collapse;">
          <tr>
            <td style="padding: 10px 0; border-bottom: 1px solid #e2e8f0; color: #718096; font-size: 14px; width: 40%;">Consulting Doctor</td>
            <td style="padding: 10px 0; border-bottom: 1px solid #e2e8f0; color: #2d3748; font-size: 15px; font-weight: 600; text-align: right;">{{DoctorName}}</td>
          </tr>
          <tr>
            <td style="padding: 10px 0; border-bottom: 1px solid #e2e8f0; color: #718096; font-size: 14px;">Date of Visit</td>
            <td style="padding: 10px 0; border-bottom: 1px solid #e2e8f0; color: #2d3748; font-size: 15px; font-weight: 600; text-align: right;">{{VisitDate}}</td>
          </tr>
          <tr>
            <td style="padding: 10px 0; color: #718096; font-size: 14px;">Queue Token</td>
            <td style="padding: 10px 0; color: #2d3748; font-size: 15px; font-weight: 600; text-align: right;">{{TokenNo}}</td>
          </tr>
        </table>
      </div>
      
      <div style="background-color: #f0fff4; border-left: 4px solid #38a169; padding: 15px; border-radius: 4px; margin-bottom: 30px;">
        <p style="margin: 0; font-size: 13px; color: #276749; line-height: 1.5;">
          <strong>Digital Health Record:</strong> We have attached your prescription file to this email for your convenience and offline access.
        </p>
      </div>
      
      <p style="margin-top: 0; font-size: 15px; color: #4a5568; line-height: 1.6;">
        Wishing you a healthy and speedy recovery!<br/><br/>
        Warm regards,<br/>
        <span style="color: #11998e; font-weight: 600;">{{HospitalName}} Team</span>
      </p>
    </div>
    
    <!-- Footer -->
    <div style="background-color: #f7fafc; padding: 20px; text-align: center; border-top: 1px solid #edf2f7;">
      <p style="margin: 0; font-size: 12px; color: #a0aec0;">This is an automated health record email. Please do not reply directly to this message.</p>
    </div>
  </div>
</div>',
    1,
    1,
    GETUTCDATE()
);
