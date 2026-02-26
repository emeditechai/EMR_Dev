namespace EMR.Web.Models.ViewModels;

public class DashboardViewModel
{
    public string UserDisplayName { get; set; } = string.Empty;
    public string CurrentBranchName { get; set; } = string.Empty;
    public string CurrentHospitalName { get; set; } = string.Empty;
    public string? HospitalLogoPath { get; set; }
    public int TotalUsers { get; set; }
    public int TotalBranches { get; set; }
    public int ActiveMappings { get; set; }
}
