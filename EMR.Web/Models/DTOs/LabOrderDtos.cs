using System.Collections.Generic;

namespace EMR.Web.Models.DTOs
{
    public class LabOrderRequestDto
    {
        public int PatientId { get; set; }
        public int BranchId { get; set; }
        public string CollectionType { get; set; } = "Lab";
        public int? PhlebotomistId { get; set; }
        public System.DateTime? BookingDate { get; set; }
        public List<LabOrderItemRequestDto> Items { get; set; } = new();
    }

    public class LabOrderItemRequestDto
    {
        public int InvestigationId { get; set; }
        public string? Type { get; set; } // 'P' or 'I'
        public decimal Price { get; set; }
        public bool IsPackage { get; set; }
        public bool IsUrgent { get; set; }
    }

    public class LabOrderResponseDto
    {
        public int LabOrderId { get; set; }
        public string BillNo { get; set; } = string.Empty;
        public string TokenNo { get; set; } = string.Empty;
    }

    public class AvailableInvestigationDto
    {
        public int InvestigationId { get; set; }
        public string TestCode { get; set; }
        public string TestName { get; set; }
        public string TATHours { get; set; }
        public decimal MRP { get; set; }
        public bool IsProfileTest { get; set; }
        public int? ProfileId { get; set; }
        public string? ProfileCode { get; set; }
        public string? ProfileEncryptedUrl { get; set; }
        public string? SampleType { get; set; }
        public string? Method { get; set; }
        public bool IsDiscountAllowed { get; set; }
        public bool IsPackage { get; set; }
        public bool IsOutsourced { get; set; }
    }

    public class DepartmentDto
    {
        public int DepartmentId { get; set; }
        public string DepartmentName { get; set; } = string.Empty;
    }

    public class CategoryDto
    {
        public int CategoryId { get; set; }
        public string CategoryName { get; set; } = string.Empty;
    }

    public class SubCategoryDto
    {
        public int SubCategoryId { get; set; }
        public string SubCategoryName { get; set; } = string.Empty;
    }

    public class LabOrderStatsDto
    {
        public int TotalOrders { get; set; }
        public decimal TotalAmount { get; set; }
        public int PaidCount { get; set; }
        public int UnpaidCount { get; set; }
    }

    public class LabOrderListItemDto
    {
        public int LabOrderId { get; set; }
        public int PatientId { get; set; }
        public int BranchId { get; set; }
        public System.DateTime OrderDate { get; set; }
        public string? BillNo { get; set; }
        public string? TokenNo { get; set; }
        public bool IsUrgent { get; set; }
        public decimal TotalAmount { get; set; }
        public string CollectionType { get; set; } = "Lab";
        public int? PhlebotomistId { get; set; }
        public string? PhlebotomistName { get; set; }
        public System.DateTime? BookingDate { get; set; }
        public bool IsActive { get; set; }
        public System.DateTime CreatedDate { get; set; }
        public int? CreatedBy { get; set; }
        public string? PatientCode { get; set; }
        public string? PatientName { get; set; }
        public string? PhoneNumber { get; set; }
        public string? Gender { get; set; }
        public DateTime? DateOfBirth { get; set; }
        public int? Age { get; set; }
        public string FormattedAge => EMR.Web.Utils.AgeCalculator.FormatAgePattern(DateOfBirth, Age);
        public int? PaymentHeaderId { get; set; }
        public string PaymentStatus { get; set; } = "U";
        public decimal TotalPaid { get; set; }
        public decimal BalanceDue { get; set; }
        public string? CreatedByName { get; set; }
        public int ItemCount { get; set; }
        public string? TestNamesSummary { get; set; }
        public int TotalCount { get; set; }
    }

    public class LabOrderPagedResult
    {
        public LabOrderStatsDto Stats { get; set; } = new();
        public List<LabOrderListItemDto> Items { get; set; } = new();
        public int TotalCount { get; set; }
        public int Page { get; set; }
        public int PageSize { get; set; }
    }

