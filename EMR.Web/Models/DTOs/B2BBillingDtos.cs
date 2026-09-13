using System;
using System.Collections.Generic;

namespace EMR.Web.Models.DTOs
{
    public class PartnerCreditStatusDto
    {
        public bool Found { get; set; }
        public string AgentType { get; set; } = string.Empty; // 'F' or 'C'
        public int AgentId { get; set; }
        public string PartnerName { get; set; } = string.Empty;
        public string PartnerCode { get; set; } = string.Empty;
        public int CreditFacilityType { get; set; } // 1: Prepaid, 2: Postpaid, 3: Hybrid
        public string CreditFacilityTypeName { get; set; } = string.Empty;
        public decimal CreditLimit { get; set; }
        public int CreditDays { get; set; }
        public int GraceDays { get; set; }
        public string? BillingCycle { get; set; }
        public DateTime? EffectiveFrom { get; set; }
        public DateTime? EffectiveTo { get; set; }
        public bool IsContractValid { get; set; } = true;
        public decimal WalletBalance { get; set; }
        public decimal CurrentOutstanding { get; set; }
        public decimal InvoicedOutstanding { get; set; }
        public decimal AvailableCredit { get; set; }
        public bool CanBook { get; set; } = true;
        public string? BlockReason { get; set; }
    }

    public class WalletTopUpDto
    {
        public int FranchiseId { get; set; }
        public decimal Amount { get; set; }
        public int PaymentMethodId { get; set; }
        public string? TransactionRef { get; set; }
        public int BranchId { get; set; } = 1;
        public string? Narration { get; set; }
    }

    public class WalletTopUpResultDto
    {
        public bool Success { get; set; }
        public string ReceiptNo { get; set; } = string.Empty;
        public decimal NewBalance { get; set; }
        public string? Message { get; set; }
    }

    public class WalletTransactionDto
    {
        public long TransactionId { get; set; }
        public int Franchise_ID { get; set; }
        public string TransactionType { get; set; } = string.Empty;
        public decimal Amount { get; set; }
        public decimal BalanceAfter { get; set; }
        public string ReferenceType { get; set; } = string.Empty;
        public int? ReferenceId { get; set; }
        public string? ReceiptNo { get; set; }
        public string? Narration { get; set; }
        public DateTime CreatedDate { get; set; }
        public string? CreatedByName { get; set; }
    }

    public class DeductWalletRequestDto
    {
        public int LabOrderId { get; set; }
        public int FranchiseId { get; set; }
        public decimal Amount { get; set; }
        public int BranchId { get; set; }
        public string BillNo { get; set; } = string.Empty;
    }

    public class DeductWalletResultDto
    {
        public bool Success { get; set; }
        public string ReceiptNo { get; set; } = string.Empty;
        public string TokenNo { get; set; } = string.Empty;
        public string? Message { get; set; }
    }

    public class UninvoicedOrderDto
    {
        public int LabOrderId { get; set; }
        public string BillNo { get; set; } = string.Empty;
        public DateTime OrderDate { get; set; }
        public DateTime? DueDate { get; set; }
        public decimal BillAmount { get; set; }
        public decimal PaidAmount { get; set; }
        public decimal BalanceDue { get; set; }
        public string PaymentStatus { get; set; } = "U";
        public int PatientId { get; set; }
        public string PatientCode { get; set; } = string.Empty;
        public string PatientName { get; set; } = string.Empty;
        public string? PatientPhone { get; set; }
        public int ItemCount { get; set; }
        public string? TestNames { get; set; }
        public string AgentType { get; set; } = "F";
        public int AgentId { get; set; }
        public string PartnerName { get; set; } = string.Empty;
        public string PartnerCode { get; set; } = string.Empty;
    }

    public class GenerateInvoiceRequestDto
    {
        public string AgentType { get; set; } = "F";
        public int AgentId { get; set; }
        public int BranchId { get; set; }
        public string SelectedOrderIds { get; set; } = string.Empty;
        public string? BillingCycle { get; set; }
        public string? Notes { get; set; }
        public List<BatchPartnerOrderGroupDto>? PartnerGroups { get; set; }
    }

