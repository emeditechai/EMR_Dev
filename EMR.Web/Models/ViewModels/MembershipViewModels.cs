using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.ViewModels;

// ── Membership Plan master ───────────────────────────────────────────────────

public class MembershipPlanListItemViewModel
{
    public int PlanId { get; set; }
    public string PlanCode { get; set; } = string.Empty;
    public string PlanName { get; set; } = string.Empty;
    public string PlanType { get; set; } = string.Empty;
    public decimal CardFee { get; set; }
    public decimal? GstPercent { get; set; }
    public int ValidityDays { get; set; }
    public int MaxMembers { get; set; }
    public int? MinAge { get; set; }
    public decimal WelcomePoints { get; set; }
    public decimal PointsEarnPercent { get; set; }
    public bool IsActive { get; set; }
    public int BenefitCount { get; set; }
    public int CardsIssued { get; set; }
}

public class MembershipPlanIndexViewModel
{
    public List<MembershipPlanListItemViewModel> Plans { get; set; } = [];
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }
}

public class MembershipBenefitViewModel
{
    public int BenefitId { get; set; }
    /// <summary>All | Department | Category</summary>
    public string Scope { get; set; } = "All";
    public int? ScopeRefId { get; set; }
    public string? ScopeName { get; set; }
    /// <summary>P = percentage, A = amount</summary>
    public string DiscountFlag { get; set; } = "P";
    public decimal DiscountValue { get; set; }
    public bool IsExcluded { get; set; }
    public int? FreeQuantity { get; set; }
}

public class MembershipScopeOptionViewModel
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;
}

public class MembershipBenefitScopesViewModel
{
    public List<MembershipScopeOptionViewModel> Departments { get; set; } = [];
    public List<MembershipScopeOptionViewModel> Categories { get; set; } = [];
}

public class MembershipPlanFormViewModel
{
    public int PlanId { get; set; }

    [Display(Name = "Plan Code")]
    public string? PlanCode { get; set; }

    [Required(ErrorMessage = "Plan Name is required.")]
    [StringLength(150, ErrorMessage = "Plan Name cannot exceed 150 characters.")]
    [Display(Name = "Plan Name")]
    public string PlanName { get; set; } = string.Empty;

    [Required]
    [RegularExpression("^(Individual|Family|Senior|Corporate)$", ErrorMessage = "Choose a plan type.")]
    [Display(Name = "Plan Type")]
    public string PlanType { get; set; } = "Individual";

    [Range(0, 9999999.99, ErrorMessage = "Card fee must be zero or more.")]
    [Display(Name = "Card Fee (₹)")]
    public decimal CardFee { get; set; }

    [Range(0, 28, ErrorMessage = "GST must be between 0 and 28 percent.")]
    [Display(Name = "GST on Fee (%)")]
    public decimal? GstPercent { get; set; }

    [Range(1, 36500, ErrorMessage = "Validity must be between 1 and 36500 days.")]
    [Display(Name = "Validity (days)")]
    public int ValidityDays { get; set; } = 365;

    [Range(1, 20, ErrorMessage = "Maximum members must be between 1 and 20.")]
    [Display(Name = "Maximum Members")]
    public int MaxMembers { get; set; } = 1;

    [Range(0, 120, ErrorMessage = "Minimum age must be between 0 and 120.")]
    [Display(Name = "Minimum Age (years)")]
    public int? MinAge { get; set; }

    [Range(0, 9999999, ErrorMessage = "Welcome points must be zero or more.")]
    [Display(Name = "Welcome Points")]
    public decimal WelcomePoints { get; set; }

    [Range(0, 100, ErrorMessage = "Must be between 0 and 100.")]
    [Display(Name = "Points Earned (% of net bill)")]
    public decimal PointsEarnPercent { get; set; }

    [Range(0, 1000, ErrorMessage = "Must be between 0 and 1000.")]
    [Display(Name = "Value of 1 Point (₹)")]
    public decimal PointValue { get; set; } = 1;

    [Range(0, 100, ErrorMessage = "Must be between 0 and 100.")]
    [Display(Name = "Max Bill Paid by Points (%)")]
    public decimal MaxRedeemPercent { get; set; }

