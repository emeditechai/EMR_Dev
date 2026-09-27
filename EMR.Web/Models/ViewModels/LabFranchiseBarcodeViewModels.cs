using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

/// <summary>Master &gt; Lab Master &gt; Franchise Barcode Assignment landing page.</summary>
public class LabFranchiseBarcodeIndexViewModel
{
    public int? SelectedFranchiseId { get; set; }
    public string? SelectedFranchiseCode { get; set; }
    public string? SelectedFranchiseName { get; set; }
    public List<SelectListItem> FranchiseOptions { get; set; } = [];
}
