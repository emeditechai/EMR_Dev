using System;
using System.Collections.Generic;

namespace EMR.Api.Models
{
    public class SampleCollectionStatsDto
    {
        public int TotalOrders { get; set; }
        public int PendingOrders { get; set; }
        public int PartialOrders { get; set; }
        public int CollectedOrders { get; set; }
    }

    public class SampleCollectionHeaderDto
    {
        public int LabOrderId { get; set; }
        public int BranchId { get; set; }
        public int PatientId { get; set; }
        public string PatientCode { get; set; } = string.Empty;
        public string PatientName { get; set; } = string.Empty;
        public int? Age { get; set; }
        public string? Gender { get; set; }
        public string? PhoneNumber { get; set; }
        public DateTime OrderDate { get; set; }
        public DateTime? BookingDateTime { get; set; }
        public string BillNo { get; set; } = string.Empty;
        public string? TokenNo { get; set; }
        public bool IsUrgent { get; set; }
        public string CollectionType { get; set; } = "Lab";
        public int? PhlebotomistId { get; set; }
        public string? PhlebotomistName { get; set; }
        public string PaymentStatus { get; set; } = "U";
        public decimal TotalPaid { get; set; }
        public decimal BalanceDue { get; set; }
        public decimal TotalAmount { get; set; }
        public string ContainerTypes { get; set; } = string.Empty;
        public int TotalTests { get; set; }
        public int CollectedCount { get; set; }
        public int PendingCount { get; set; }
        public int ReCollectCount { get; set; }
        public int RejectedCount { get; set; }
        public string OverallStatus { get; set; } = "Pending";
    }

    public class SampleCollectionHeaderListResult
    {
        public SampleCollectionStatsDto Stats { get; set; } = new();
        public List<SampleCollectionHeaderDto> Headers { get; set; } = new();
    }

    public class SampleCollectionOrderDetailDto
    {
        public int LabOrderId { get; set; }
        public int BranchId { get; set; }
        public int PatientId { get; set; }
        public string PatientCode { get; set; } = string.Empty;
        public string PatientName { get; set; } = string.Empty;
        public int? Age { get; set; }
        public string? Gender { get; set; }
        public string? PhoneNumber { get; set; }
        public string? EmailId { get; set; }
        public string? Address { get; set; }
        public DateTime OrderDate { get; set; }
        public DateTime? BookingDateTime { get; set; }
        public string BillNo { get; set; } = string.Empty;
        public string? TokenNo { get; set; }
        public bool IsUrgent { get; set; }
        public string CollectionType { get; set; } = "Lab";
        public int? PhlebotomistId { get; set; }
        public string? PhlebotomistName { get; set; }
        public string PaymentStatus { get; set; } = "U";
        public decimal TotalPaid { get; set; }
        public decimal BalanceDue { get; set; }
        public decimal TotalAmount { get; set; }
        public List<SampleCollectionItemDto> Items { get; set; } = new();
    }

    public class SampleCollectionItemDto
    {
        public long SamplecollectionID { get; set; }
        public int Laborderid { get; set; }
        public int InvestigationID { get; set; }
        public string TestCode { get; set; } = string.Empty;
        public string TestName { get; set; } = string.Empty;
        public string ProfileOrPackageName { get; set; } = string.Empty;
        public int? ProfileId { get; set; }
        public string? ProfileName { get; set; }
        public int? PackageId { get; set; }
        public string? PackageName { get; set; }
        public int? SampleTypeId { get; set; }
        public string SampleTypeName { get; set; } = string.Empty;
        public string ContainerType { get; set; } = string.Empty;
        public bool IsFastingRequired { get; set; }
        public string? BarcodeNo { get; set; }
        public int CollectionstatusID { get; set; }
        public string StatusName { get; set; } = string.Empty;
        public string StatusCode { get; set; } = string.Empty;
        public string BadgeClass { get; set; } = "badge-secondary";
        public DateTime? Samplecollectiondate { get; set; }
        public TimeSpan? Samplecollectiontime { get; set; }
        public string? FormattedCollectionDateTime { get; set; }
        public bool Iscancelled { get; set; }
    }

    public class SampleCollectionStatusMasterDto
    {
        public int StatusID { get; set; }
        public string StatusCode { get; set; } = string.Empty;
        public string StatusName { get; set; } = string.Empty;
        public string BadgeClass { get; set; } = "badge-secondary";
        public int DisplayOrder { get; set; }
        public bool IsActive { get; set; }
    }

    public class UpdateSampleCollectionStatusRequestDto
    {
        public long SampleCollectionId { get; set; }
        public int? LabOrderId { get; set; }
        public int CollectionstatusID { get; set; }
        public DateTime? SampleCollectionDate { get; set; }
        public TimeSpan? SampleCollectionTime { get; set; }
    }

    public class CollectAllSamplesRequestDto
    {
        public int LabOrderId { get; set; }
    }

    public class UpdateProfileSampleCollectionStatusRequestDto
    {
        public int LabOrderId { get; set; }
        public int? ProfileId { get; set; }
        public string? ProfileName { get; set; }
        public int CollectionstatusID { get; set; }
        public DateTime? SampleCollectionDate { get; set; }
        public TimeSpan? SampleCollectionTime { get; set; }
    }
}

