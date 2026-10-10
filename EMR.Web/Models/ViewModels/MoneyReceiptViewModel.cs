using System;
using System.Collections.Generic;

namespace EMR.Web.Models.ViewModels
{
    /// <summary>Money Receipt (A5) of a due collection on an OPD or LAB bill (SQLScripts/2204, usp_MoneyReceipt_Get).</summary>
    public class MoneyReceiptViewModel
    {
        // ── Hospital Branding ─────────────────────────────────────────────────
        public string HospitalName { get; set; } = "eMeditech Hospital";
        public string? HospitalAddress { get; set; }
        public string? HospitalPhone { get; set; }
        public string? HospitalEmail { get; set; }
        public string? HospitalGSTIN { get; set; }
        public string? HospitalLogoPath { get; set; }
        public string? RegistrationNumber { get; set; }

        // ── Receipt ───────────────────────────────────────────────────────────
        public string ReceiptNo { get; set; } = string.Empty;
        public DateTime ReceiptOn { get; set; }
        public string ModuleCode { get; set; } = string.Empty;
        public string? BranchName { get; set; }
        public string? BillNo { get; set; }
        public DateTime? BillDate { get; set; }
        public string? TokenNo { get; set; }
        public string? PatientCode { get; set; }
        public string? PatientName { get; set; }
        public string? PatientPhone { get; set; }
        public decimal NetAmount { get; set; }
        public decimal PaidBefore { get; set; }
        public decimal Amount { get; set; }
        public decimal BalanceAfter { get; set; }
        public string? ReceivedByName { get; set; }
        public List<MoneyReceiptLine> Lines { get; set; } = new();

        /// <summary>Set instead of the receipt when it cannot be printed (not found, another branch, not a due collection).</summary>
        public string? Message { get; set; }

        // ── Computed ──────────────────────────────────────────────────────────
        public string ModuleTitle => ModuleCode == "LAB" ? "Lab" : "OPD";
        public string AmountInWords => ConvertToWords(Amount);

        // Same wording as PrintSettlementReceiptViewModel (Indian Crore / Lakh)
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

    public class MoneyReceiptLine
    {
        public string? MethodName { get; set; }
        public string? MethodCode { get; set; }
        public decimal PaidAmount { get; set; }
        public string? UPIRefNo { get; set; }
        public string? CardLast4 { get; set; }
        public string? ChequeNo { get; set; }
        public string? BankName { get; set; }
        public string? TransactionRef { get; set; }
    }
}