    public class BatchPartnerOrderGroupDto
    {
        public int AgentId { get; set; }
        public string SelectedOrderIds { get; set; } = string.Empty;
    }

    public class GenerateInvoiceResultDto
    {
        public bool Success { get; set; }
        public int InvoiceId { get; set; }
        public string InvoiceNo { get; set; } = string.Empty;
        public string? Message { get; set; }
        public List<GeneratedInvoiceSummaryDto> GeneratedInvoices { get; set; } = new();
    }

    public class GeneratedInvoiceSummaryDto
    {
        public int InvoiceId { get; set; }
        public string InvoiceNo { get; set; } = string.Empty;
        public int AgentId { get; set; }
        public string PartnerName { get; set; } = string.Empty;
        public string PartnerCode { get; set; } = string.Empty;
        public int OrderCount { get; set; }
        public decimal TotalAmount { get; set; }
    }

    public class B2BInvoiceListDto
    {
        public int InvoiceId { get; set; }
        public string InvoiceNo { get; set; } = string.Empty;
        public string PartnerType { get; set; } = string.Empty;
        public int PartnerId { get; set; }
        public string PartnerName { get; set; } = string.Empty;
        public string PartnerCode { get; set; } = string.Empty;
        public int BranchId { get; set; }
        public string? BillingCycle { get; set; }
        public DateTime InvoiceDate { get; set; }
        public DateTime DueDate { get; set; }
        public decimal TotalAmount { get; set; }
        public decimal NetAmount { get; set; }
        public decimal PaidAmount { get; set; }
        public decimal BalanceAmount { get; set; }
        public string Status { get; set; } = "U";
        public string StatusName { get; set; } = "Unpaid";
        public int OrderCount { get; set; }
        public int TotalCount { get; set; }
    }

    public class B2BInvoiceDetailDto
    {
        public int InvoiceId { get; set; }
        public string InvoiceNo { get; set; } = string.Empty;
        public string PartnerType { get; set; } = string.Empty;
        public int PartnerId { get; set; }
        public string PartnerName { get; set; } = string.Empty;
        public string PartnerCode { get; set; } = string.Empty;
        public string? PartnerPhone { get; set; }
        public string? PartnerEmail { get; set; }
        public string? PartnerAddress { get; set; }
        public int BranchId { get; set; }
        public string? BranchName { get; set; }
        public string? BranchCode { get; set; }
        public string? BillingCycle { get; set; }
        public DateTime InvoiceDate { get; set; }
        public DateTime DueDate { get; set; }
        public decimal TotalAmount { get; set; }
        public decimal DiscountAmount { get; set; }
        public decimal TaxAmount { get; set; }
        public decimal NetAmount { get; set; }
        public decimal PaidAmount { get; set; }
        public decimal BalanceAmount { get; set; }
        public string Status { get; set; } = "U";
        public string? Notes { get; set; }
        public DateTime CreatedDate { get; set; }
        public string? CreatedByName { get; set; }
        public List<B2BInvoiceItemDto> Items { get; set; } = new();
        public List<B2BInvoiceTestLineDto> TestLines { get; set; } = new();

