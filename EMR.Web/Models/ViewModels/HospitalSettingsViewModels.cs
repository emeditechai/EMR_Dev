using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Http;

namespace EMR.Web.Models.ViewModels;

public class HospitalSettingsViewModel
{
    public int Id { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;

    [Display(Name = "Hospital Name")]
    [MaxLength(200)]
    public string? HospitalName { get; set; }

    [Display(Name = "Hospital Type")]
    [MaxLength(100)]
    public string? HospitalType { get; set; }

    [Display(Name = "Registration / License Number")]
    [MaxLength(100)]
    public string? RegistrationNumber { get; set; }

    [Display(Name = "Address")]
    [MaxLength(500)]
    public string? Address { get; set; }

    [Display(Name = "Contact Number 1")]
    [MaxLength(20)]
    public string? ContactNumber1 { get; set; }

    [Display(Name = "Contact Number 2")]
    [MaxLength(20)]
    public string? ContactNumber2 { get; set; }

    [Display(Name = "Emergency Helpline Number")]
    [MaxLength(50)]
    public string? EmergencyNumber { get; set; }

    [Display(Name = "Email Address")]
    [EmailAddress]
    [MaxLength(150)]
    public string? EmailAddress { get; set; }

    [Display(Name = "Website")]
    [MaxLength(200)]
    public string? Website { get; set; }

    [Display(Name = "GST Code")]
    [MaxLength(50)]
    public string? GSTCode { get; set; }

    [Display(Name = "Logo Path")]
    [MaxLength(500)]
    public string? LogoPath { get; set; }

    [Display(Name = "Upload Logo")]
    public IFormFile? LogoFile { get; set; }

    // ── Accreditation & Classification ───────────────────────────────────────
    [Display(Name = "NABH Status")]
    [MaxLength(100)]
    public string? NabhStatus { get; set; }

    [Display(Name = "NABH Certificate Number")]
    [MaxLength(100)]
    public string? NabhCertificateNo { get; set; }

    [Display(Name = "NABH Valid From")]
    public string? NabhValidFrom { get; set; } // yyyy-MM-dd for HTML date input

    [Display(Name = "NABH Valid To")]
    public string? NabhValidTo { get; set; } // yyyy-MM-dd for HTML date input

    [Display(Name = "Teaching Hospital")]
    public bool IsTeachingHospital { get; set; } = false;

    [Display(Name = "Check-In Time")]
    public string? CheckInTime { get; set; }   // "HH:mm" string for HTML time input

    [Display(Name = "Check-Out Time")]
    public string? CheckOutTime { get; set; }


    // ── OPD Module Settings ──────────────────────────────────────────────────
    [Display(Name = "Registration Charges Validity (Days)")]
    [Range(0, 3650, ErrorMessage = "Value must be between 0 and 3650 days.")]
    public int? OpdRegistrationValidityDays { get; set; }

    [Display(Name = "Global Patient Search Required")]
    public bool GlobalPatientSearchRequired { get; set; } = false;

    [Display(Name = "Email Notification (Bill/Prescription) Required")]
    public bool EmailNotificationRequired { get; set; } = true;

    [Display(Name = "LAB Email Notification (Billing) Required")]
    public bool LabEmailNotificationRequired { get; set; } = true;

    [Display(Name = "Is Sample Collection Mandatory")]
    public bool IsSampleCollectionMandatory { get; set; } = true;

    [Display(Name = "Barcode Generate at Billing")]
    public bool BarcodeGenerateAtBilling { get; set; } = false;

    [Display(Name = "Enable AI Features at Billing")]
    public bool EnableAiBillingFeatures { get; set; } = false;

    [Display(Name = "Enable Ask AI Features")]
    public bool EnableAskAiFeatures { get; set; } = false;

    [Display(Name = "Token No Generate in Due Payment")]
    public bool TokenGenerateOnDuePayment { get; set; } = false;

    [Display(Name = "Email Notification to Patient (LAB Reports)")]
    public bool LabReportEmailNotificationRequired { get; set; } = false;

    [Display(Name = "Pathologist Approval Required")]
    public bool PathologistApprovalRequired { get; set; } = false;

    [Display(Name = "Show LAB Report Print on List")]
    public bool ShowLabReportPrintOnList { get; set; } = false;

    [Display(Name = "Critical Value Communication Required")]
    public bool CriticalValueCommunicationRequired { get; set; } = false;

    [Display(Name = "Critical Value: Inform Within (minutes)")]
    [Range(1, 1440, ErrorMessage = "Enter between 1 and 1440 minutes.")]
    public int? CriticalValueInformMinutes { get; set; }

    [Display(Name = "Required B2C Bill Print Header")]
    public bool LabB2CBillPrintHeaderRequired { get; set; } = true;

    [Display(Name = "LAB Bill Print Page Size")]
    public string LabBillPrintPageSize { get; set; } = "A4";

    [Display(Name = "Required B2C Lab Report Print Header")]
    public bool LabB2CReportPrintHeaderRequired { get; set; } = true;

    [Display(Name = "Doctor IP Commission Run")]
    [RegularExpression("^(Manual|Automatic|Both)$", ErrorMessage = "Choose Manual, Automatic or Both.")]
    public string DoctorIpComputeMode { get; set; } = "Manual";

    [Display(Name = "Membership Card Number Prefix")]
    [RegularExpression("^[A-Za-z0-9]{1,10}$", ErrorMessage = "Use 1 to 10 letters or digits.")]
    public string MembershipCardNoPrefix { get; set; } = "MC";

    [Display(Name = "Send Membership Card by WhatsApp")]
    public bool MembershipCardWhatsAppRequired { get; set; } = true;

    [Display(Name = "Send Membership Card by Email")]
    public bool MembershipCardEmailRequired { get; set; } = true;

    [Display(Name = "Send Membership Card on Issue")]
    public bool MembershipCardAutoSendOnIssue { get; set; } = true;

    [Display(Name = "Membership Renewal Window (days)")]
    [Range(0, 365, ErrorMessage = "Enter between 0 and 365 days.")]
    public int MembershipRenewalWindowDays { get; set; } = 30;

    [Display(Name = "Manual Discount with Membership Discount")]
    public bool MembershipDiscountWithManualDiscount { get; set; } = false;

    [Display(Name = "OTP for Points Redemption")]
    public bool MembershipRedeemOtpRequired { get; set; } = true;

    [Display(Name = "Points Expiry Run Time")]
    public string? MembershipPointsExpiryTime { get; set; } = "01:00";   // "HH:mm" string for HTML time input

    [Display(Name = "Send Renewal Reminder Emails")]
    public bool MembershipRenewalReminderEnabled { get; set; } = true;

    [Display(Name = "Renewal Reminder Days")]
    [RegularExpression(@"^\s*\d{1,3}(\s*,\s*\d{1,3}){0,9}\s*$", ErrorMessage = "Enter days before expiry separated by commas, e.g. 30,15,1.")]
    public string? MembershipRenewalReminderDays { get; set; } = "30,15,1";

    [Display(Name = "Renewal Reminder Time")]
    public string? MembershipRenewalReminderTime { get; set; } = "10:00";   // "HH:mm" string for HTML time input

    [Display(Name = "Renewal Reminder Message")]
    [StringLength(1000, ErrorMessage = "Message cannot exceed 1000 characters.")]
    public string? MembershipRenewalReminderTemplate { get; set; }

    [Display(Name = "Membership Card Message")]
    [StringLength(1000, ErrorMessage = "Message cannot exceed 1000 characters.")]
    public string? MembershipCardMessageTemplate { get; set; }

    [Display(Name = "Doctor IP Scheduled Time")]
    public string? DoctorIpAutoRunTime { get; set; }   // "HH:mm" string for HTML time input
    [Display(Name = "Required Patient Portal")]
    public bool LabPatientPortalRequired { get; set; }

    [Display(Name = "Follow up Notification Required")]
    public bool OpdFollowUpNotificationRequired { get; set; }

    [Display(Name = "Notification Required for Issue Certificate")]
    public bool OpdCertificateNotificationRequired { get; set; }

    [Display(Name = "Block Billing Until Day Closed")]
    public bool DayClosingBlockBilling { get; set; }

    [Display(Name = "Allow Verifying Own Day Closing")]
    public bool DayClosingAllowSelfVerify { get; set; }

    [Display(Name = "Remind Day Closing Notification")]
    public bool DayClosingLoginReminder { get; set; } = true;

    [Display(Name = "Login Retry Count")]
    [Range(0, 20, ErrorMessage = "Login Retry Count must be between 0 and 20 (0 = no lock).")]
    public int LoginRetryCount { get; set; }

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;

    public DateTime CreatedDate { get; set; }
    public DateTime? LastModifiedDate { get; set; }
}
