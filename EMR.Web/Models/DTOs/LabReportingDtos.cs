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
    }

    public class LabReportingHeaderListResult
    {
        public LabReportingStatsDto Stats { get; set; } = new();
        public List<LabReportingHeaderDto> Headers { get; set; } = new();
    }

    public class LabReportingPackageGroupDto
    {
        public string GroupId { get; set; } = string.Empty;
        public string PackageName { get; set; } = string.Empty;
        public List<LabReportingProfileGroupDto> Profiles { get; set; } = new();
        public List<LabReportingItemDto> StandaloneItems { get; set; } = new();
    }

    public class LabReportingProfileGroupDto
    {
        public string GroupId { get; set; } = string.Empty;
        public string ProfileName { get; set; } = string.Empty;
        public string? SharedBarcode { get; set; }
        public List<LabReportingItemDto> Items { get; set; } = new();
    }

    public class LabReportingHierarchyDto
    {
        public List<LabReportingPackageGroupDto> Packages { get; set; } = new();
        public List<LabReportingProfileGroupDto> StandaloneProfiles { get; set; } = new();
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
        public List<LabReportingItemDto> Items { get; set; } = new();

        public LabReportingHierarchyDto GetHierarchy()
        {
            var hierarchy = new LabReportingHierarchyDto();
            if (Items == null || Items.Count == 0) return hierarchy;

            var pkgMap = new Dictionary<string, LabReportingPackageGroupDto>();
            var profMap = new Dictionary<string, LabReportingProfileGroupDto>();

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
                            PackageName = item.PackageName!
                        };
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
                                ProfileName = item.ProfileName!,
                                SharedBarcode = item.BarcodeNo
                            };
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
                            ProfileName = item.ProfileName!,
                            SharedBarcode = item.BarcodeNo
                        };
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
}