        public string AmountInWords
        {
            get
            {
                var amount = NetAmount > 0 ? NetAmount : TotalAmount;
                if (amount <= 0) return "Rupees Zero Only";
                long rupees = (long)Math.Truncate(amount);
                int paise = (int)Math.Round((amount - rupees) * 100);
                var result = "Rupees " + RupeesToWords(rupees);
                if (paise > 0) result += $" and {TwoDigitWords(paise)} Paise";
                return result + " Only";
            }
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

    public class B2BInvoiceItemDto
    {
        public int InvoiceItemId { get; set; }
        public int InvoiceId { get; set; }
        public int LabOrderId { get; set; }
        public string BillNo { get; set; } = string.Empty;
        public DateTime OrderDate { get; set; }
        public string PatientName { get; set; } = string.Empty;
        public string? PatientCode { get; set; }
        public string? PatientPhone { get; set; }
        public decimal B2BTotal { get; set; }
        public decimal Amount { get; set; }
        public string? TestNames { get; set; }
        public List<B2BInvoiceTestLineDto> Tests { get; set; } = new();
    }

    public class B2BInvoiceTestLineDto
    {
        public int LabOrderItemId { get; set; }
        public int LabOrderId { get; set; }
        public int InvoiceId { get; set; }
        public string BillNo { get; set; } = string.Empty;
        public DateTime OrderDate { get; set; }
        public string PatientName { get; set; } = string.Empty;
        public string? PatientCode { get; set; }
        public int InvestigationId { get; set; }
        public string ItemType { get; set; } = "I";
        public string? TestCode { get; set; }
        public string? TestName { get; set; }
        public string? DepartmentName { get; set; }
        public decimal MrpRate { get; set; }
        public decimal B2BRate { get; set; }
    }

    public class OutstandingSettlementBillDto
    {
        public int LabOrderId { get; set; }
        public string BillNo { get; set; } = string.Empty;
        public DateTime OrderDate { get; set; }
        public DateTime DueDate { get; set; }
        public decimal BillAmount { get; set; }
        public decimal PaidAmount { get; set; }
        public decimal BalanceDue { get; set; }
        public string PaymentStatus { get; set; } = "U";
        public int PatientId { get; set; }
        public string PatientCode { get; set; } = string.Empty;
        public string PatientName { get; set; } = string.Empty;
        public string? PatientPhone { get; set; }
        public int? InvoiceId { get; set; }
        public string? InvoiceNo { get; set; }
        public bool IsOverdue { get; set; }
        public int OverdueDays { get; set; }
        public string? TestNames { get; set; }
    }

    public class B2BBillPayItemDto
    {
        public int LabOrderId { get; set; }
        public decimal PayAmount { get; set; }
    }

    public class B2BSettleBillsRequestDto
    {
        public string AgentType { get; set; } = "F";
        public int AgentId { get; set; }
        public int BranchId { get; set; }
        public int PaymentMethodId { get; set; }
        public decimal PaidAmount { get; set; }
        public string? TransactionRef { get; set; }
        public string? BankName { get; set; }
        public string? ChequeNo { get; set; }
        public DateTime? ChequeDate { get; set; }
        public DateTime? PaymentDate { get; set; }
        public string? Notes { get; set; }
        public List<B2BBillPayItemDto> SelectedBills { get; set; } = new();
    }

    public class B2BSettleBillsResultDto
    {
        public bool Success { get; set; }
        public string BatchReceiptNo { get; set; } = string.Empty;
        public int SettledBillCount { get; set; }
        public string? Message { get; set; }
    }

    public class B2BSettlementReceiptDto
    {
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
        public string AgentType { get; set; } = string.Empty;
        public int AgentId { get; set; }
        public string PartnerName { get; set; } = string.Empty;
        public string PartnerCode { get; set; } = string.Empty;
        public string PartnerType { get; set; } = string.Empty;
        public string? PartnerPhone { get; set; }
        public string? PartnerEmail { get; set; }
        public string? PartnerAddress { get; set; }
        public int BranchId { get; set; }
        public string? BranchName { get; set; }
        public string? DebitLedgerName { get; set; }
        public string? CreditLedgerName { get; set; }

        public List<B2BSettledBillLineDto> Bills { get; set; } = new();
    }

    public class B2BSettledBillLineDto
    {
        public int LabOrderId { get; set; }
        public string BillNo { get; set; } = string.Empty;
        public string? TokenNo { get; set; }
        public DateTime OrderDate { get; set; }
        public string? PatientCode { get; set; }
        public string PatientName { get; set; } = string.Empty;
        public string? Gender { get; set; }
        public int? Age { get; set; }
        public decimal B2BTotal { get; set; }
        public decimal SettledAmount { get; set; }
        public decimal TotalPaid { get; set; }
        public decimal BalanceDue { get; set; }
        public string PaymentStatus { get; set; } = string.Empty;
        public string? TestNames { get; set; }
    }
}
