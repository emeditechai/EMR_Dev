using System;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.Models.ViewModels;

public class LabDashboardViewModel
{
    public string UserDisplayName { get; set; } = "User";
    public string CurrentBranchName { get; set; } = "Branch";
    public string CurrentHospitalName { get; set; } = "Hospital";
    public string? HospitalLogoPath { get; set; }
    public string SelectedDate { get; set; } = DateTime.Today.ToString("yyyy-MM-dd");
    public LabDashboardData Data { get; set; } = new();
}
