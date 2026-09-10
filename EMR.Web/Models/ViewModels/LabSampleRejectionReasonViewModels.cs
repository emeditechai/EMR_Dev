using System.ComponentModel.DataAnnotations;
using EMR.Web.ApiClients.Models;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class LabSampleRejectionReasonIndexViewModel
{
    public List<LabSampleRejectionReasonModel> Reasons { get; set; } = [];
    public int? SelectedSampleTypeId { get; set; }
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }

    public List<SelectListItem> SampleTypeOptions { get; set; } = [];
    public List<SelectListItem> StatusOptions { get; set; } = [];
    public LabMasterDashboardViewModel Dashboard { get; set; } = new();
}

public class LabSampleRejectionReasonFormViewModel
{
    public int Reason_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    [Required(ErrorMessage = "Rejection Reason text is required.")]
    [StringLength(1000, ErrorMessage = "Reason Text cannot exceed 1000 characters.")]
    [Display(Name = "Rejection Reason Text")]
    public string Reason_Text { get; set; } = string.Empty;

    [Display(Name = "Applicable Sample Type")]
    public int? Applicable_Sample_Type_ID { get; set; }

    [Required(ErrorMessage = "Display Order is required.")]
    [Range(1, 99999, ErrorMessage = "Display Order must be a positive integer.")]
    [Display(Name = "Display Order")]
    public int Display_Order { get; set; } = 1;

    [Display(Name = "Status")]
    public bool Status { get; set; } = true;

    public List<SelectListItem> SampleTypeOptions { get; set; } = [];
}
