using System;
using System.Collections.Generic;

namespace EMR.Web.Models.DTOs
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
    }

    public class LabReportingHeaderListResult
    {
        public LabReportingStatsDto Stats { get; set; } = new();
        public List<LabReportingHeaderDto> Headers { get; set; } = new();
    }

    public class LabReportingPackageGroupDto
    {
        public string GroupId { get; set; } = string.Empty;
        public int? PackageId { get; set; }
        public string PackageName { get; set; } = string.Empty;
        public string? LabRemarks { get; set; }
        public List<LabReportingProfileGroupDto> Profiles { get; set; } = new();
        public List<LabReportingItemDto> StandaloneItems { get; set; } = new();
    }

    public class LabReportingProfileGroupDto
    {
        public string GroupId { get; set; } = string.Empty;
        public int? ProfileId { get; set; }
        public string ProfileName { get; set; } = string.Empty;
        public string? SharedBarcode { get; set; }
        public string? LabRemarks { get; set; }
        public int CollectionstatusID { get; set; } = 2;
        public string SampleCollectionStatus { get; set; } = "Collected";
        public string SampleCollectionStatusCode { get; set; } = "COLLECTED";
        public int? RejectionReasonId { get; set; }
        public string? RejectionReason { get; set; }
        public List<LabReportingItemDto> Items { get; set; } = new();
    }

    public class LabReportingStandaloneTestGroupDto
    {
        public string GroupId { get; set; } = string.Empty;
        public long SamplecollectionID { get; set; }
        public int InvestigationId { get; set; }
        public string TestCode { get; set; } = string.Empty;
        public string TestName { get; set; } = string.Empty;
        public string? SharedBarcode { get; set; }
        public string? LabRemarks { get; set; }
        public int CollectionstatusID { get; set; } = 2;
        public string SampleCollectionStatus { get; set; } = "Collected";
        public string SampleCollectionStatusCode { get; set; } = "COLLECTED";
        public int? RejectionReasonId { get; set; }
        public string? RejectionReason { get; set; }
        public List<LabReportingItemDto> Items { get; set; } = new();
    }

    public class LabReportingHierarchyDto
    {
        public List<LabReportingPackageGroupDto> Packages { get; set; } = new();
        public List<LabReportingProfileGroupDto> StandaloneProfiles { get; set; } = new();
        public List<LabReportingStandaloneTestGroupDto> StandaloneTestGroups { get; set; } = new();
        public List<LabReportingItemDto> StandaloneItems { get; set; } = new();
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

        public LabReportingHierarchyDto GetHierarchy()
        {
            var hierarchy = new LabReportingHierarchyDto();
            if (Items == null || Items.Count == 0) return hierarchy;

            var pkgMap = new Dictionary<string, LabReportingPackageGroupDto>();
            var profMap = new Dictionary<string, LabReportingProfileGroupDto>();
            var testMap = new Dictionary<string, LabReportingStandaloneTestGroupDto>();

            var remarksMap = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (GroupRemarks != null)
            {
                foreach (var r in GroupRemarks)
                {
                    if (!string.IsNullOrEmpty(r.GroupKey))
                    {
                        remarksMap[r.GroupKey] = r.LabRemarks ?? "";
                    }
                }
            }

            int groupIndex = 0;
            foreach (var item in Items)
            {
                bool hasProfile = !string.IsNullOrWhiteSpace(item.ProfileName) && item.ProfileName != "—";
                bool hasPackage = !string.IsNullOrWhiteSpace(item.PackageName) && item.PackageName != "—";

                if (hasPackage)
                {
                    string pkgKey = $"PKG_{item.PackageId?.ToString() ?? item.PackageName}";
                    if (!pkgMap.TryGetValue(pkgKey, out var pkgGrp))
                    {
                        groupIndex++;
                        pkgGrp = new LabReportingPackageGroupDto
                        {
                            GroupId = $"grp_{groupIndex}",
                            PackageId = item.PackageId,
                            PackageName = item.PackageName!
                        };
                        if (remarksMap.TryGetValue(pkgKey, out var pkgRem))
                        {
                            pkgGrp.LabRemarks = pkgRem;
                        }
                        pkgMap[pkgKey] = pkgGrp;
                        hierarchy.Packages.Add(pkgGrp);
                    }

                    if (hasProfile)
                    {
                        string profKey = $"PRF_{item.ProfileId?.ToString() ?? item.ProfileName}";
                        var profGrp = pkgGrp.Profiles.Find(p => p.ProfileName == item.ProfileName);
                        if (profGrp == null)
                        {
                            groupIndex++;
                            profGrp = new LabReportingProfileGroupDto
                            {
                                GroupId = $"grp_{groupIndex}",
                                ProfileId = item.ProfileId,
                                ProfileName = item.ProfileName!,
                                SharedBarcode = item.BarcodeNo,
                                CollectionstatusID = item.CollectionstatusID,
                                SampleCollectionStatus = item.SampleCollectionStatus,
                                SampleCollectionStatusCode = item.SampleCollectionStatusCode,
                                RejectionReasonId = item.RejectionReasonId,
                                RejectionReason = item.RejectionReason
                            };
                            if (remarksMap.TryGetValue(profKey, out var pRem))
                            {
                                profGrp.LabRemarks = pRem;
                            }
                            else if (!string.IsNullOrEmpty(item.GroupLabRemarks))
                            {
                                profGrp.LabRemarks = item.GroupLabRemarks;
                            }
                            pkgGrp.Profiles.Add(profGrp);
                        }
                        if (string.IsNullOrEmpty(profGrp.SharedBarcode) && !string.IsNullOrEmpty(item.BarcodeNo))
                        {
                            profGrp.SharedBarcode = item.BarcodeNo;
                        }
                        profGrp.Items.Add(item);
                    }
                    else
                    {
                        pkgGrp.StandaloneItems.Add(item);
                    }
                }
                else if (hasProfile)
                {
                    string profKey = $"PRF_{item.ProfileId?.ToString() ?? item.ProfileName}";
                    if (!profMap.TryGetValue(profKey, out var profGrp))
                    {
                        groupIndex++;
                        profGrp = new LabReportingProfileGroupDto
                        {
                            GroupId = $"grp_{groupIndex}",
                            ProfileId = item.ProfileId,
                            ProfileName = item.ProfileName!,
                            SharedBarcode = item.BarcodeNo,
                            CollectionstatusID = item.CollectionstatusID,
                            SampleCollectionStatus = item.SampleCollectionStatus,
                            SampleCollectionStatusCode = item.SampleCollectionStatusCode,
                            RejectionReasonId = item.RejectionReasonId,
                            RejectionReason = item.RejectionReason
                        };
                        if (remarksMap.TryGetValue(profKey, out var pRem))
                        {
                            profGrp.LabRemarks = pRem;
                        }
                        else if (!string.IsNullOrEmpty(item.GroupLabRemarks))
                        {
                            profGrp.LabRemarks = item.GroupLabRemarks;
                        }
                        profMap[profKey] = profGrp;
                        hierarchy.StandaloneProfiles.Add(profGrp);
                    }
                    if (string.IsNullOrEmpty(profGrp.SharedBarcode) && !string.IsNullOrEmpty(item.BarcodeNo))
                    {
                        profGrp.SharedBarcode = item.BarcodeNo;
                    }
                    profGrp.Items.Add(item);
                }
                else
                {
                    hierarchy.StandaloneItems.Add(item);

                    // Group standalone test by InvestigationID as individual test header
                    string testKey = $"INV_{item.InvestigationID}";
                    if (!testMap.TryGetValue(testKey, out var testGrp))
                    {
                        groupIndex++;
                        testGrp = new LabReportingStandaloneTestGroupDto
                        {
                            GroupId = $"grp_tst_{groupIndex}",
                            SamplecollectionID = item.SamplecollectionID,
                            InvestigationId = item.InvestigationID,
                            TestCode = item.TestCode,
                            TestName = item.TestName,
                            SharedBarcode = item.BarcodeNo,
                            CollectionstatusID = item.CollectionstatusID,
                            SampleCollectionStatus = item.SampleCollectionStatus,
                            SampleCollectionStatusCode = item.SampleCollectionStatusCode,
                            RejectionReasonId = item.RejectionReasonId,
                            RejectionReason = item.RejectionReason
                        };
                        if (remarksMap.TryGetValue(testKey, out var tRem))
                        {
                            testGrp.LabRemarks = tRem;
                        }
                        else if (!string.IsNullOrEmpty(item.GroupLabRemarks))
                        {
                            testGrp.LabRemarks = item.GroupLabRemarks;
                        }
                        testMap[testKey] = testGrp;
                        hierarchy.StandaloneTestGroups.Add(testGrp);
                    }
                    if (string.IsNullOrEmpty(testGrp.SharedBarcode) && !string.IsNullOrEmpty(item.BarcodeNo))
                    {
                        testGrp.SharedBarcode = item.BarcodeNo;
                    }
                    testGrp.Items.Add(item);
                }
            }

            return hierarchy;
        }
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

    public class LabReportingItemGroupDto
    {
        public string GroupId { get; set; } = string.Empty;
        public string GroupType { get; set; } = string.Empty; // "Profile", "Package", "PackageProfile", "Standalone"
        public string? PackageName { get; set; }
        public string? ProfileName { get; set; }
        public string DisplayTitle { get; set; } = string.Empty;
        public string? SharedBarcode { get; set; }
        public List<LabReportingItemDto> Items { get; set; } = new();
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
}
