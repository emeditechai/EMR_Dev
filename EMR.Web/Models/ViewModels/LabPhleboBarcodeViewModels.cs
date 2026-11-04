using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

/// <summary>Master &gt; Lab Master &gt; Phlebotomist Barcode Assignment (SQLScripts/2401).</summary>
public class LabPhleboBarcodeIndexViewModel
{
    public int? SelectedPhlebotomistId { get; set; }
    public string? SelectedPhlebotomistCode { get; set; }
    public string? SelectedPhlebotomistName { get; set; }
    public List<SelectListItem> PhlebotomistOptions { get; set; } = [];
}
