using EMR.Web.ApiClients.Models;

namespace EMR.Web.Models.ViewModels;

public class OpdDashboardViewModel
{
    public string UserDisplayName { get; set; } = string.Empty;
    public string CurrentBranchName { get; set; } = string.Empty;
    public string CurrentHospitalName { get; set; } = string.Empty;
    public string? HospitalLogoPath { get; set; }
    public string SelectedDate { get; set; } = string.Empty;

    public OpdDashboardData Data { get; set; } = new();
}
