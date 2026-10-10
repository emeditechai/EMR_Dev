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

    // ---- Home: personal shortcuts and session (no business data) -------------------------------------------------
    public string? ActiveRole { get; set; }
    public int RoleCount { get; set; }
    public int BranchCount { get; set; }

    /// <summary>The user's latest actions in this branch, newest first; the first is "Your last activity".</summary>
    public List<HomeActivityItem> RecentActivity { get; set; } = new();
    /// <summary>Screens the user opened last in this branch ("Continue where you left off").</summary>
    public List<HomeRecentScreen> RecentScreens { get; set; } = new();
    /// <summary>Every page the user may open, for the "Go to" search.</summary>
    public List<HomePageLink> PageCatalog { get; set; } = new();

    /// <summary>The sign-in before this session, in any branch (for "since your last sign-in").</summary>
    public DateTime? LastSessionAt { get; set; }
    /// <summary>Wrong-password / refused sign-ins on this account since the previous sign-in.</summary>
    public int FailedSignInsSinceLast { get; set; }
    public DateTime? LastFailedSignInAt { get; set; }
    public DateTime? PasswordLastChanged { get; set; }
    public bool MustChangePassword { get; set; }
    /// <summary>Days after which the password is shown as due for a change.</summary>
    public const int PasswordMaxAgeDays = 90;
}

/// <summary>A page of the navigation the user may open (Home "Go to" search, recent screens, activity links).</summary>
public sealed record HomePageLink(string Code, string Title, string? Icon, string Url, string? Target, string Path,
    string Controller, string Action);

/// <summary>A screen the user opened recently (from their page views), newest first.</summary>
public sealed record HomeRecentScreen(HomePageLink Page, DateTime LastOpenedAt);

/// <summary>One of the user's own recent actions, with a link back to the record or the screen when they may open it.</summary>
public sealed class HomeActivityItem
{
    public string? Description { get; set; }
    public DateTime At { get; set; }
    public string? Module { get; set; }
    /// <summary>"Payment received" (from the audit action code).</summary>
    public string EventTitle { get; set; } = string.Empty;
    /// <summary>The screen's menu title ("B2C Booking"), else the controller in words.</summary>
    public string ScreenTitle { get; set; } = string.Empty;
    public string? ScreenPath { get; set; }
    public string? ScreenIcon { get; set; }
    public string? ReferenceNo { get; set; }
    public string? OpenUrl { get; set; }
    public string? OpenLabel { get; set; }
}

/// <summary>Select Role: what the user can do in the branch with one of their roles - modules, screens, key actions.</summary>
public sealed class RoleAccessSummary
{
    public string? Role { get; set; }
    /// <summary>Super admin: everything is open, whatever the role.</summary>
    public bool FullAccess { get; set; }
    public int ScreenCount { get; set; }
    /// <summary>Actions beyond opening a screen (add, edit, print, approve ...) held on those screens.</summary>
    public int ActionCount { get; set; }
    public List<RoleAccessModule> Modules { get; set; } = new();
    public List<RoleAccessAction> KeyActions { get; set; } = new();
}

public sealed class RoleAccessModule
{
    public string Title { get; set; } = string.Empty;
    public string? Icon { get; set; }
    public int ScreenCount { get; set; }
    public List<string> Examples { get; set; } = new();
}

public sealed record RoleAccessAction(string Label, string Icon);
