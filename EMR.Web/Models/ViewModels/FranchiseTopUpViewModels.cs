namespace EMR.Web.Models.ViewModels;

// ── Utility > Franchise Top-Up (SQLScripts/2225) ──────────────────────────────

public class FranchiseTopUpPageViewModel
{
    public List<PaymentMethodViewModel> PaymentMethods { get; set; } = [];
}

/// <summary>Posted by the top-up form.</summary>
public class FranchiseTopUpRequest
{
    public int FranchiseId { get; set; }
    public decimal Amount { get; set; }
    public int PaymentMethodId { get; set; }
    public string? TransactionRef { get; set; }
    public string? Narration { get; set; }
    /// <summary>The wallet balance the screen showed - the top-up is refused if the wallet changed meanwhile.</summary>
    public decimal? ExpectedBalance { get; set; }
}

public class FranchiseTopUpDashboard
{
    public FranchiseTopUpSummary Summary { get; set; } = new();
    public List<FranchiseWalletRow> Franchises { get; set; } = [];
    public List<FranchiseTopUpRow> TopUps { get; set; } = [];
    public List<FranchiseTopUpModeRow> ByMode { get; set; } = [];
    public List<FranchiseTopUpTrendRow> Trend { get; set; } = [];
}

/// <summary>RS1 of usp_FranchiseTopUp_Dashboard.</summary>
public class FranchiseTopUpSummary
{
    public int TopUpCount { get; set; }
    public decimal TopUpAmount { get; set; }
    public decimal HighestTopUp { get; set; }
    public int FranchisesToppedUp { get; set; }
    public int PrepaidFranchiseCount { get; set; }
    public decimal TotalWalletBalance { get; set; }
    public int LowBalanceCount { get; set; }
    public decimal PeriodUsage { get; set; }
}

/// <summary>RS2: one franchise and its wallet.</summary>
public class FranchiseWalletRow
{
    public int Franchise_ID { get; set; }
    public string? Franchise_Code { get; set; }
    public string? Franchise_Name { get; set; }
    public string? Mobile_No { get; set; }
    public bool IsActive { get; set; }
    public bool IsSuspended { get; set; }
    public int CreditFacilityType { get; set; }
    public string CreditFacilityName { get; set; } = string.Empty;
    public decimal WalletBalance { get; set; }
    public DateTime? LastTopUpOn { get; set; }
    public decimal? LastTopUpAmount { get; set; }
    public string? LastReceiptNo { get; set; }
    public decimal PeriodTopUp { get; set; }
    public int PeriodTopUpCount { get; set; }
    public decimal PeriodUsage { get; set; }
    public decimal UsedLast30Days { get; set; }
    public decimal? DaysOfCover { get; set; }
    public bool CanTopUp { get; set; }
    public string? TopUpBlockReason { get; set; }
}

/// <summary>RS3: one top-up.</summary>
public class FranchiseTopUpRow
{
    public long TransactionId { get; set; }
    public string? ReceiptNo { get; set; }
    public DateTime CreatedDate { get; set; }
    public int Franchise_ID { get; set; }
    public string? Franchise_Code { get; set; }
    public string? Franchise_Name { get; set; }
    public decimal Amount { get; set; }
    public decimal BalanceAfter { get; set; }
    public int? PaymentMethodId { get; set; }
    public string? MethodName { get; set; }
    public string? TransactionRef { get; set; }
    public string? Narration { get; set; }
    public int? BranchId { get; set; }
    public string? BranchName { get; set; }
    public int? CreatedBy { get; set; }
    public string? CreatedByName { get; set; }
}

public class FranchiseTopUpModeRow
{
    public int PaymentMethodId { get; set; }
    public string? MethodName { get; set; }
    public int TopUpCount { get; set; }
    public decimal Amount { get; set; }
}

public class FranchiseTopUpTrendRow
{
    public DateTime Day { get; set; }
    public decimal TopUp { get; set; }
    public decimal Used { get; set; }
}

/// <summary>Top-up receipt (A5), from usp_FranchiseTopUp_Receipt plus the branch's hospital settings.</summary>
public class FranchiseTopUpReceiptViewModel
{
    public string HospitalName { get; set; } = "eMeditech Hospital";
    public string? HospitalAddress { get; set; }
    public string? HospitalPhone { get; set; }
    public string? HospitalEmail { get; set; }
    public string? HospitalGSTIN { get; set; }
    public string? HospitalLogoPath { get; set; }
    public string? RegistrationNumber { get; set; }

    public long TransactionId { get; set; }
    public string ReceiptNo { get; set; } = string.Empty;
    public DateTime CreatedDate { get; set; }
    public decimal Amount { get; set; }
    public decimal BalanceBefore { get; set; }
    public decimal BalanceAfter { get; set; }
    public int? PaymentMethodId { get; set; }
    public string? MethodName { get; set; }
    public string? TransactionRef { get; set; }
    public string? Narration { get; set; }
    public int? BranchId { get; set; }
    public string? BranchName { get; set; }
    public int Franchise_ID { get; set; }
    public string? Franchise_Code { get; set; }
    public string? Franchise_Name { get; set; }
    public string? Mobile_No { get; set; }
    public string? Email { get; set; }
    public string? CreatedByName { get; set; }

    /// <summary>Set instead of the receipt when it cannot be printed.</summary>
    public string? Message { get; set; }

    public string AmountInWords => new MoneyReceiptViewModel { Amount = Amount }.AmountInWords;
}
