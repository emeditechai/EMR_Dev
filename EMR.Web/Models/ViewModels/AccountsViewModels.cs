using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.ViewModels;

// Utility > Accounts (SQLScripts/2244 - 2246): petty cash, manual vouchers, ledgers and the ledger reports.

public static class AccStatus
{
    public const string Submitted = "S", Approved = "A", Rejected = "R", Cancelled = "C";

    public static string Name(string? s) => s switch
    {
        Submitted => "Waiting approval", Approved => "Approved", Rejected => "Rejected", Cancelled => "Cancelled", _ => "-"
    };

    public static string Badge(string? s) => s switch
    {
        Submitted => "bg-warning-subtle text-warning-emphasis border border-warning-subtle",
        Approved => "bg-success-subtle text-success border border-success-subtle",
        Rejected => "bg-danger-subtle text-danger border border-danger-subtle",
        _ => "bg-secondary-subtle text-secondary-emphasis border border-secondary-subtle"
    };
}

public static class AccLedgerTypes
{
    public static readonly (string Code, string Name)[] All =
    [
        ("GENERAL", "General"), ("EXPENSE", "Expense"), ("INCOME", "Income"), ("CASH", "Cash"), ("BANK", "Bank"),
        ("PARTY", "Party (receivable / payable)"), ("TAX", "Tax"), ("PETTY", "Petty Cash (counter)")
    ];

    public static string Name(string? code) => All.FirstOrDefault(t => t.Code == code).Name ?? code ?? "";
}

public class AccOption
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
    public string? Extra { get; set; }
}

// ── Masters ──────────────────────────────────────────────────────────────────
public class AccLedgerGroupDto
{
    public int LedgerGroupId { get; set; }
    public string GroupName { get; set; } = "";
    public int? ParentGroupId { get; set; }
    public string? ParentGroupName { get; set; }
    public string GroupType { get; set; } = "";
    public bool IsActive { get; set; }
    public bool IsSystem { get; set; }
    public int LedgerCount { get; set; }
}

public class AccLedgerDto
{
    public int LedgerId { get; set; }
    public string? LedgerCode { get; set; }
    public string LedgerName { get; set; } = "";
    public int LedgerGroupId { get; set; }
    public string GroupName { get; set; } = "";
    public string GroupType { get; set; } = "";
    public string LedgerType { get; set; } = "GENERAL";
    public decimal OpeningBalance { get; set; }
    public string OpeningBalanceType { get; set; } = "Dr";
    public bool IsActive { get; set; }
    public bool IsSystem { get; set; }
    public string? Remarks { get; set; }
    public decimal Balance { get; set; }      // Dr positive
}

public class AccLedgersPageViewModel
{
    public List<AccLedgerDto> Ledgers { get; set; } = [];
    public List<AccLedgerGroupDto> Groups { get; set; } = [];
    public string? Search { get; set; }
    public int? GroupId { get; set; }
    public string? LedgerType { get; set; }
}

public class AccLedgerForm
{
    public int LedgerId { get; set; }
    [Required, StringLength(100)] public string LedgerName { get; set; } = "";
    [Range(1, int.MaxValue, ErrorMessage = "Select the ledger group.")] public int LedgerGroupId { get; set; }
    [Required] public string LedgerType { get; set; } = "GENERAL";
    [Range(0, 9999999999.99)] public decimal OpeningBalance { get; set; }
    public string OpeningBalanceType { get; set; } = "Dr";
    [StringLength(300)] public string? Remarks { get; set; }
    public bool IsActive { get; set; } = true;
}

public class AccLedgerGroupForm
{
    public int LedgerGroupId { get; set; }
    [Required, StringLength(100)] public string GroupName { get; set; } = "";
    [Required] public string GroupType { get; set; } = "Expense";
    public int? ParentGroupId { get; set; }
    public bool IsActive { get; set; } = true;
}

public class AccExpenseHeadDto
{
    public int ExpenseHeadId { get; set; }
    public string HeadName { get; set; } = "";
    public int LedgerId { get; set; }
    public string LedgerName { get; set; } = "";
    public decimal? MaxPerVoucher { get; set; }
    public decimal? BillRequiredAbove { get; set; }
    public bool IsActive { get; set; }
}

