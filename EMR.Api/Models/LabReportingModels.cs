using System;
using System.Collections.Generic;

namespace EMR.Api.Models
{
    public class LabReportingStatsDto
    {
        public int TotalOrders { get; set; }
        public int PendingOrders { get; set; }
        public int DraftOrders { get; set; }
        public int EnteredOrders { get; set; }
        public int ValidatedOrders { get; set; }
    }

    public class LabReportingHeaderDto
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
        public DateTime OrderDate { get; set; }
        public DateTime? BookingDateTime { get; set; }
        public string? BillNo { get; set; }
        public string? TokenNo { get; set; }
        public bool IsUrgent { get; set; }
        public string CollectionType { get; set; } = "Lab";
        public int TotalInHouseTests { get; set; }
        public int CollectedInHouseTests { get; set; }
        public string SampleCollectionStatus { get; set; } = "Collected";
        public int ReportStatusId { get; set; }
        public string ReportStatusName { get; set; } = "Pending Entry";
        public string ReportBadgeClass { get; set; } = "bg-secondary-subtle text-secondary border border-secondary-subtle";
    }

    public class LabReportingHeaderListResult
    {
        public LabReportingStatsDto Stats { get; set; } = new();
        public List<LabReportingHeaderDto> Headers { get; set; } = new();
    }

    public class LabReportingOrderDetailDto
    {
        public int LabOrderId { get; set; }
        public int BranchId { get; set; }
        public string? BranchName { get; set; }
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
        public string? BillNo { get; set; }
        public string? TokenNo { get; set; }
        public bool IsUrgent { get; set; }
        public string CollectionType { get; set; } = "Lab";
        public int? PhlebotomistId { get; set; }
        public string? PhlebotomistName { get; set; }
        public string PaymentStatus { get; set; } = "U";
        public decimal TotalPaid { get; set; }
        public decimal BalanceDue { get; set; }
        public decimal TotalAmount { get; set; }
        public List<LabReportingItemDto> Items { get; set; } = new();
    }

    public class LabReportingItemDto
    {
        public long SamplecollectionID { get; set; }
        public int Laborderid { get; set; }
        public int InvestigationID { get; set; }
        public string TestCode { get; set; } = string.Empty;
        public string TestName { get; set; } = string.Empty;
        public int? DepartmentID { get; set; }
        public string? DepartmentName { get; set; }
        public int? SampleTypeId { get; set; }
        public string? SampleTypeName { get; set; }
        public string? ContainerType { get; set; }
        public string? UnitName { get; set; }
        public string? ReportingType { get; set; }
        public string? BarcodeNo { get; set; }
        public DateTime? Samplecollectiondate { get; set; }
        public TimeSpan? Samplecollectiontime { get; set; }
        public int? ProfileId { get; set; }
        public string? ProfileName { get; set; }
        public int? PackageId { get; set; }
        public string? PackageName { get; set; }
        public string? ProfilePackageName { get; set; }
        public long? LabEntryDetailId { get; set; }
        public string? TestValue { get; set; }
        public string? Remarks { get; set; }
        public int ReportStatusId { get; set; }
        public string ReportStatusName { get; set; } = "Pending Entry";
        public string ReportBadgeClass { get; set; } = "bg-secondary-subtle text-secondary border border-secondary-subtle";
        public DateTime? DraftedDate { get; set; }
        public DateTime? SubmittedDate { get; set; }
        public DateTime? ValidatedDate { get; set; }
        public DateTime? ApprovedDate { get; set; }
        public DateTime? LastSavedDate { get; set; }
    }

    public class LabReportStatusMasterDto
    {
        public int ReportStatusId { get; set; }
        public string StatusCode { get; set; } = string.Empty;
        public string StatusName { get; set; } = string.Empty;
        public string BadgeClass { get; set; } = "bg-secondary text-white";
        public int DisplayOrder { get; set; }
        public bool IsActive { get; set; }
    }

    public class SaveLabReportingRequestDto
    {
        public int LabOrderId { get; set; }
        public int ReportStatusId { get; set; }
        public List<LabReportingItemValueDto> Entries { get; set; } = new();
    }

    public class LabReportingItemValueDto
    {
        public long SamplecollectionID { get; set; }
        public int InvestigationID { get; set; }
        public string? TestValue { get; set; }
        public string? Remarks { get; set; }
        public string? ReportingType { get; set; }
    }
}
