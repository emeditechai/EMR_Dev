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
        public bool IsTransferred { get; set; }
        public int? SourceBranchId { get; set; }
        public string? SourceBranchName { get; set; }
        public DateTime? TransferredDate { get; set; }
        /// <summary>True when the order was billed to a Franchise / Company (B2B).</summary>
        public bool IsB2B { get; set; }
        /// <summary>"FRANCHISE" or "COMPANY" for B2B orders; null for B2C.</summary>
        public string? ClientType { get; set; }
        public string? ClientCode { get; set; }
        public string? ClientName { get; set; }
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
        public int? ReferralDoctorId { get; set; }
        public string? ReferralDoctorName { get; set; }
        public string PaymentStatus { get; set; } = "U";
        public decimal TotalPaid { get; set; }
        public decimal BalanceDue { get; set; }
        public decimal TotalAmount { get; set; }
        public bool IsTransferred { get; set; }
        public int? SourceBranchId { get; set; }
        public string? SourceBranchName { get; set; }
        public DateTime? TransferredDate { get; set; }
        public string? TransferRemarks { get; set; }
        public int ReportStatusId { get; set; }
        public string? StatusCode { get; set; }
        public string ReportStatusName { get; set; } = "Pending Entry";
        public string ReportBadgeClass { get; set; } = "bg-secondary-subtle text-secondary border border-secondary-subtle";
        public DateTime? DraftedDate { get; set; }
        public DateTime? SubmittedDate { get; set; }
        public DateTime? ValidatedDate { get; set; }
        public DateTime? ApprovedDate { get; set; }
        public List<LabReportingItemDto> Items { get; set; } = new();
        public List<LabReportGroupRemarkDto> GroupRemarks { get; set; } = new();
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
        public string? MethodName { get; set; }
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
        public string? SpecialRemarks { get; set; }
        public int? RefRangeId { get; set; }
        public decimal? LowValue { get; set; }
        public decimal? HighValue { get; set; }
        /// <summary>'Critical Value' / 'Panic Value' when the matched reference range has that tier, else null.</summary>
        public string? RangeTier { get; set; }
        /// <summary>Critical / Panic limits: a result beyond them is flagged 'Critical' / 'Panic' (before L / H).</summary>
        public decimal? LowThreshold { get; set; }
        public decimal? HighThreshold { get; set; }
        public string? ReferenceRange { get; set; }
        public string? AbnormalFlag { get; set; }
        public int TATHours { get; set; } = 24;
        public string? PreviousTestValue { get; set; }
        public DateTime? PreviousOrderDate { get; set; }
        public string? PreviousUnitSymbol { get; set; }
        public int ReportStatusId { get; set; }
        public string ReportStatusName { get; set; } = "Pending Entry";
        public string ReportBadgeClass { get; set; } = "bg-secondary-subtle text-secondary border border-secondary-subtle";
        public DateTime? DraftedDate { get; set; }
        public DateTime? SubmittedDate { get; set; }
        public DateTime? ValidatedDate { get; set; }
        public DateTime? ApprovedDate { get; set; }
        public DateTime? LastSavedDate { get; set; }
        public bool IsTransferred { get; set; }
        public int? SourceBranchId { get; set; }
        public string? SourceBranchName { get; set; }
        public int? TargetBranchId { get; set; }
        public string? TargetBranchName { get; set; }
        /// <summary>
        /// The sample was transferred out of the branch currently viewing: the result was produced and approved at
        /// the target branch, so it is shown here (to be seen and printed) but nothing on it may be changed.
        /// </summary>
        public bool IsReadOnlyForBranch { get; set; }
        public DateTime? TransferredDate { get; set; }
        public string? TransferRemarks { get; set; }
        public int CollectionstatusID { get; set; } = 2;
        public string SampleCollectionStatus { get; set; } = "Collected";
        public string SampleCollectionStatusCode { get; set; } = "COLLECTED";
        public int? RejectionReasonId { get; set; }
        public string? RejectionReason { get; set; }
        public string? GroupLabRemarks { get; set; }
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
        public List<LabReportGroupRemarkDto> GroupRemarks { get; set; } = new();
    }

    public class LabReportGroupRemarkDto
    {
        public string GroupKey { get; set; } = string.Empty;
        public string HeaderName { get; set; } = string.Empty;
        public int? ProfileId { get; set; }
        public int? InvestigationId { get; set; }
        public string? LabRemarks { get; set; }
    }

    public class LabReportingItemValueDto
    {
        public long SamplecollectionID { get; set; }
        public int InvestigationID { get; set; }
        public string? TestValue { get; set; }
        public string? Remarks { get; set; }
        public string? ReportingType { get; set; }
        public string? AbnormalFlag { get; set; }
    }

    public class UpdateLabSampleStatusRequestDto
    {
        public int LabOrderId { get; set; }
        public int? ProfileId { get; set; }
        public int? InvestigationId { get; set; }
        public long? SampleCollectionId { get; set; }
        public int CollectionStatusId { get; set; } // 2=COLLECTED, 3=RE_COLLECT, 4=REJECTED, 1=PENDING
        public int? RejectionReasonId { get; set; }
        public string? RejectionReason { get; set; }
    }

    public class LabOrderActivityDto
    {
        public DateTime EventDate { get; set; }
        public string Source { get; set; } = string.Empty;
        public string? EventType { get; set; }
        public string ActionName { get; set; } = string.Empty;
        public string? Description { get; set; }
        public int? UserId { get; set; }
        public string? UserName { get; set; }
        public string? BranchName { get; set; }
        public string? IpAddress { get; set; }
        public string? MetadataJson { get; set; }
    }

    public class LabReportSampleMetaDto
    {
        public long SamplecollectionID { get; set; }
        public int? DepartmentId { get; set; }
        public string? DepartmentName { get; set; }
        public int? CategoryId { get; set; }
        public string? CategoryName { get; set; }
        public int CategoryOrder { get; set; } = 9999;
        public string? SubCategoryName { get; set; }
        public DateTime? ReceivedDate { get; set; }
    }

    public class LabReportSignatoryDto
    {
        /// <summary>VALIDATED or APPROVED</summary>
        public string SignRole { get; set; } = string.Empty;
        public int UserId { get; set; }
        public string? FullName { get; set; }
        public string? RegistrationNo { get; set; }
        public string? CertificationNo { get; set; }
        public bool IsPathologist { get; set; }
        public DateTime? EventDate { get; set; }
    }

    public class LabReportProcessingLabDto
    {
        public int BranchId { get; set; }
        public string? BranchName { get; set; }
        public string? BranchCode { get; set; }
        public string? Address { get; set; }
        public string? City { get; set; }
        public string? State { get; set; }
        public string? Pincode { get; set; }
        public string? Phone { get; set; }
        public string? Email { get; set; }
    }

    /// <summary>B2B partner an order was billed to. ClientType: FRANCHISE or COMPANY.</summary>
    public class LabReportClientDto
    {
        public string ClientType { get; set; } = string.Empty;
        public string? Code { get; set; }
        public string? Name { get; set; }
        public string? Address { get; set; }
        public string? Phone { get; set; }
    }

    public class LabReportPrintMetaDto
    {
        public List<LabReportSampleMetaDto> Samples { get; set; } = new();
        public List<LabReportSignatoryDto> Signatories { get; set; } = new();
        public LabReportProcessingLabDto? ProcessingLab { get; set; }
        /// <summary>Null for B2C orders.</summary>
        public LabReportClientDto? Client { get; set; }
    }
}
