namespace EMR.Web.Models.ViewModels;

public class LabMasterSummaryItemViewModel
{
    public string ModuleName { get; set; } = string.Empty;
    public string ControllerName { get; set; } = string.Empty;
    public string IconClass { get; set; } = string.Empty;
    public string BadgeBgClass { get; set; } = string.Empty;
    public int TotalCount { get; set; }
    public int ActiveCount { get; set; }
}

public class LabMasterDashboardViewModel
{
    public string ActiveModule { get; set; } = string.Empty;
    public int TotalCategories { get; set; }
    public int ActiveCategories { get; set; }
    public int TotalSubCategories { get; set; }
    public int ActiveSubCategories { get; set; }
    public int TotalSampleTypes { get; set; }
    public int ActiveSampleTypes { get; set; }
    public int TotalTestMethods { get; set; }
    public int ActiveTestMethods { get; set; }
    public int TotalUnits { get; set; }
    public int ActiveUnits { get; set; }
}
