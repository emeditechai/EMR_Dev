using System;
using System.Collections.Generic;

namespace EMR.Api.Models
{
    public class LabOrderRequest
    {
        public int PatientId { get; set; }
        public int BranchId { get; set; }
        public string CollectionType { get; set; } = "Lab";
        public int? PhlebotomistId { get; set; }
        public DateTime? BookingDate { get; set; }
        public List<LabOrderItemRequest> Items { get; set; } = new();
    }

    public class LabOrderItemRequest
    {
        public int InvestigationId { get; set; }
        public string? Type { get; set; } = "I"; // 'P' or 'I'
        public decimal Price { get; set; }
        public decimal DiscountAmount { get; set; }
    }

    public class LabOrderResponse
    {
        public int LabOrderId { get; set; }
        public string BillNo { get; set; } = string.Empty;
        public string? TokenNo { get; set; }
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
        public string? SampleType { get; set; }
        public string? Method { get; set; }
        public bool IsDiscountAllowed { get; set; }
        public bool IsPackage { get; set; }
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
        public DateTime OrderDate { get; set; }
        public string? BillNo { get; set; }
        public string? TokenNo { get; set; }
        public decimal TotalAmount { get; set; }
        public string CollectionType { get; set; } = "Lab";
        public int? PhlebotomistId { get; set; }
        public string? PhlebotomistName { get; set; }
        public DateTime? BookingDate { get; set; }
        public bool IsActive { get; set; }
        public DateTime CreatedDate { get; set; }
        public int? CreatedBy { get; set; }
        public string? PatientCode { get; set; }
        public string? PatientName { get; set; }
        public string? PhoneNumber { get; set; }
        public string? Gender { get; set; }
        public DateTime? DateOfBirth { get; set; }
        public int? Age { get; set; }
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
        public DateTime OrderDate { get; set; }
        public string? BillNo { get; set; }
        public string? TokenNo { get; set; }
        public decimal TotalAmount { get; set; }
        public string CollectionType { get; set; } = "Lab";
        public int? PhlebotomistId { get; set; }
        public string? PhlebotomistName { get; set; }
        public DateTime? BookingDate { get; set; }
        public bool IsActive { get; set; }
        public DateTime CreatedDate { get; set; }
        public string? CreatedByName { get; set; }
        public string? PatientCode { get; set; }
        public string? PatientName { get; set; }
        public string? PhoneNumber { get; set; }
        public string? EmailId { get; set; }
        public string? Gender { get; set; }
        public DateTime? DateOfBirth { get; set; }
        public int? Age { get; set; }
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
        public string? Type { get; set; }
        public string? TestCode { get; set; }
        public string? TestName { get; set; }
        public string? SampleType { get; set; }
        public string? TATHours { get; set; }
        public string? DepartmentName { get; set; }
        public string? CategoryName { get; set; }
        public string? SubCategoryName { get; set; }
        public decimal Price { get; set; }
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
        public DateTime PaymentDate { get; set; }
        public string? ReceiptNo { get; set; }
        public string? TransactionRef { get; set; }
        public string? ChequeNo { get; set; }
        public string? BankName { get; set; }
        public string? UPIRefNo { get; set; }
        public string? CardLast4 { get; set; }
        public string? Notes { get; set; }
    }
}
