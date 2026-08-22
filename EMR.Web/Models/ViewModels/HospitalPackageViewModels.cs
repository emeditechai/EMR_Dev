using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class HospitalPackageItemViewModel
{
    public int HospitalPackage_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public string Package_Code { get; set; } = string.Empty;
    public string Package_Name { get; set; } = string.Empty;
    public string Package_Type { get; set; } = string.Empty;
    public DateTime ValidFrom { get; set; }
    public DateTime? ValidTo { get; set; }
    public decimal TotalPackageAmount { get; set; }
    public string? Description { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public int TotalDetailsCount { get; set; }
    public int DistinctHeadsCount { get; set; }
}

public class HospitalPackageIndexViewModel
{
    public List<HospitalPackageItemViewModel> Packages { get; set; } = [];
    public int? SelectedBranchId { get; set; }
    public string? SelectedPackageType { get; set; }
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }

    // KPI Summary Metrics
    public int TotalPackagesCount => Packages.Count;
    public int ActivePackagesCount => Packages.Count(p => p.Status);
    public int InactivePackagesCount => Packages.Count(p => !p.Status);
    public decimal AveragePackagePrice => Packages.Count > 0 ? Packages.Average(p => p.TotalPackageAmount) : 0;
    public int DistinctCategoriesCount => Packages.Select(p => p.Package_Type).Distinct().Count();

    // Dropdown filters & Lookups
    public List<SelectListItem> PackageTypeOptions { get; set; } = [];
    public List<SelectListItem> StatusOptions { get; set; } = [];
    public List<MasterLookupItemViewModel> MasterLookups { get; set; } = [];
}

public class HospitalPackageDetailViewModel
{
    public int HospitalPackageDetail_ID { get; set; }
    public int HospitalPackage_ID { get; set; }
    public string DetailHeadType { get; set; } = string.Empty;
    public int? MasterReferenceId { get; set; }
    public string? ItemCode { get; set; }
    public string ItemName { get; set; } = string.Empty;
    public decimal Quantity { get; set; } = 1;
    public decimal UnitRate { get; set; } = 0;
    public decimal Amount { get; set; } = 0;
    public string BillingFrequency { get; set; } = "Package Included";
    public bool IsMandatory { get; set; } = true;
    public string? Remarks { get; set; }
    public int DisplayOrder { get; set; }
}

public class HospitalPackageSaveViewModel
{
    public int HospitalPackage_ID { get; set; }
    public int CompanyId { get; set; } = 1;
    public int Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public string Package_Code { get; set; } = string.Empty;
    public string Package_Name { get; set; } = string.Empty;
    public string Package_Type { get; set; } = string.Empty;
    public DateTime ValidFrom { get; set; } = DateTime.Today;
    public DateTime? ValidTo { get; set; }
    public decimal TotalPackageAmount { get; set; }
    public string? Description { get; set; }
    public bool Status { get; set; }
    public List<HospitalPackageDetailViewModel> Details { get; set; } = [];
}

public class MasterLookupItemViewModel
{
    public string DetailHeadType { get; set; } = string.Empty;
    public int? MasterReferenceId { get; set; }
    public string? ItemCode { get; set; }
    public string ItemName { get; set; } = string.Empty;
    public decimal DefaultRate { get; set; }
    public string DefaultBillingFrequency { get; set; } = "Package Included";
}
