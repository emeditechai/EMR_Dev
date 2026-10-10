namespace EMR.Api.Models;

// ── Membership Plan master ───────────────────────────────────────────────────

public class MembershipPlanListItem
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

public class MembershipPlanDetail : MembershipPlanListItem
{
    public int CompanyId { get; set; }
    public decimal PointValue { get; set; }
    public decimal MaxRedeemPercent { get; set; }
    public int PointsExpiryDays { get; set; }
    public bool FreeHomeCollection { get; set; }
    public string? Terms { get; set; }
    public DateTime CreatedDate { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public List<MembershipPlanBenefit> Benefits { get; set; } = [];
}

public class MembershipPlanBenefit
{
    public int BenefitId { get; set; }
    /// <summary>All | Department | Category | Test | Package</summary>
    public string Scope { get; set; } = "All";
    public int? ScopeRefId { get; set; }
    public string? ScopeName { get; set; }
    /// <summary>P = percentage, A = amount</summary>
    public string DiscountFlag { get; set; } = "P";
    public decimal DiscountValue { get; set; }
    public bool IsExcluded { get; set; }
    public int? FreeQuantity { get; set; }
}

public class MembershipPlanSaveRequest
{
    public int PlanId { get; set; }
    public int CompanyId { get; set; }
    public string PlanName { get; set; } = string.Empty;
    public string PlanType { get; set; } = "Individual";
    public decimal CardFee { get; set; }
    public decimal? GstPercent { get; set; }
    public int ValidityDays { get; set; } = 365;
    public int MaxMembers { get; set; } = 1;
    public int? MinAge { get; set; }
    public decimal WelcomePoints { get; set; }
    public decimal PointsEarnPercent { get; set; }
    public decimal PointValue { get; set; } = 1;
    public decimal MaxRedeemPercent { get; set; }
    public int PointsExpiryDays { get; set; } = 365;
    public bool FreeHomeCollection { get; set; }
    public string? Terms { get; set; }
    public bool IsActive { get; set; } = true;
    public List<MembershipPlanBenefit> Benefits { get; set; } = [];
    public int UserId { get; set; }
}

public class MembershipScopeOption
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;
}

public class MembershipBenefitScopes
{
    public List<MembershipScopeOption> Departments { get; set; } = [];
    public List<MembershipScopeOption> Categories { get; set; } = [];
}

// ── Membership Cards ─────────────────────────────────────────────────────────

public class MembershipPatientSearchItem
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

public class MembershipCardMemberRequest
{
    public int PatientId { get; set; }
    public string? Relation { get; set; }
}

public class MembershipCardIssueRequest
{
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public int PlanId { get; set; }
    public int PrimaryPatientId { get; set; }
    public DateTime? ValidFrom { get; set; }
    public List<MembershipCardMemberRequest> Members { get; set; } = [];
    public int? PaymentMethodId { get; set; }
    public string? TransactionRef { get; set; }
    public string? Remarks { get; set; }
    public int UserId { get; set; }
}

public class MembershipCardIssueResult
{
    public int CardId { get; set; }
    public string CardNo { get; set; } = string.Empty;
    public string? ReceiptNo { get; set; }
    public int? PaymentHeaderId { get; set; }
    public decimal FeeAmount { get; set; }
}

public class MembershipCardListItem
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

public class MembershipCardDetail
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
    public List<MembershipCardMember> Members { get; set; } = [];
    public List<MembershipLedgerRow> Ledger { get; set; } = [];
    /// <summary>Accounting vouchers posted for the card (Acc_LedgerTransaction), one row per debit / credit line.</summary>
    public List<MembershipAccountingRow> Accounting { get; set; } = [];
}

public class MembershipAccountingRow
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

public class MembershipCardMember
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

public class MembershipLedgerRow
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

public class MembershipCardAddMemberRequest
{
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public int PatientId { get; set; }
    public string? Relation { get; set; }
    public int UserId { get; set; }
}

public class MembershipCardStatusRequest
{
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string Status { get; set; } = string.Empty;
    public string? Reason { get; set; }
    public int UserId { get; set; }
}

public class MembershipCardMarkRequest
{
    public int CompanyId { get; set; }
    public int UserId { get; set; }
    /// <summary>For mark-sent: WhatsApp | Email</summary>
    public string? Channel { get; set; }
}
