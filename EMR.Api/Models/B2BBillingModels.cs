using System;
using System.Collections.Generic;

namespace EMR.Api.Models
{
    public class PartnerCreditStatusModel
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

    public class WalletTopUpRequest
    {
        public int FranchiseId { get; set; }
        public decimal Amount { get; set; }
        public int PaymentMethodId { get; set; }
        public string? TransactionRef { get; set; }
        public int BranchId { get; set; } = 1;
        public string? Narration { get; set; }
    }

    public class WalletTopUpResponse
    {
        public bool Success { get; set; }
        public string ReceiptNo { get; set; } = string.Empty;
        public decimal NewBalance { get; set; }
        public string? Message { get; set; }
    }

    public class WalletTransactionModel
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

    public class UninvoicedOrderModel
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

    public class GenerateInvoiceRequest
    {
        public string AgentType { get; set; } = "F"; // 'F' or 'C'
        public int AgentId { get; set; }
        public int BranchId { get; set; }
        public string SelectedOrderIds { get; set; } = string.Empty; // Comma-separated LabOrderIds
        public string? BillingCycle { get; set; }
        public string? Notes { get; set; }
        public List<BatchPartnerOrderGroup>? PartnerGroups { get; set; }
    }

    public class BatchPartnerOrderGroup
    {
        public int AgentId { get; set; }
        public string SelectedOrderIds { get; set; } = string.Empty;
    }

    public class GenerateInvoiceResponse
    {
        public bool Success { get; set; }
        public int InvoiceId { get; set; }
        public string InvoiceNo { get; set; } = string.Empty;
        public string? Message { get; set; }
        public List<GeneratedInvoiceSummary> GeneratedInvoices { get; set; } = new();
    }

    public class GeneratedInvoiceSummary
    {
        public int InvoiceId { get; set; }
        public string InvoiceNo { get; set; } = string.Empty;
        public int AgentId { get; set; }
        public string PartnerName { get; set; } = string.Empty;
        public string PartnerCode { get; set; } = string.Empty;
        public int OrderCount { get; set; }
        public decimal TotalAmount { get; set; }
    }

    public class B2BInvoiceListModel
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

    public class B2BInvoiceDetailModel
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
        public List<B2BInvoiceItemModel> Items { get; set; } = new();
        public List<B2BInvoiceTestLineModel> TestLines { get; set; } = new();
    }

    public class B2BInvoiceItemModel
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
        public List<B2BInvoiceTestLineModel> Tests { get; set; } = new();
    }

    public class B2BInvoiceTestLineModel
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

    public class OutstandingSettlementBillModel
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

    public class B2BBillPayItem
    {
        public int LabOrderId { get; set; }
        public decimal PayAmount { get; set; }
    }

    public class B2BSettleBillsRequest
    {
        public string AgentType { get; set; } = "F"; // 'F' or 'C'
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
        public List<B2BBillPayItem> SelectedBills { get; set; } = new();
    }

    public class B2BSettleBillsResponse
    {
        public bool Success { get; set; }
        public string BatchReceiptNo { get; set; } = string.Empty;
        public int SettledBillCount { get; set; }
        public string? Message { get; set; }
    }

    public class DeductWalletRequest
    {
        public int LabOrderId { get; set; }
        public int FranchiseId { get; set; }
        public decimal Amount { get; set; }
        public int BranchId { get; set; }
        public string BillNo { get; set; } = string.Empty;
    }

    public class DeductWalletResponse
    {
        public bool Success { get; set; }
        public string ReceiptNo { get; set; } = string.Empty;
        public string TokenNo { get; set; } = string.Empty;
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

