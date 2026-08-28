using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class LabRateCardIndexViewModel
{
    public int? Branch_ID { get; set; }
    public SelectList? BranchList { get; set; }
}

public class LabRateCardFormViewModel
{
    public int? RateCard_ID { get; set; }
    public int CompanyId { get; set; } = 1;
    
    // Header
    public int Branch_ID { get; set; }
    public SelectList? BranchList { get; set; }
    public string Rate_Type { get; set; } = "B2C";
    public DateTime Effective_From { get; set; } = DateTime.Today;
    public DateTime Effective_To { get; set; } = new DateTime(2099, 12, 31);
    public bool Status { get; set; } = true;

    // Dropdowns for Copy functionality
    public SelectList? SourceBranchList { get; set; }

    // Dropdowns for Category filtering
    public SelectList? DepartmentList { get; set; }

    // JSON payload of Details for binding to frontend grid
    public string DetailsJson { get; set; } = "[]";
}
