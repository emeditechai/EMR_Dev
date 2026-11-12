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

    [Display(Name = "Enable ABHA")]
    public bool EnableAbha { get; set; }

    [Display(Name = "Enable Ayushman Bharat")]
    public bool EnableAyushmanBharat { get; set; }

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

    [Display(Name = "Bill Change Approval Required")]
    public bool BillChangeApprovalRequired { get; set; } = true;

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

    [Display(Name = "Is Phlebotomist App Required")]
    public bool IsPhlebotomistAppRequired { get; set; }

    [Display(Name = "Follow up Notification Required")]
    public bool OpdFollowUpNotificationRequired { get; set; }

    [Display(Name = "Notification Required for Issue Certificate")]
    public bool OpdCertificateNotificationRequired { get; set; }

    [Display(Name = "Show QR on B2B Invoice")]
    public bool ShowQrOnB2BInvoice { get; set; }

    [Display(Name = "Block Billing Until Day Closed")]
    public bool DayClosingBlockBilling { get; set; }

    [Display(Name = "Allow Verifying Own Day Closing")]
    public bool DayClosingAllowSelfVerify { get; set; }

    [Display(Name = "Remind Day Closing Notification")]
    public bool DayClosingLoginReminder { get; set; } = true;

    // ── Pharmacy (SQLScripts/2343) ──
    [Display(Name = "Pharmacy Enabled")]
    public bool PharmacyEnabled { get; set; } = false;

    [Display(Name = "Pharmacy Display Name")]
    [StringLength(150)]
    public string? PharmacyName { get; set; }

    [Display(Name = "Drug Licence No. (Form 20B)")]
    [StringLength(50)]
    public string? PharmacyDrugLicence20B { get; set; }

    [Display(Name = "20B Valid To")]
    public DateTime? PharmacyDrugLicence20BValidTo { get; set; }

    [Display(Name = "Drug Licence No. (Form 21B)")]
    [StringLength(50)]
    public string? PharmacyDrugLicence21B { get; set; }

    [Display(Name = "21B Valid To")]
    public DateTime? PharmacyDrugLicence21BValidTo { get; set; }

    [Display(Name = "Pharmacy GSTIN")]
    [RegularExpression("^[0-9]{2}[A-Za-z]{5}[0-9]{4}[A-Za-z][1-9A-Za-z][Zz][0-9A-Za-z]$", ErrorMessage = "Pharmacy GSTIN is not in the 15-character format.")]
    public string? PharmacyGstin { get; set; }

    [Display(Name = "Pharmacist In-charge")]
    [StringLength(100)]
    public string? PharmacistName { get; set; }

    [Display(Name = "Pharmacist Registration No.")]
    [StringLength(50)]
    public string? PharmacistRegNo { get; set; }

    [Display(Name = "NDPS / Schedule X Licence No.")]
    [StringLength(50)]
    public string? PharmacyNdpsLicenceNo { get; set; }

    [Display(Name = "Pharmacy Contact No.")]
    [StringLength(30)]
    public string? PharmacyContactNo { get; set; }

    [Display(Name = "Allow Negative Stock")]
    public bool PharmacyAllowNegativeStock { get; set; } = false;

    [Display(Name = "Min. Shelf Life for Sale (Days)")]
    [Range(0, 365)]
    public int PharmacyMinShelfLifeSaleDays { get; set; } = 30;

    [Display(Name = "Min. Shelf Life for IPD Issue (Days)")]
    [Range(0, 365)]
    public int PharmacyMinShelfLifeIpdDays { get; set; } = 0;

    [Display(Name = "Min. Shelf Life to Accept at GRN (Days)")]
    [Range(0, 730)]
    public int PharmacyMinShelfLifeGrnDays { get; set; } = 90;

    [Display(Name = "Near-Expiry Alert (Days)")]
    [Range(0, 365)]
    public int PharmacyNearExpiryAlertDays { get; set; } = 90;

    [Display(Name = "Sale Return Allowed Within (Days)")]
    [Range(0, 90)]
    public int PharmacySaleReturnDays { get; set; } = 7;

    [Display(Name = "Loose / Cut-Strip Return Allowed")]
    public bool PharmacyLooseReturnAllowed { get; set; } = false;

    [Display(Name = "Max. Manual Discount % (without approval)")]
    [Range(0, 100)]
    public decimal PharmacyMaxManualDiscountPercent { get; set; } = 10m;

    [Display(Name = "IPD Issue GST Exempt")]
    public bool PharmacyIpdGstExempt { get; set; } = true;

    [Display(Name = "Block Discharge on Pending Pharmacy Indent")]
    public bool PharmacyBlockDischargeOnPendingIndent { get; set; } = true;

    [Display(Name = "Discharge Medicines (TTO) Billed On")]
    public string PharmacyTtoBillingMode { get; set; } = "IPD";

    // ── IPD (SQLScripts/2422) ──
    [Display(Name = "IP Number Prefix")]
    [StringLength(10)]
    public string IpdNumberPrefix { get; set; } = "IP";

    [Display(Name = "Restart IP Number Every Financial Year")]
    public bool IpdNumberResetYearly { get; set; } = true;

    [Display(Name = "Bed Charge Cycle")]
    public string IpdBedChargeMode { get; set; } = "CALENDAR";

    [Display(Name = "Discharge Grace Hour (calendar day)")]
    [Range(0, 23)]
    public int IpdDischargeGraceHour { get; set; } = 12;

    [Display(Name = "Grace Hours (24-hour / check-in-out cycle)")]
    [Range(0, 12)]
    public int IpdHourlyGraceHours { get; set; } = 2;

    [Display(Name = "Default / Fallback Tariff Category")]
    public int? IpdDefaultTariffCategoryId { get; set; }

    [Display(Name = "Room Rent GST Threshold (Rs / day)")]
    [Range(0, 1000000)]
    public decimal IpdRoomGstThreshold { get; set; } = 5000m;

    [Display(Name = "Minimum Advance (days of bed charge)")]
    [Range(0, 60)]
    public int IpdMinAdvanceDays { get; set; } = 0;

    [Display(Name = "Deposit Alert at % of Advance Used")]
    [Range(10, 100)]
    public int IpdDepositAlertPercent { get; set; } = 80;

    [Display(Name = "Pre-admission Estimate Valid (days)")]
    [Range(1, 90)]
    public int IpdEstimateValidityDays { get; set; } = 7;

    [Display(Name = "Expected Discharge Hour")]
    [Range(0, 23)]
    public int IpdDefaultDischargeHour { get; set; } = 11;

    [Display(Name = "Block Bed in a Ward of the Other Gender")]
    public bool IpdBlockWardGenderMismatch { get; set; } = true;

    [Display(Name = "General Consent Required at Admission")]
    public bool IpdConsentRequired { get; set; } = false;

    [Display(Name = "A Vacated Bed Goes To")]
    public string IpdReleaseBedTo { get; set; } = "CLEANING";

    [Display(Name = "Hold a Reserved Bed (hours after expected admission)")]
    [Range(1, 168)]
    public int IpdReservationHoldHours { get; set; } = 24;

    [Display(Name = "Round Off Pharmacy Bill")]
    public bool PharmacyRoundOffBill { get; set; } = true;

    [Display(Name = "Pharmacy Bill Print Format")]
    public string PharmacyBillPrintFormat { get; set; } = "A4";

    [Display(Name = "Send Pharmacy Bill by WhatsApp / E-mail")]
    public bool PharmacyBillNotificationRequired { get; set; } = false;

    [Display(Name = "GRN Not Required")]
    public bool PharmacyGrnNotRequired { get; set; }

    [Display(Name = "Auto Reorder")]
    public bool PharmacyAutoReorderEnabled { get; set; } = false;

    [Display(Name = "Average Sales Over (Days)")]
    public int PharmacyReorderSalesDays { get; set; } = 30;

    [Display(Name = "Safety Stock (Days)")]
    public int PharmacyReorderSafetyDays { get; set; } = 3;

    [Display(Name = "Order to Cover (Days)")]
    public int PharmacyReorderCoverDays { get; set; } = 15;

    [Display(Name = "Apply Supplier Schemes at GRN / PO")]
    public bool PharmacySchemeAutoApply { get; set; } = true;

    [Display(Name = "GS1 DataMatrix Scanning")]
    public bool PharmacyGs1ScanEnabled { get; set; } = true;

    [Display(Name = "Blind Stock Count")]
    public bool PharmacyCountBlind { get; set; } = true;

    [Display(Name = "Recount if Variance Above (%)")]
    public decimal PharmacyCountRecountPercent { get; set; } = 5m;

    [Display(Name = "Cycle Count Every (Days)")]
    public int PharmacyCycleCountDays { get; set; } = 30;

    [Display(Name = "ABC - Class A up to (% of value)")]
    public decimal PharmacyAbcAPercent { get; set; } = 70m;

    [Display(Name = "ABC - Class B up to (% of value)")]
    public decimal PharmacyAbcBPercent { get; set; } = 90m;

    [Display(Name = "Slow Moving if No Sale For (Days)")]
    public int PharmacySlowMovingDays { get; set; } = 60;

    [Display(Name = "Dead Stock if No Sale For (Days)")]
    public int PharmacyDeadStockDays { get; set; } = 180;

    [Display(Name = "Split Payment at Counter")]
    public bool PharmacySplitPaymentEnabled { get; set; } = true;

    [Display(Name = "Suggest Substitute Brands")]
    public bool PharmacySubstituteSuggest { get; set; } = true;

    [Display(Name = "Pull OPD Prescription into Bill")]
    public bool PharmacyRxLinkEnabled { get; set; } = true;

    [Display(Name = "Clinical Safety Checks")]
    public bool PharmacyClinicalChecksEnabled { get; set; } = true;

    [Display(Name = "Block Sale on Major Interaction")]
    public bool PharmacyMajorInteractionBlock { get; set; } = false;

    [Display(Name = "Refill Reminders by WhatsApp")]
    public bool PharmacyRefillReminderEnabled { get; set; } = false;

    [Display(Name = "Remind (Days Before Run-out)")]
    public int PharmacyRefillReminderDaysBefore { get; set; } = 2;

    [Display(Name = "Loyalty Points")]
    public bool PharmacyLoyaltyEnabled { get; set; } = false;

    [Display(Name = "Points Earned per ₹100")]
    public decimal PharmacyLoyaltyEarnPer100 { get; set; } = 1m;

    [Display(Name = "Value of 1 Point (₹)")]
    public decimal PharmacyLoyaltyPointValue { get; set; } = 1m;

    [Display(Name = "Min. Points to Redeem")]
    public int PharmacyLoyaltyMinRedeem { get; set; } = 100;

    [Display(Name = "Max. Bill % Payable by Points")]
    public decimal PharmacyLoyaltyMaxRedeemPercent { get; set; } = 20m;

    [Display(Name = "Points Expire After (Days)")]
    public int PharmacyLoyaltyExpiryDays { get; set; } = 365;

    [Display(Name = "Loyalty Type")]
    public string PharmacyLoyaltyType { get; set; } = "POINTS";

    [Display(Name = "Loyalty Discount %")]
    public decimal PharmacyLoyaltyDiscountPercent { get; set; } = 5m;

    [Display(Name = "Wallet Credit % of Bill")]
    public decimal PharmacyLoyaltyEarnPercent { get; set; } = 1m;

    [Display(Name = "Earn On")]
    public string PharmacyLoyaltyEarnBasis { get; set; } = "NET";

    [Display(Name = "Min. Bill to Earn (₹)")]
    public decimal PharmacyLoyaltyMinBillToEarn { get; set; } = 0m;

    [Display(Name = "Max. Points per Bill")]
    public decimal PharmacyLoyaltyMaxEarnPerBill { get; set; } = 0m;

    [Display(Name = "Earn on a Bill that Used Points")]
    public bool PharmacyLoyaltyEarnOnRedeemBill { get; set; } = true;

    [Display(Name = "Points Usable After (Days)")]
    public int PharmacyLoyaltyLockInDays { get; set; } = 0;

    [Display(Name = "Min. Bill to Use Points (₹)")]
    public decimal PharmacyLoyaltyMinBillToRedeem { get; set; } = 0m;

    [Display(Name = "OTP on WhatsApp to Use Points")]
    public bool PharmacyLoyaltyRedeemOtp { get; set; } = false;

    [Display(Name = "Walk-ins are Members by Mobile")]
    public bool PharmacyLoyaltyWalkinByMobile { get; set; } = false;

    [Display(Name = "WhatsApp the Member")]
    public bool PharmacyLoyaltyNotifyWhatsApp { get; set; } = true;

    [Display(Name = "Expiry Reminder (Days Before)")]
    public int PharmacyLoyaltyExpiryReminderDays { get; set; } = 7;


    [Display(Name = "Login Retry Count")]
    [Range(0, 20, ErrorMessage = "Login Retry Count must be between 0 and 20 (0 = no lock).")]
    public int LoginRetryCount { get; set; }

    [Display(Name = "Login Alert After Wrong Attempts")]
    [Range(0, 20, ErrorMessage = "Login Alert After Wrong Attempts must be between 0 and 20 (0 = no alert).")]
    public int LoginAlertCount { get; set; }

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;

    public DateTime CreatedDate { get; set; }
    public DateTime? LastModifiedDate { get; set; }
}