    [Range(1, 3650, ErrorMessage = "Must be between 1 and 3650 days.")]
    [Display(Name = "Points Expire After (days)")]
    public int PointsExpiryDays { get; set; } = 365;

    [Display(Name = "Free Home Collection")]
    public bool FreeHomeCollection { get; set; }

    [StringLength(1000, ErrorMessage = "Terms cannot exceed 1000 characters.")]
    [Display(Name = "Terms (printed on the card)")]
    public string? Terms { get; set; }

    [Display(Name = "Is Active?")]
    public bool IsActive { get; set; } = true;

    public int CardsIssued { get; set; }

    /// <summary>The benefit grid, posted as JSON by the form.</summary>
    public string? BenefitsJson { get; set; }
    public List<MembershipBenefitViewModel> Benefits { get; set; } = [];

    /// <summary>Departments and categories a benefit rule can point at (filled by the controller).</summary>
    public MembershipBenefitScopesViewModel Scopes { get; set; } = new();
}

// ── Membership Cards ─────────────────────────────────────────────────────────

public class MembershipPatientSearchItemViewModel
{
    public int PatientId { get; set; }
    public string PatientCode { get; set; } = string.Empty;
    public string PatientName { get; set; } = string.Empty;
    public string? PhoneNumber { get; set; }
    public string? EmailId { get; set; }
    public string? Gender { get; set; }
    public DateTime? DateOfBirth { get; set; }
    public int? Age { get; set; }
    public string? ActiveCardNo { get; set; }
    public string? ActivePlanName { get; set; }
    public DateTime? ActiveValidTo { get; set; }
}

