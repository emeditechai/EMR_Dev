using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class HospitalServiceListItemViewModel
{
    public int HospitalServiceId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string? BranchCode { get; set; }
    public int DepartmentId { get; set; }
    public string DepartmentName { get; set; } = string.Empty;
    public string DepartmentCode { get; set; } = string.Empty;
    public string ServiceCode { get; set; } = string.Empty;
    public string ServiceName { get; set; } = string.Empty;
    public string ServiceType { get; set; } = string.Empty;
    public string UOM { get; set; } = string.Empty;
    public decimal TaxPercentage { get; set; }
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
}

public class HospitalServiceFormViewModel
{
    public int HospitalServiceId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; }

    [Required(ErrorMessage = "Department is required")]
    [Display(Name = "IPD Department")]
    public int DepartmentId { get; set; }

    [Required(ErrorMessage = "Service Code is required")]
    [StringLength(50, ErrorMessage = "Service Code cannot exceed 50 characters")]
    [Display(Name = "Service Code")]
    public string ServiceCode { get; set; } = string.Empty;

    [Required(ErrorMessage = "Service Name is required")]
    [StringLength(200, ErrorMessage = "Service Name cannot exceed 200 characters")]
    [Display(Name = "Service Name")]
    public string ServiceName { get; set; } = string.Empty;

    [Required(ErrorMessage = "Service Type is required")]
    [StringLength(100)]
    [Display(Name = "Service Type")]
    public string ServiceType { get; set; } = string.Empty;

    [Required(ErrorMessage = "UOM is required")]
    [StringLength(50)]
    [Display(Name = "Unit of Measurement (UOM)")]
    public string UOM { get; set; } = string.Empty;

    [Range(0, 100, ErrorMessage = "Tax Percentage must be between 0 and 100")]
    [Display(Name = "Tax Percentage (%)")]
    public decimal TaxPercentage { get; set; } = 0;

    [StringLength(500)]
    [Display(Name = "Description / Remarks")]
    public string? Description { get; set; }

    [Display(Name = "Is Active")]
    public bool IsActive { get; set; } = true;

    // Dropdown SelectLists
    public List<SelectListItem> DepartmentOptions { get; set; } = [];
    public List<SelectListItem> ServiceTypeOptions { get; set; } = [];
    public List<SelectListItem> UomOptions { get; set; } = [];
}

public class HospitalServiceDetailsViewModel
{
    public EMR.Web.Models.Entities.HospitalServiceMaster Service { get; set; } = null!;
    public List<EMR.Web.Models.Entities.HospitalServiceRateMaster> Rates { get; set; } = [];
    public bool HasConfiguredRates => Rates.Count > 0;
}

