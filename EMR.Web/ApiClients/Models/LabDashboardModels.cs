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
