namespace EMR.Web.Models.ViewModels;

public class PrintBillViewModel
{
    // ── Hospital / Branch Info ────────────────────────────────────────────────
    public string? HospitalName { get; set; }
    public string? HospitalType { get; set; }
    public string? RegistrationNumber { get; set; }
    public string? HospitalAddress { get; set; }
    public string? HospitalPhone { get; set; }
    public string? HospitalEmergencyPhone { get; set; }
    public string? HospitalEmail { get; set; }
    public string? HospitalWebsite { get; set; }
    public string? HospitalGSTIN { get; set; }
    public string? HospitalLogoPath { get; set; }
    public string? BranchName { get; set; }
    public string? NabhStatus { get; set; }
    public string? NabhCertificateNo { get; set; }
    public DateTime? NabhValidFrom { get; set; }
    public DateTime? NabhValidTo { get; set; }

    // ── Patient Info ──────────────────────────────────────────────────────────
    public string? PatientName { get; set; }
    public string? PatientCode { get; set; }
    public string? PhoneNumber { get; set; }
    public string? EmailId { get; set; }
    public string? Gender { get; set; }
    public int? Age { get; set; }
    public DateTime? DateOfBirth { get; set; }
    public string FormattedAge => EMR.Web.Utils.AgeCalculator.FormatAgePattern(DateOfBirth, Age);
    public string? Address { get; set; }

    // ── Order Info ────────────────────────────────────────────────────────────
    public int LabOrderId { get; set; }
    public string? BillNo { get; set; }
    public string? TokenNo { get; set; }
    public DateTime OrderDate { get; set; }
    public DateTime CreatedDate { get; set; }
    public DateTime? BookingDate { get; set; }
    public string? CollectionType { get; set; }
    public string? PhlebotomistName { get; set; }
    public string? CreatedByName { get; set; }

    // ── Payment Summary ───────────────────────────────────────────────────────
    public decimal GrossAmount { get; set; }
    public decimal DiscountAmount { get; set; }
    public decimal RoundOffAmount { get; set; }
    public decimal GrandTotal { get; set; }
    public decimal ReceivedAmount { get; set; }
    public decimal Balance { get; set; }
    public string PaymentStatus { get; set; } = "U";
    public bool IsActive { get; set; }

    // ── Line Items ────────────────────────────────────────────────────────────
    public List<PrintBillLineItem> LineItems { get; set; } = new();

    // ── Payment Methods ───────────────────────────────────────────────────────
    public List<PrintBillPaymentRow> Payments { get; set; } = new();

    // ── Computed ──────────────────────────────────────────────────────────────
    public string AmountInWords => ConvertToWords(ReceivedAmount);

    private static string ConvertToWords(decimal amount)
    {
        if (amount == 0) return "Zero";
        var rupees = (long)Math.Floor(amount);
        var paise = (int)Math.Round((amount - rupees) * 100);
        var result = RupeesToWords(rupees);
        if (paise > 0) result += $" and {TwoDigitWords(paise)} Paise";
        return result + " Only";
    }

    private static readonly string[] Ones = { "", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine",
        "Ten", "Eleven", "Twelve", "Thirteen", "Fourteen", "Fifteen", "Sixteen", "Seventeen", "Eighteen", "Nineteen" };
    private static readonly string[] Tens = { "", "", "Twenty", "Thirty", "Forty", "Fifty", "Sixty", "Seventy", "Eighty", "Ninety" };

    private static string TwoDigitWords(int n)
    {
        if (n < 20) return Ones[n];
        return (Tens[n / 10] + (n % 10 > 0 ? " " + Ones[n % 10] : "")).Trim();
    }

    private static string RupeesToWords(long n)
    {
        if (n == 0) return "Zero";
        if (n < 0) return "Minus " + RupeesToWords(-n);
        var result = "";
        if (n >= 10000000) { result += RupeesToWords(n / 10000000) + " Crore "; n %= 10000000; }
        if (n >= 100000)   { result += RupeesToWords(n / 100000)   + " Lakh ";  n %= 100000;   }
        if (n >= 1000)     { result += RupeesToWords(n / 1000)     + " Thousand "; n %= 1000;   }
        if (n >= 100)      { result += Ones[n / 100] + " Hundred "; n %= 100; }
        if (n > 0)         { result += TwoDigitWords((int)n); }
        return result.Trim();
    }
}

public class PrintBillLineItem
{
    public string? TestCode { get; set; }
    public string? TestName { get; set; }
    public string? SampleType { get; set; }
    public decimal MRP { get; set; }
    public decimal DiscountAmount { get; set; }
    public decimal Total => MRP - DiscountAmount;
    public bool IsActive { get; set; }
}

public class PrintBillPaymentRow
{
    public string? MethodName { get; set; }
    public decimal PaidAmount { get; set; }
    public string? TransactionRef { get; set; }
    public string? ReceiptNo { get; set; }
}