public class MembershipCardListItemViewModel
{
    public int CardId { get; set; }
    public string CardNo { get; set; } = string.Empty;
    public string PlanName { get; set; } = string.Empty;
    public string PlanType { get; set; } = string.Empty;
    public string PatientCode { get; set; } = string.Empty;
    public string PatientName { get; set; } = string.Empty;
    public string? PhoneNumber { get; set; }
    public int MemberCount { get; set; }
    public DateTime ValidFrom { get; set; }
    public DateTime ValidTo { get; set; }
    public decimal FeeAmount { get; set; }
    public string? ReceiptNo { get; set; }
    public decimal PointsBalance { get; set; }
    public string? IssueBranchName { get; set; }
    public string Status { get; set; } = string.Empty;
    public int PrintCount { get; set; }
    public DateTime? WhatsAppSentOn { get; set; }
    public DateTime? EmailSentOn { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class MembershipCardIndexViewModel
{
    public List<MembershipCardListItemViewModel> Cards { get; set; } = [];
    public List<MembershipPlanListItemViewModel> Plans { get; set; } = [];
    public int? PlanId { get; set; }
    public string? Status { get; set; }
    public string? Search { get; set; }
    [DataType(DataType.Date)] public DateTime? FromDate { get; set; }
    [DataType(DataType.Date)] public DateTime? ToDate { get; set; }
}

public class MembershipCardMemberInput
{
    public int PatientId { get; set; }
    public string? Relation { get; set; }
}

public class MembershipCardIssueViewModel
{
    [Range(1, int.MaxValue, ErrorMessage = "Select the membership plan.")]
    [Display(Name = "Membership Plan")]
    public int PlanId { get; set; }

    [Range(1, int.MaxValue, ErrorMessage = "Select the primary member (patient).")]
    public int PrimaryPatientId { get; set; }

    [DataType(DataType.Date)]
    [Display(Name = "Valid From")]
    public DateTime ValidFrom { get; set; } = DateTime.Today;

    [Display(Name = "Payment Method")]
    public int? PaymentMethodId { get; set; }

    [StringLength(100)]
    [Display(Name = "Reference No.")]
    public string? TransactionRef { get; set; }

    [StringLength(250)]
    public string? Remarks { get; set; }

    /// <summary>Family members, posted as JSON by the form: [{"patientId":1,"relation":"Spouse"}].</summary>
    public string? MembersJson { get; set; }

    // Page data
    public List<MembershipPlanListItemViewModel> Plans { get; set; } = [];
    public List<PaymentMethodViewModel> PaymentMethods { get; set; } = [];
}

public class MembershipCardIssueResultViewModel
{
    public int CardId { get; set; }
    public string CardNo { get; set; } = string.Empty;
    public string? ReceiptNo { get; set; }
    public int? PaymentHeaderId { get; set; }
    public decimal FeeAmount { get; set; }
}

public class MembershipCardMemberViewModel
{
    public int CardMemberId { get; set; }
    public int PatientId { get; set; }
    public string PatientCode { get; set; } = string.Empty;
    public string PatientName { get; set; } = string.Empty;
    public string? PhoneNumber { get; set; }
    public string? Gender { get; set; }
    public DateTime? DateOfBirth { get; set; }
    public string Relation { get; set; } = string.Empty;
    public bool IsPrimary { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class MembershipLedgerRowViewModel
{
    public long LedgerId { get; set; }
    public string TxnType { get; set; } = string.Empty;
    public decimal Points { get; set; }
    public decimal Amount { get; set; }
    public DateTime? ExpiresOn { get; set; }
    public decimal BalanceAfter { get; set; }
    public string? ReceiptNo { get; set; }
    public string? Narration { get; set; }
    public DateTime CreatedDate { get; set; }
    public string? CreatedByName { get; set; }
}

public class MembershipAccountingRowViewModel
{
    public long TransactionId { get; set; }
    public string? VoucherNo { get; set; }
    public string? VoucherTypeName { get; set; }
    public DateTime TransactionDate { get; set; }
    public string? ReferenceType { get; set; }
    public string LedgerName { get; set; } = string.Empty;
    public decimal DebitAmount { get; set; }
    public decimal CreditAmount { get; set; }
    public string? Narration { get; set; }
}

public class MembershipCardDetailViewModel
{
    public int CardId { get; set; }
    public int CompanyId { get; set; }
    public string CardNo { get; set; } = string.Empty;
    public int PlanId { get; set; }
    public string PlanCode { get; set; } = string.Empty;
    public string PlanName { get; set; } = string.Empty;
    public string PlanType { get; set; } = string.Empty;
    public int MaxMembers { get; set; }
    public string? Terms { get; set; }
    public bool FreeHomeCollection { get; set; }
    public int IssueBranchId { get; set; }
    public string? IssueBranchName { get; set; }
    public int PrimaryPatientId { get; set; }
    public string PatientCode { get; set; } = string.Empty;
    public string PatientName { get; set; } = string.Empty;
    public string? PhoneNumber { get; set; }
    public string? EmailId { get; set; }
    public string? Gender { get; set; }
    public DateTime? DateOfBirth { get; set; }
    public DateTime ValidFrom { get; set; }
    public DateTime ValidTo { get; set; }
    public string Status { get; set; } = string.Empty;
    public string? StatusReason { get; set; }
    public decimal FeeAmount { get; set; }
    public int? FeePaymentHeaderId { get; set; }
    public string? ReceiptNo { get; set; }
    public string? PaymentMethodName { get; set; }
    public decimal PointsBalance { get; set; }
    public string? Remarks { get; set; }
    public int PrintCount { get; set; }
    public DateTime? LastPrintedOn { get; set; }
    public DateTime? WhatsAppSentOn { get; set; }
    public DateTime? EmailSentOn { get; set; }
    public DateTime CreatedDate { get; set; }
    public string? IssuedByName { get; set; }
    public List<MembershipCardMemberViewModel> Members { get; set; } = [];
    public List<MembershipLedgerRowViewModel> Ledger { get; set; } = [];
    /// <summary>Accounting vouchers posted for the card (Acc_LedgerTransaction), one row per debit / credit line.</summary>
    public List<MembershipAccountingRowViewModel> Accounting { get; set; } = [];

    // Page data: which delivery channels Hospital Settings has switched on for this branch
    public bool WhatsAppEnabled { get; set; }
    public bool EmailEnabled { get; set; }
}
