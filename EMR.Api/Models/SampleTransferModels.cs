using System;
using System.Collections.Generic;

namespace EMR.Api.Models
{
    public class SampleTransferStatsDto
    {
        public int ReadyCount { get; set; }
        public int TransferredTodayCount { get; set; }
        public int TargetBranchesCount { get; set; }
    }

    public class SampleTransferEligibleItemDto
    {
        public long SampleCollectionId { get; set; }
        public int LabOrderId { get; set; }
        public int CurrentBranchId { get; set; }
        public int PatientId { get; set; }
        public string PatientCode { get; set; } = string.Empty;
        public string PatientName { get; set; } = string.Empty;
        public int? Age { get; set; }
        public string? Gender { get; set; }
        public string? PhoneNumber { get; set; }
        public string? BillNo { get; set; }
        public string? TokenNo { get; set; }
        public DateTime OrderDate { get; set; }
        public DateTime? BookingDateTime { get; set; }
        public DateTime? CollectionDate { get; set; }
        public TimeSpan? CollectionTime { get; set; }
        public string? BarcodeNo { get; set; }
        public int InvestigationId { get; set; }
        public string TestCode { get; set; } = string.Empty;
        public string TestName { get; set; } = string.Empty;
        public int? DepartmentId { get; set; }
        public string? DepartmentName { get; set; }
        public string? SampleTypeName { get; set; }
        public string? ContainerType { get; set; }
        public string? ProfilePackageName { get; set; }
        public int CollectionStatusId { get; set; }
        public string? CollectionStatusName { get; set; }
        public bool IsTransferred { get; set; }
        public int SourceBranchId { get; set; }
        public string? SourceBranchName { get; set; }
        public int? TargetBranchId { get; set; }
        public string? TargetBranchName { get; set; }
        public DateTime? TransferredDate { get; set; }
        public int? TransferredBy { get; set; }
        public string? TransferredByName { get; set; }
        public string? TransferRemarks { get; set; }
        public bool IsReceived { get; set; }
        public DateTime? ReceivedDate { get; set; }
        public int? ReceivedBy { get; set; }
        public string? ReceivedByName { get; set; }
        public string? ReceiveRemarks { get; set; }
        public bool HasReportEntry { get; set; }
        public string ReportStatusName { get; set; } = "Pending Entry";
    }

    public class SampleTransferHeaderListResult
    {
        public SampleTransferStatsDto Stats { get; set; } = new();
        public List<SampleTransferEligibleItemDto> Items { get; set; } = new();
    }

    public class ExecuteSampleTransferRequestDto
    {
        public List<long> SampleCollectionIds { get; set; } = new();
        public int SourceBranchId { get; set; }
        public int TargetBranchId { get; set; }
        public string? TransferRemarks { get; set; }
    }

    public class ExecuteSampleTransferResponseDto
    {
        public bool IsSuccess { get; set; }
        public int TransferredCount { get; set; }
        public string Message { get; set; } = string.Empty;
    }

    public class ReceiveSampleTransferRequestDto
    {
        public List<long> SampleCollectionIds { get; set; } = new();
        public int TargetBranchId { get; set; }
        public string? ReceiveRemarks { get; set; }
    }

    public class ReceiveSampleTransferResponseDto
    {
        public bool IsSuccess { get; set; }
        public int ReceivedCount { get; set; }
        public string Message { get; set; } = string.Empty;
    }

    public class SampleTransferReceiveStatsDto
    {
        public int PendingReceiveCount { get; set; }
        public int ReceivedTodayCount { get; set; }
        public int SourceBranchesCount { get; set; }
    }

    public class SampleTransferReceivableListResult
    {
        public SampleTransferReceiveStatsDto Stats { get; set; } = new();
        public List<SampleTransferEligibleItemDto> Items { get; set; } = new();
    }

    public class SampleTransferAuditDto
    {
        public long TransferAuditId { get; set; }
        public long SampleCollectionId { get; set; }
        public int LabOrderId { get; set; }
        public string? BarcodeNo { get; set; }
        public int InvestigationId { get; set; }
        public string? TestCode { get; set; }
        public string? TestName { get; set; }
        public string? DepartmentName { get; set; }
        public string? SampleTypeName { get; set; }
        public string? PatientCode { get; set; }
        public string? PatientName { get; set; }
        public string? BillNo { get; set; }
        public string? TokenNo { get; set; }
        public int SourceBranchId { get; set; }
        public string? SourceBranchName { get; set; }
        public int TargetBranchId { get; set; }
        public string? TargetBranchName { get; set; }
        public DateTime TransferredDate { get; set; }
        public int TransferredBy { get; set; }
        public string? TransferredByName { get; set; }
        public string? TransferRemarks { get; set; }
        public string? ActionType { get; set; }
        public bool IsReceived { get; set; }
        public string? ReportStatusName { get; set; }
    }

    public class TargetBranchOptionDto
    {
        public int BranchId { get; set; }
        public string BranchCode { get; set; } = string.Empty;
        public string BranchName { get; set; } = string.Empty;
    }
}