    public class LabOrderDetailDto
    {
        public int LabOrderId { get; set; }
        public int PatientId { get; set; }
        public int BranchId { get; set; }
        public string? BranchName { get; set; }
        public System.DateTime OrderDate { get; set; }
        public string? BillNo { get; set; }
        public string? TokenNo { get; set; }
        public bool IsUrgent { get; set; }
        public decimal TotalAmount { get; set; }
        public string CollectionType { get; set; } = "Lab";
        public int? PhlebotomistId { get; set; }
        public string? PhlebotomistName { get; set; }
        public System.DateTime? BookingDate { get; set; }
        public bool IsActive { get; set; }
        public System.DateTime CreatedDate { get; set; }
        public string? CreatedByName { get; set; }
        public string? PatientCode { get; set; }
        public string? PatientName { get; set; }
        public string? PhoneNumber { get; set; }
        public string? EmailId { get; set; }
        public string? Gender { get; set; }
        public System.DateTime? DateOfBirth { get; set; }
        public int? Age { get; set; }
        public string FormattedAge => EMR.Web.Utils.AgeCalculator.FormatAgePattern(DateOfBirth, Age);
        public string? Address { get; set; }
        public int? PaymentHeaderId { get; set; }
        public string PaymentStatus { get; set; } = "U";
        public decimal TotalPaid { get; set; }
        public decimal BalanceDue { get; set; }
        public decimal NetAmount { get; set; }
        public decimal DiscountAmount { get; set; }
        public decimal RoundOffAmount { get; set; }
        public List<LabOrderItemDetailDto> Items { get; set; } = new();
        public List<LabOrderPaymentDetailDto> Payments { get; set; } = new();
    }

    public class LabOrderItemDetailDto
    {
        public int LabOrderItemId { get; set; }
        public int LabOrderId { get; set; }
        public int InvestigationId { get; set; }
        public string? TestCode { get; set; }
        public string? TestName { get; set; }
        public string? SampleType { get; set; }
        public string? TATHours { get; set; }
        public string? DepartmentName { get; set; }
        public string? CategoryName { get; set; }
        public string? SubCategoryName { get; set; }
        public string? Type { get; set; }
        public decimal Price { get; set; }
        public bool IsUrgent { get; set; }
        public decimal DiscountAmount { get; set; }
        public decimal NetAmount { get; set; }
        public bool IsActive { get; set; }
    }

    public class LabOrderPaymentDetailDto
    {
        public int PaymentDetailId { get; set; }
        public string? MethodName { get; set; }
        public string? MethodCode { get; set; }
        public decimal PaidAmount { get; set; }
        public System.DateTime PaymentDate { get; set; }
        public string? ReceiptNo { get; set; }
        public string? TransactionRef { get; set; }
        public string? ChequeNo { get; set; }
        public string? BankName { get; set; }
        public string? UPIRefNo { get; set; }
        public string? CardLast4 { get; set; }
        public string? Notes { get; set; }
    }

    // ── Cancellation & Refund DTOs ─────────────────────────────────────────────

    public class BillSearchResultDto
    {
        public int ModuleRefId { get; set; }
        public string ModuleCode { get; set; } = string.Empty;
        public string? BillNo { get; set; }
        public System.DateTime BillDate { get; set; }
        public decimal TotalAmount { get; set; }
        public int PatientId { get; set; }
        public string? PatientCode { get; set; }
        public string? PatientName { get; set; }
        public string? PhoneNumber { get; set; }
        public string? Gender { get; set; }
        public int? Age { get; set; }
        public string PaymentStatus { get; set; } = "U";
        public decimal TotalPaid { get; set; }
        public decimal BalanceDue { get; set; }
        public decimal NetAmount { get; set; }
        public bool HasCancellation { get; set; }
        public decimal? TotalCancelled { get; set; }
    }

    public class BillLineItemForCancellationDto
    {
        public int LineRefId { get; set; }
        public int ModuleRefId { get; set; }
        public string? ItemName { get; set; }
        public string? ItemCode { get; set; }
        public decimal OriginalAmount { get; set; }
        public decimal NetAmount { get; set; }
        public decimal DiscountAmount { get; set; }
        public bool IsActive { get; set; }
        public decimal CancelledAmount { get; set; }
        public bool IsCancelled { get; set; }
        public string? SampleTypeName { get; set; }
        public string? DepartmentName { get; set; }
        public string? CategoryName { get; set; }
    }

