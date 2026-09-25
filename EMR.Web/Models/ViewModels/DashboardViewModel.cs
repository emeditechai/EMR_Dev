namespace EMR.Web.Models.ViewModels;

public class DashboardViewModel
{
    public string UserDisplayName { get; set; } = string.Empty;
    public string CurrentBranchName { get; set; } = string.Empty;
    public string CurrentHospitalName { get; set; } = string.Empty;
    public string CompanyName { get; set; } = string.Empty;
    public string CompanyCode { get; set; } = string.Empty;
    public string? HospitalLogoPath { get; set; }

    /// <summary>When this session started (Users.LastLoginDate, set at branch selection).</summary>
    public DateTime? SignedInAt { get; set; }
    /// <summary>The sign-in before this one, from the audit trail; null on a first-ever sign-in.</summary>
    public DateTime? PreviousSignInAt { get; set; }
    public string? SignedInFromIp { get; set; }

    /// <summary>The user's most recent real action - page views and sign-in events are not activity.</summary>
    public string? LastActivityDescription { get; set; }
    public DateTime? LastActivityAt { get; set; }
    public string? LastActivityModule { get; set; }
    public string? LastActivityScreen { get; set; }
}
