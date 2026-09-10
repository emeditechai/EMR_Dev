using System.ComponentModel.DataAnnotations;
using EMR.Web.ApiClients.Models;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class LabSampleRejectionIndexViewModel
{
    public List<LabSampleRejectionModel> Rejections { get; set; } = [];
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }

    public List<SelectListItem> StatusOptions { get; set; } = [];
    public LabMasterDashboardViewModel Dashboard { get; set; } = new();
}

public class LabSampleRejectionFormViewModel
{
    public int Rejection_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    [Display(Name = "Rejection Code")]
    public string? Rejection_Code { get; set; }

    [Required(ErrorMessage = "Rejection Reason is required.")]
    [StringLength(200, ErrorMessage = "Rejection Reason cannot exceed 200 characters.")]
    [Display(Name = "Rejection Reason")]
    public string Rejection_Reason { get; set; } = string.Empty;

    [StringLength(500, ErrorMessage = "Description cannot exceed 500 characters.")]
    [Display(Name = "Description")]
    public string? Description { get; set; }

    [Required(ErrorMessage = "Display Order is required.")]
    [Range(1, 99999, ErrorMessage = "Display Order must be a positive integer.")]
    [Display(Name = "Display Order")]
    public int Display_Order { get; set; } = 1;

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;
}