    public class BillPaymentSummaryDto
    {
        public int PaymentDetailId { get; set; }
        public string? MethodName { get; set; }
        public string? MethodCode { get; set; }
        public decimal PaidAmount { get; set; }
        public System.DateTime PaymentDate { get; set; }
        public string? ReceiptNo { get; set; }
        public string? TransactionRef { get; set; }
    }

    public class BillDetailForCancellationDto
    {
        public int ModuleRefId { get; set; }
        public string ModuleCode { get; set; } = string.Empty;
        public string? BillNo { get; set; }
        public System.DateTime BillDate { get; set; }
        public decimal TotalAmount { get; set; }
        public int PatientId { get; set; }
        public string? PatientCode { get; set; }
        public string? PatientName { get; set; }
        public string? PhoneNumber { get; set; }
        public string? Gender { get; set; }
        public string? EmailId { get; set; }
        public string? Address { get; set; }
        public int? Age { get; set; }
        public int PaymentHeaderId { get; set; }
        public string PaymentStatus { get; set; } = "U";
        public decimal TotalPaid { get; set; }
        public decimal BalanceDue { get; set; }
        public decimal NetAmount { get; set; }
        public decimal TotalDiscountAmount { get; set; }
        public decimal LineDiscountTotal { get; set; }
        public decimal RoundOffAmount { get; set; }
        public string? BranchName { get; set; }
        public List<BillLineItemForCancellationDto> Items { get; set; } = new();
        public List<BillPaymentSummaryDto> Payments { get; set; } = new();
    }

    public class BillCancelItemRequest
    {
        public int LineRefId { get; set; }
        public decimal Amount { get; set; }
    }

    public class BillCancellationRequestDto
    {
        public string ModuleCode { get; set; } = string.Empty;
        public int ModuleRefId { get; set; }
        public int BranchId { get; set; }
        public List<BillCancelItemRequest> Items { get; set; } = new();
        public string? Reason { get; set; }
        public decimal DiscountAdjusted { get; set; }
    }

    public class BillCancellationResponseDto
    {
        public bool Success { get; set; }
        public string? Error { get; set; }
        public int CancellationId { get; set; }
        public string? CancellationNo { get; set; }
        public decimal CancelledAmount { get; set; }
        public string? CancellationType { get; set; }
    }

    public class BillRefundRequestDto
    {
        public string ModuleCode { get; set; } = string.Empty;
        public int ModuleRefId { get; set; }
        public int CancellationId { get; set; }
        public decimal RefundAmount { get; set; }
        public string RefundMode { get; set; } = string.Empty;
        public string? TransactionRef { get; set; }
        public string? Notes { get; set; }
    }

    public class BillRefundResponseDto
    {
        public bool Success { get; set; }
        public string? Error { get; set; }
        public int RefundId { get; set; }
        public decimal RefundAmount { get; set; }
        public string? RefundMode { get; set; }
    }

    public class CancellationHistoryItemDto
    {
        public int CancellationId { get; set; }
        public string? CancellationNo { get; set; }
        public string? CancellationType { get; set; }
        public System.DateTime CancellationDate { get; set; }
        public decimal CancelledAmount { get; set; }
        public decimal DiscountAdjusted { get; set; }
        public string? Reason { get; set; }
        public string? Status { get; set; }
        public string? CancelledBy { get; set; }
    }

    public class CancellationHistoryLineItemDto
    {
        public int CancellationItemId { get; set; }
        public int CancellationId { get; set; }
        public int LineRefId { get; set; }
        public decimal OriginalAmount { get; set; }
        public decimal CancelledAmount { get; set; }
    }

    public class RefundHistoryItemDto
    {
        public int RefundId { get; set; }
        public int CancellationId { get; set; }
        public decimal RefundAmount { get; set; }
        public string? RefundMode { get; set; }
        public System.DateTime RefundDate { get; set; }
        public string? TransactionRef { get; set; }
        public string? Notes { get; set; }
        public string? Status { get; set; }
        public string? RefundedBy { get; set; }
    }

    public class BillCancellationHistoryDto
    {
        public List<CancellationHistoryItemDto> Cancellations { get; set; } = new();
        public List<CancellationHistoryLineItemDto> CancellationItems { get; set; } = new();
        public List<RefundHistoryItemDto> Refunds { get; set; } = new();
    }
}

