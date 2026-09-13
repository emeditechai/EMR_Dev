using System;
using System.Collections.Generic;
using EMR.Web.Models.DTOs;

namespace EMR.Web.Models.ViewModels
{
    public class PrintSettlementReceiptViewModel
    {
        // ── Hospital Branding ─────────────────────────────────────────────────
        public string HospitalName { get; set; } = "eMeditech Hospital";
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

        // ── Receipt Details ───────────────────────────────────────────────────
        public string ReceiptNo { get; set; } = string.Empty;
        public DateTime PaymentDate { get; set; }
        public DateTime CreatedDate { get; set; }
        public decimal TotalAmount { get; set; }
        public int SettledBillCount { get; set; }
        public string PaymentMethod { get; set; } = string.Empty;
        public string? TransactionRef { get; set; }
        public string? BankName { get; set; }
        public string? ChequeNo { get; set; }
        public string? Notes { get; set; }
        public string? CreatedByName { get; set; }
        public string? DebitLedgerName { get; set; }
        public string? CreditLedgerName { get; set; }

        // ── Partner Details ───────────────────────────────────────────────────
        public string AgentType { get; set; } = "F"; // 'F' = Franchise, 'C' = Corporate
        public int AgentId { get; set; }
        public string PartnerName { get; set; } = string.Empty;
        public string PartnerCode { get; set; } = string.Empty;
        public string PartnerType { get; set; } = string.Empty;
        public string? PartnerPhone { get; set; }
        public string? PartnerEmail { get; set; }
        public string? PartnerAddress { get; set; }

        // ── Settled Bills ─────────────────────────────────────────────────────
        public List<B2BSettledBillLineDto> Bills { get; set; } = new();

        // ── Computed ──────────────────────────────────────────────────────────
        public string AmountInWords => ConvertToWords(TotalAmount);

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
}