public class AccExpenseHeadsPageViewModel
{
    public List<AccExpenseHeadDto> Heads { get; set; } = [];
    public List<AccOption> Ledgers { get; set; } = [];
}

public class AccExpenseHeadForm
{
    public int ExpenseHeadId { get; set; }
    [Required, StringLength(100)] public string HeadName { get; set; } = "";
    public int? LedgerId { get; set; }
    public decimal? MaxPerVoucher { get; set; }
    public decimal? BillRequiredAbove { get; set; }
    public bool IsActive { get; set; } = true;
}

public class AccSettingsDto
{
    public int CompanyId { get; set; }
    public bool PettyApprovalRequired { get; set; } = true;
    [Range(0, 99999999)] public decimal PettyAutoApproveLimit { get; set; } = 500;
    [Range(1, 99999999)] public decimal PettyMaxPerVoucher { get; set; } = 5000;
    public bool AllowPettyOverdraw { get; set; }
    public bool AllowSelfApproval { get; set; }
    public bool VoucherApprovalRequired { get; set; }
    [Range(0, 365)] public int BackDateDays { get; set; } = 2;
    [Range(1, 12)] public byte FinancialYearStartMonth { get; set; } = 4;
    public bool PettyGstInputCredit { get; set; }
}

/// <summary>Books of one branch locked up to a date (no entry on or before it); null = open.</summary>
public class AccBranchLockDto
{
    public int BranchId { get; set; }
    public string BranchName { get; set; } = "";
    public DateTime? LockedUpTo { get; set; }
    public string? ModifiedByName { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class AccSettingsPageViewModel
{
    public AccSettingsDto Settings { get; set; } = new();
    public List<AccBranchLockDto> Locks { get; set; } = [];
    // payment mode -> ledger (SQLScripts/2322)
    public List<AccOption> PaymentMethods { get; set; } = [];   // Extra = MethodCode
    public List<AccOption> MoneyLedgers { get; set; } = [];     // cash-in-hand and bank ledgers, Extra = group
    public List<AccOption> Branches { get; set; } = [];
    public List<AccModeLedgerRow> ModeLedgers { get; set; } = [];
}

public class AccPayeeDto
{
    public int PayeeId { get; set; }
    public string PayeeName { get; set; } = "";
    public string? Phone { get; set; }
    public string? GSTIN { get; set; }
    public string? PAN { get; set; }
    public int? DefaultExpenseHeadId { get; set; }
    public string? DefaultHeadName { get; set; }
    public string? Remarks { get; set; }
    public bool IsActive { get; set; } = true;
}

public class AccPayeesPageViewModel
{
    public List<AccPayeeDto> Payees { get; set; } = [];
    public List<AccExpenseHeadDto> Heads { get; set; } = [];
    public string? Search { get; set; }
}

public class AccAttachmentDto
{
    public int AttachmentId { get; set; }
    public string RefType { get; set; } = "";
    public int RefId { get; set; }
    public string FileName { get; set; } = "";
    public string StoredName { get; set; } = "";
    public string ContentType { get; set; } = "";
    public int SizeBytes { get; set; }
    public string? CreatedByName { get; set; }
    public DateTime CreatedDate { get; set; }
    public bool IsImage => ContentType.StartsWith("image/");
    public string SizeText => SizeBytes >= 1024 * 1024 ? $"{SizeBytes / 1048576m:0.0} MB" : $"{Math.Max(1, SizeBytes / 1024)} KB";
}

/// <summary>The attachments box of a petty expense / voucher details page.</summary>
public class AccAttachmentsViewModel
{
    public string Controller { get; set; } = "";
    public string PageCode { get; set; } = "";
    public int RefId { get; set; }
    public bool CanChange { get; set; }
    public List<AccAttachmentDto> Items { get; set; } = [];
}

// ── Petty cash ───────────────────────────────────────────────────────────────
public class AccCounterDto
{
    public int CounterId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = "";
    public string CounterName { get; set; } = "";
    public int? CustodianUserId { get; set; }
    public string? CustodianName { get; set; }
    public decimal FloatAmount { get; set; }
    public int LedgerId { get; set; }
    public string LedgerName { get; set; } = "";
    public int? FundingLedgerId { get; set; }
    public string? FundingLedgerName { get; set; }
    public decimal? LowBalanceAlert { get; set; }
    public bool IsActive { get; set; }
    public decimal Balance { get; set; }            // cash now in the counter (book)
    public decimal PendingAmount { get; set; }      // expenses waiting for approval
    public DateTime? LastClosingDate { get; set; }
    public decimal Available => Balance - PendingAmount;
    public decimal ToReplenish => Math.Max(0, FloatAmount - Balance);
    public bool IsLow => IsActive && LowBalanceAlert.HasValue && Balance <= LowBalanceAlert.Value;
}

public class AccCountersPageViewModel
{
    public List<AccCounterDto> Counters { get; set; } = [];
    public List<AccOption> Branches { get; set; } = [];
    public List<AccOption> Users { get; set; } = [];
    public List<AccOption> FundingLedgers { get; set; } = [];
    public bool CanPickBranch { get; set; }
    public int? OwnBranchId { get; set; }
}

public class AccCounterForm
{
    public int CounterId { get; set; }
    [Range(1, int.MaxValue, ErrorMessage = "Select the branch.")] public int BranchId { get; set; }
    [Required, StringLength(100)] public string CounterName { get; set; } = "";
    public int? CustodianUserId { get; set; }
    [Range(1, 99999999.99, ErrorMessage = "Float amount must be greater than zero.")] public decimal FloatAmount { get; set; }
    public int? FundingLedgerId { get; set; }
    public decimal? LowBalanceAlert { get; set; }
    public bool IsActive { get; set; } = true;
}

public class AccFloatForm
{
    public int CounterId { get; set; }
    [Required] public string Kind { get; set; } = "ISSUE";
    [DataType(DataType.Date)] public DateTime TxnDate { get; set; } = DateTime.Today;
    public decimal Amount { get; set; }
    public int SourceLedgerId { get; set; }
    [StringLength(100)] public string? ReferenceNo { get; set; }
    [StringLength(300)] public string? Remarks { get; set; }
}

public class AccFloatDto
{
    public int FloatId { get; set; }
    public string Kind { get; set; } = "";
    public DateTime TxnDate { get; set; }
    public decimal Amount { get; set; }
    public string SourceLedgerName { get; set; } = "";
    public string? ReferenceNo { get; set; }
    public string? Remarks { get; set; }
    public string? VoucherNo { get; set; }
    public string? CreatedByName { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class AccPettyExpenseLineDto
{
    public int ExpenseHeadId { get; set; }
    public string? HeadName { get; set; }
    public decimal Amount { get; set; }            // paid, GST included
    public decimal GstAmount { get; set; }         // the GST inside Amount, claimed as input credit
    public string? Remarks { get; set; }
}

public class AccPettyExpenseDto
{
    public int ExpenseId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = "";
    public int CounterId { get; set; }
    public string CounterName { get; set; } = "";
    public DateTime ExpenseDate { get; set; }
    public string? PayeeName { get; set; }
    public string? BillNo { get; set; }
    public DateTime? BillDate { get; set; }
    public decimal TotalAmount { get; set; }
    public string? Narration { get; set; }
    public string Status { get; set; } = AccStatus.Submitted;
    public long? TransactionId { get; set; }
    public string? VoucherNo { get; set; }
    public string? Heads { get; set; }
    public int? CreatedBy { get; set; }
    public string? CreatedByName { get; set; }
    public DateTime CreatedDate { get; set; }
    public string? ApprovedByName { get; set; }
    public DateTime? ApprovedDate { get; set; }
    public bool IsAutoApproved { get; set; }
    public string? RejectedByName { get; set; }
    public DateTime? RejectedDate { get; set; }
    public string? RejectReason { get; set; }
    public string? CancelledByName { get; set; }
    public DateTime? CancelledDate { get; set; }
    public string? CancelReason { get; set; }
    public List<AccPettyExpenseLineDto> Lines { get; set; } = [];
    public List<AccAttachmentDto> Attachments { get; set; } = [];
    public int AttachmentCount { get; set; }
    public string DisplayNo => VoucherNo ?? $"PE-{ExpenseId:D5}";
}

public class AccPettyExpenseIndexViewModel
{
    public List<AccPettyExpenseDto> Expenses { get; set; } = [];
    public List<AccCounterDto> Counters { get; set; } = [];
    public DateTime FromDate { get; set; }
    public DateTime ToDate { get; set; }
    public int? CounterId { get; set; }
    public string? Status { get; set; }
    public string? Search { get; set; }
}

public class AccPettyExpenseForm
{
    public int ExpenseId { get; set; }
    [Range(1, int.MaxValue, ErrorMessage = "Select the petty cash counter.")] public int CounterId { get; set; }
    [DataType(DataType.Date)] public DateTime ExpenseDate { get; set; } = DateTime.Today;
    [StringLength(150)] public string? PayeeName { get; set; }
    [StringLength(50)] public string? BillNo { get; set; }
    [DataType(DataType.Date)] public DateTime? BillDate { get; set; }
    [StringLength(500)] public string? Narration { get; set; }
    public List<AccPettyExpenseLineDto> Lines { get; set; } = [];

    // for the screen
    public List<AccCounterDto> Counters { get; set; } = [];
    public List<AccExpenseHeadDto> Heads { get; set; } = [];
    public List<AccPayeeDto> Payees { get; set; } = [];
    public AccSettingsDto Settings { get; set; } = new();
}

public class AccClosingDto
{
    public int ClosingId { get; set; }
    public int CounterId { get; set; }
    public string CounterName { get; set; } = "";
    public string BranchName { get; set; } = "";
    public DateTime ClosingDate { get; set; }
    public decimal BookBalance { get; set; }
    public decimal CountedCash { get; set; }
    public decimal Difference { get; set; }
    public string? Remarks { get; set; }
    public string? VoucherNo { get; set; }
    public string? CreatedByName { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class AccClosingPageViewModel
{
    public List<AccClosingDto> Closings { get; set; } = [];
    public List<AccCounterDto> Counters { get; set; } = [];
    public int? CounterId { get; set; }
}

public class AccClosingForm
{
    public int CounterId { get; set; }
    [DataType(DataType.Date)] public DateTime ClosingDate { get; set; } = DateTime.Today;
    public decimal CountedCash { get; set; }
    public string? DenominationJson { get; set; }
    [StringLength(300)] public string? Remarks { get; set; }
}

// ── Manual vouchers ──────────────────────────────────────────────────────────
public class AccVoucherLineDto
{
    public int LedgerId { get; set; }
    public string? LedgerName { get; set; }
    public decimal DebitAmount { get; set; }
    public decimal CreditAmount { get; set; }
    public string? Narration { get; set; }
}

public class AccVoucherDto
{
    public int VoucherId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = "";
    public string VoucherTypeCode { get; set; } = "";
    public string VoucherTypeName { get; set; } = "";
    public DateTime VoucherDate { get; set; }
    public string? PayeeName { get; set; }
    public string? PaymentMode { get; set; }
    public string? InstrumentNo { get; set; }
    public DateTime? InstrumentDate { get; set; }
    public string? Narration { get; set; }
    public decimal TotalAmount { get; set; }
    public string Status { get; set; } = AccStatus.Submitted;
    public long? TransactionId { get; set; }
    public string? VoucherNo { get; set; }
    public int? CreatedBy { get; set; }
    public string? CreatedByName { get; set; }
    public DateTime CreatedDate { get; set; }
    public string? ApprovedByName { get; set; }
    public DateTime? ApprovedDate { get; set; }
    public string? RejectReason { get; set; }
    public string? CancelledByName { get; set; }
    public DateTime? CancelledDate { get; set; }
    public string? CancelReason { get; set; }
    public List<AccVoucherLineDto> Lines { get; set; } = [];
    public List<AccAttachmentDto> Attachments { get; set; } = [];
    public string DisplayNo => VoucherNo ?? $"DRAFT-{VoucherId:D5}";
}

public class AccVoucherIndexViewModel
{
    public List<AccVoucherDto> Vouchers { get; set; } = [];
    public List<AccOption> Branches { get; set; } = [];
    public DateTime FromDate { get; set; }
    public DateTime ToDate { get; set; }
    public string? TypeCode { get; set; }
    public string? Status { get; set; }
    public int? BranchId { get; set; }
    public string? Search { get; set; }
    public bool CanPickBranch { get; set; }
}

public class AccVoucherForm
{
    [Required] public string VoucherTypeCode { get; set; } = "PMT";
    public int BranchId { get; set; }
    [DataType(DataType.Date)] public DateTime VoucherDate { get; set; } = DateTime.Today;
    [StringLength(150)] public string? PayeeName { get; set; }
    [StringLength(50)] public string? PaymentMode { get; set; }
    [StringLength(100)] public string? InstrumentNo { get; set; }
    [DataType(DataType.Date)] public DateTime? InstrumentDate { get; set; }
    [Required(ErrorMessage = "Enter the narration."), StringLength(500)] public string? Narration { get; set; }
    public List<AccVoucherLineDto> Lines { get; set; } = [];

    // for the screen
    public List<AccOption> Branches { get; set; } = [];
    public List<AccLedgerDto> Ledgers { get; set; } = [];
    public List<string> PaymentModes { get; set; } = [];
    public List<AccPayeeDto> Payees { get; set; } = [];
    public bool CanPickBranch { get; set; }
    public AccSettingsDto Settings { get; set; } = new();
}

// ── Reports ──────────────────────────────────────────────────────────────────
public class AccStatementHeader
{
    public int LedgerId { get; set; }
    public string LedgerName { get; set; } = "";
    public string? LedgerCode { get; set; }
    public string LedgerType { get; set; } = "";
    public string GroupName { get; set; } = "";
    public string GroupType { get; set; } = "";
    public decimal OpeningBalance { get; set; }
}

public class AccStatementRow
{
    public long TransactionId { get; set; }
    public DateTime TransactionDate { get; set; }
    public string? VoucherNo { get; set; }
    public string VoucherTypeName { get; set; } = "";
    public string? VoucherTypeCode { get; set; }
    public string? BranchName { get; set; }
    public string Particulars { get; set; } = "";
    public string? Narration { get; set; }
    public string? PayeeName { get; set; }
    public string? ReferenceType { get; set; }
    public int? ReferenceId { get; set; }
    public decimal DebitAmount { get; set; }
    public decimal CreditAmount { get; set; }
    public string Status { get; set; } = "P";
    public bool IsReversal { get; set; }
    public decimal RunningBalance { get; set; }
}

public class AccDayBookRow
{
    public long TransactionId { get; set; }
    public DateTime TransactionDate { get; set; }
    public string? VoucherNo { get; set; }
    public string VoucherTypeName { get; set; } = "";
    public string? VoucherTypeCode { get; set; }
    public string? BranchName { get; set; }
    public string? PayeeName { get; set; }
    public string? PaymentMode { get; set; }
    public string? InstrumentNo { get; set; }
    public string? VoucherNarration { get; set; }
    public decimal TotalAmount { get; set; }
    public string Status { get; set; } = "P";
    public bool IsReversal { get; set; }
    public string? ReferenceType { get; set; }
    public int? ReferenceId { get; set; }
    public string? EnteredBy { get; set; }
    public string LedgerName { get; set; } = "";
    public decimal DebitAmount { get; set; }
    public decimal CreditAmount { get; set; }
}

public class AccTrialRow
{
    public int LedgerId { get; set; }
    public string LedgerName { get; set; } = "";
    public string? LedgerCode { get; set; }
    public string LedgerType { get; set; } = "";
    public int LedgerGroupId { get; set; }
    public string GroupName { get; set; } = "";
    public string GroupType { get; set; } = "";
    public decimal OpeningBalance { get; set; }
    public decimal PeriodDebit { get; set; }
    public decimal PeriodCredit { get; set; }
    public decimal ClosingBalance { get; set; }
}

public class AccExpenseSummaryRow
{
    public int ExpenseHeadId { get; set; }
    public string HeadName { get; set; } = "";
    public string? BranchName { get; set; }
    public string YearMonth { get; set; } = "";
    public int Vouchers { get; set; }
    public decimal Amount { get; set; }
}

public class AccAuditIssueRow
{
    public string Source { get; set; } = "";
    public string DocNo { get; set; } = "";
    public DateTime DocDate { get; set; }
    public string? BranchName { get; set; }
    public decimal Amount { get; set; }
    public string Issue { get; set; } = "";
    public long? TransactionId { get; set; }
}

public class AccAuditSummaryRow
{
    public string Source { get; set; } = "";
    public int Checked { get; set; }
    public int Problems { get; set; }
}

/// <summary>Filters and data of every Accounts report page (one model, the view uses what it needs).</summary>
public class AccReportViewModel
{
    public string Report { get; set; } = "";          // LedgerStatement | CashBook | BankBook | PettyCashBook | DayBook | VoucherRegister | TrialBalance | IncomeExpense | ExpenseSummary
    public string Title { get; set; } = "";
    public DateTime FromDate { get; set; }
    public DateTime ToDate { get; set; }
    public int? BranchId { get; set; }
    public string? BranchName { get; set; }
    public int? LedgerId { get; set; }
    public int? VoucherTypeId { get; set; }
    public bool CanPickBranch { get; set; }
    public List<AccOption> Branches { get; set; } = [];
    public List<AccOption> Ledgers { get; set; } = [];
    public List<AccOption> VoucherTypes { get; set; } = [];

    public AccStatementHeader? Statement { get; set; }
    public List<AccStatementRow> StatementRows { get; set; } = [];
    public List<AccDayBookRow> DayBook { get; set; } = [];
    public List<AccTrialRow> Trial { get; set; } = [];
    public int UnbalancedVouchers { get; set; }
    public List<AccExpenseSummaryRow> ExpenseSummary { get; set; } = [];
    public List<AccAuditIssueRow> AuditIssues { get; set; } = [];
    public List<AccAuditSummaryRow> AuditSummary { get; set; } = [];
}

public class AccVoucherPrintViewModel
{
    public string Title { get; set; } = "Voucher";
    public string CompanyName { get; set; } = "";
    public string? BranchName { get; set; }
    public string VoucherNo { get; set; } = "";
    public DateTime VoucherDate { get; set; }
    public string? PayeeName { get; set; }
    public string? PaymentMode { get; set; }
    public string? InstrumentNo { get; set; }
    public string? Narration { get; set; }
    public string StatusName { get; set; } = "";
    public string? PreparedBy { get; set; }
    public string? ApprovedBy { get; set; }
    public decimal TotalAmount { get; set; }
    public List<AccVoucherLineDto> Lines { get; set; } = [];
    public string? BackUrl { get; set; }

    public string AmountInWords => Words(TotalAmount);

    private static string Words(decimal amount)
    {
        var rupees = (long)Math.Floor(amount);
        var paise = (int)Math.Round((amount - rupees) * 100);
        var text = "Rupees " + (rupees == 0 ? "Zero" : Num(rupees));
        if (paise > 0) text += " and " + Num(paise) + " Paise";
        return text + " Only";
    }

    private static readonly string[] Ones = ["", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Eleven", "Twelve", "Thirteen",
        "Fourteen", "Fifteen", "Sixteen", "Seventeen", "Eighteen", "Nineteen"];
    private static readonly string[] Tens = ["", "", "Twenty", "Thirty", "Forty", "Fifty", "Sixty", "Seventy", "Eighty", "Ninety"];

    // Indian grouping: crore, lakh, thousand, hundred
    private static string Num(long n)
    {
        if (n < 20) return Ones[n];
        if (n < 100) return (Tens[n / 10] + " " + Ones[n % 10]).Trim();
        if (n < 1000) return (Ones[n / 100] + " Hundred " + Num(n % 100)).Trim();
        if (n < 100000) return (Num(n / 1000) + " Thousand " + Num(n % 1000)).Trim();
        if (n < 10000000) return (Num(n / 100000) + " Lakh " + Num(n % 100000)).Trim();
        return (Num(n / 10000000) + " Crore " + Num(n % 10000000)).Trim();
    }
}

// ── Accounts Phase 1 (SQLScripts/2322) ──────────────────────────────────────────────────────────────────────

/// <summary>Accounts Settings > Payment mode ledgers: a payment method posts to this ledger (BranchId null = every branch).</summary>
public class AccModeLedgerRow
{
    public string MethodCode { get; set; } = "";
    public int? BranchId { get; set; }
    public int? LedgerId { get; set; }
}

public class AccOpeningHeader
{
    public long TransactionId { get; set; }
    public string? VoucherNo { get; set; }
    public DateTime AsOfDate { get; set; }
    public DateTime CreatedDate { get; set; }
    public string? ByUser { get; set; }
}

public class AccOpeningLine
{
    public int LedgerId { get; set; }
    public string LedgerName { get; set; } = "";
    public string? LedgerCode { get; set; }
    public string GroupName { get; set; } = "";
    public string GroupType { get; set; } = "";
    public decimal Debit { get; set; }
    public decimal Credit { get; set; }
}

/// <summary>Utility > Accounts > Opening Balances: one opening entry per branch (asset and liability ledgers).</summary>
public class AccOpeningPageViewModel
{
    public int BranchId { get; set; }
    public string? BranchName { get; set; }
    public bool CanPickBranch { get; set; }
    public List<AccOption> Branches { get; set; } = [];
    public AccOpeningHeader? Header { get; set; }
    public List<AccOpeningLine> Lines { get; set; } = [];
    public DateTime AsOfDate { get; set; }
}

public class AccOpeningForm
{
    public int BranchId { get; set; }
    public DateTime? AsOfDate { get; set; }
    public List<AccOpeningLineForm> Lines { get; set; } = [];
}

public class AccOpeningLineForm
{
    public int LedgerId { get; set; }
    public decimal? Debit { get; set; }
    public decimal? Credit { get; set; }
}

public class AccReconLedgerRow
{
    public string Ledger { get; set; } = "";
    public decimal LedgerBalance { get; set; }
    /// <summary>What the bills say is owed (patient receivable only).</summary>
    public decimal? BillsBalance { get; set; }
    public decimal? PatientCredits { get; set; }
}

public class AccReconIssueRow
{
    public string Module { get; set; } = "";
    public int RefId { get; set; }
    public string? BillNo { get; set; }
    public DateTime? BillDate { get; set; }
    public string? BranchName { get; set; }
    public bool? IsActive { get; set; }
    public bool? IsB2B { get; set; }
    public decimal LedgerDue { get; set; }
    public decimal ExpectedDue { get; set; }
    public decimal Difference { get; set; }
    public string Reason { get; set; } = "";
    public bool Fixable { get; set; }
}

public class AccReconRepairResult
{
    public int BillsPosted { get; set; }
    public int ReceiptsPosted { get; set; }
    public int RefundsPosted { get; set; }
    public int CancellationsPosted { get; set; }
    public int DuplicatesReversed { get; set; }
    public int Total => BillsPosted + ReceiptsPosted + RefundsPosted + CancellationsPosted + DuplicatesReversed;
}

/// <summary>Reports > Accounts > Bill Reconciliation: the receivable ledgers against the bills, with each difference explained.</summary>
public class AccReconViewModel
{
    public int? BranchId { get; set; }
    public bool CanPickBranch { get; set; }
    public List<AccOption> Branches { get; set; } = [];
    public List<AccReconLedgerRow> Ledgers { get; set; } = [];
    public List<AccReconIssueRow> Issues { get; set; } = [];
}
