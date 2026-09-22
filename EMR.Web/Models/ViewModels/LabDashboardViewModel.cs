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
    /// <summary>ALL | B2C | B2B - the client filter that drives every figure on the dashboard.</summary>
    public string ClientType { get; set; } = "ALL";
    public LabDashboardData Data { get; set; } = new();
}
