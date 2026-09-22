using System;
using System.Collections.Generic;

namespace EMR.Web.ApiClients.Models;

public class LabDashboardData
{
    public LabDashboardSummary Summary { get; set; } = new();
    public List<LabStatusBreakdownDto> StatusBreakdown { get; set; } = new();
    public List<LabTopTestDto> TopInvestigations { get; set; } = new();
    public List<LabCategoryDistributionDto> CategoryDistribution { get; set; } = new();
    public List<LabDashboardPatientOrderDto> PatientOrders { get; set; } = new();
    public LabReportingPipelineDto ReportingPipeline { get; set; } = new();
    public LabBillingSummaryDto Billing { get; set; } = new();
    public List<LabHourlyBookingDto> HourlyBookings { get; set; } = new();
    public List<LabDepartmentWorkloadDto> DepartmentWorkload { get; set; } = new();
    public List<LabTopClientDto> TopClients { get; set; } = new();
}

public class LabDashboardSummary
{
    public int TotalOrdersToday { get; set; }
    public decimal TotalRevenueToday { get; set; }
    public int UrgentOrdersToday { get; set; }
    public int HomeCollectionOrders { get; set; }
    public int InLabOrders { get; set; }
    public int PendingCollectionsToday { get; set; }
    public int CompletedCollectionsToday { get; set; }
    public int RecollectSamplesToday { get; set; }
    public int RejectedSamplesToday { get; set; }
    public int TotalTestsBookedToday { get; set; }
}

public class LabStatusBreakdownDto
{
    public int StatusID { get; set; }
    public string StatusCode { get; set; } = string.Empty;
    public string StatusName { get; set; } = string.Empty;
    public string BadgeClass { get; set; } = string.Empty;
    public int TotalCount { get; set; }
}

public class LabTopTestDto
{
    public string ItemName { get; set; } = string.Empty;
    public string ItemType { get; set; } = "I";
    public string CategoryName { get; set; } = string.Empty;
    public int OrderCount { get; set; }
    public decimal TotalRevenue { get; set; }
}

public class LabCategoryDistributionDto
{
    public string CategoryName { get; set; } = string.Empty;
    public int TestCount { get; set; }
}

public class LabDashboardPatientOrderDto
{
    public int LabOrderId { get; set; }
    public string BillNo { get; set; } = string.Empty;
    public string? TokenNo { get; set; }
    public DateTime OrderDate { get; set; }
    public DateTime BookingDate { get; set; }
    public int PatientId { get; set; }
    public string PatientCode { get; set; } = string.Empty;
    public string PatientName { get; set; } = string.Empty;
    public string? PhoneNumber { get; set; }
    public string? Gender { get; set; }
    public int? Age { get; set; }
    public decimal TotalAmount { get; set; }
    public bool IsUrgent { get; set; }
    public string CollectionType { get; set; } = "Lab";
    public string PaymentStatus { get; set; } = "U";
    public decimal TotalPaid { get; set; }
    public decimal BalanceDue { get; set; }
    public int TotalItems { get; set; }
    public int PendingCount { get; set; }
    public int CollectedCount { get; set; }
    public int AlertCount { get; set; }
    public string OverallSampleStatus { get; set; } = "Pending";
    public string? TestSummary { get; set; }
}

/// <summary>Entry → validation → approval of today's tests, plus abnormal / critical counts and average TAT.</summary>
public class LabReportingPipelineDto
{
    public int PendingEntry { get; set; }
    public int Entered { get; set; }
    public int Validated { get; set; }
    public int Approved { get; set; }
    public int AbnormalResults { get; set; }
    public int CriticalResults { get; set; }
    public decimal? AvgTatMinutes { get; set; }
}

/// <summary>What was billed and what was actually collected.</summary>
public class LabBillingSummaryDto
{
    public decimal GrossAmount { get; set; }
    public decimal CollectedAmount { get; set; }
    public decimal OutstandingAmount { get; set; }
    public int BillsWithDue { get; set; }
    public int B2BOrders { get; set; }
    public int B2COrders { get; set; }
    public decimal B2BAmount { get; set; }
    public decimal B2CAmount { get; set; }
    public decimal AvgBillValue { get; set; }
}

public class LabHourlyBookingDto
{
    public int HourOfDay { get; set; }
    public int OrderCount { get; set; }
    public decimal Amount { get; set; }
}

public class LabDepartmentWorkloadDto
{
    public string DepartmentName { get; set; } = string.Empty;
    public int TestCount { get; set; }
    public int CollectedCount { get; set; }
    public int ApprovedCount { get; set; }
}

public class LabTopClientDto
{
    public string? ClientType { get; set; }
    public string? ClientName { get; set; }
    public string? ClientCode { get; set; }
    public int OrderCount { get; set; }
    public decimal Amount { get; set; }
}
