namespace EMR.Web.Models.ViewModels;

// Server-Side Authorization - Settings > Security screens.

public sealed class AdminMenuRow
{
    public int Menu_ID { get; set; }
    public int? Parent_Menu_ID { get; set; }
    public string Menu_Type { get; set; } = "NAV";
    public string Menu_Code { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public string? Icon { get; set; }
    public int Sort_Order { get; set; }
    public bool IsActive { get; set; }
}

public sealed class AdminPageRow
{
    public int Page_ID { get; set; }
    public int? Menu_ID { get; set; }
    public string Page_Code { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public string Controller { get; set; } = string.Empty;
    public string Action { get; set; } = string.Empty;
    public string? Area { get; set; }
    public bool Show_In_Menu { get; set; }
    public int Sort_Order { get; set; }
    public string? Icon { get; set; }
    public string? Route_Values { get; set; }
    public string? Link_Target { get; set; }
    public bool IsActive { get; set; }
    public int EndpointCount { get; set; }
    public int GrantCount { get; set; }
}

public sealed class AdminControlRow
{
    public int Control_ID { get; set; }
    public int Page_ID { get; set; }
    public string Control_Code { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public int Sort_Order { get; set; }
    public bool IsActive { get; set; }
    public bool Is_Sensitive { get; set; }
}

public sealed class ControlVocabularyRow
{
    public string Control_Code { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public int Sort_Order { get; set; }
    public bool Is_Sensitive { get; set; }
}

public sealed class AdminTree
{
    public List<AdminMenuRow> Menus { get; set; } = new();
    public List<AdminPageRow> Pages { get; set; } = new();
    public List<AdminControlRow> Controls { get; set; } = new();
    public List<ControlVocabularyRow> Vocabulary { get; set; } = new();
}

public sealed class AdminEndpointRow
{
    public int Endpoint_ID { get; set; }
    public string App { get; set; } = "WEB";
    public string Http_Method { get; set; } = "GET";
    public string Controller { get; set; } = string.Empty;
    public string Action { get; set; } = string.Empty;
    public string? Route { get; set; }
    public string? Source { get; set; }
    public bool Is_Public { get; set; }
    public bool Is_Orphaned { get; set; }
    public int? Page_ID { get; set; }
    public string? Page_Code { get; set; }
    public string? Page_Title { get; set; }
    public int? Control_ID { get; set; }
    public string? Control_Code { get; set; }
    public DateTime? Last_Seen_On { get; set; }
    public int Refusals7d { get; set; }
}

public sealed class EndpointStats
{
    public int Unmapped { get; set; }
    public int Orphaned { get; set; }
    public int PublicEndpoints { get; set; }
    public int Mapped { get; set; }
}

/// <summary>What the scanner suggests for an unmapped endpoint; the curator accepts or corrects it.</summary>
public sealed class EndpointProposal
{
    public int EndpointId { get; set; }
    public string HttpMethod { get; set; } = "GET";
    public string Controller { get; set; } = string.Empty;
    public string Action { get; set; } = string.Empty;
    public List<int> PageIds { get; set; } = new();
    public string? PageTitle { get; set; }
    public string? PageCode { get; set; }
    public string ControlCode { get; set; } = "VIEW";
    /// <summary>high = the controller belongs to one screen (or the action is that screen's own); review = a guess.</summary>
    public string Confidence { get; set; } = "review";
    public string Reason { get; set; } = string.Empty;
    public int Refusals7d { get; set; }
}

public sealed class GrantRow
{
    public int? Menu_ID { get; set; }
    public int? Page_ID { get; set; }
    public int? Control_ID { get; set; }
    public string Permission { get; set; } = "A";
    public string? Reason { get; set; }
}

public sealed class GrantChange
{
    public int? M { get; set; }
    public int? P { get; set; }
    public int? C { get; set; }
    /// <summary>A = allow, D = deny, "" = remove the row (inherit).</summary>
    public string V { get; set; } = string.Empty;
    public string? R { get; set; }
}

public sealed class SaveGrantsRequest
{
    public int TargetId { get; set; }
    public int? BranchId { get; set; }
    public int ExpectedVersion { get; set; }
    public bool Confirmed { get; set; }
    public List<GrantChange> Changes { get; set; } = new();
}

public sealed class SaveGrantsResult
{
    public string Status { get; set; } = "OK";
    public int Changes { get; set; }
    public int AffectedUsers { get; set; }
    public int Version { get; set; }
    public List<int> AffectedUserIds { get; set; } = new();
}

public sealed class RoleGrantsMeta
{
    public int Version { get; set; }
    public string? LastChangedBy { get; set; }
    public DateTime? LastChangedOn { get; set; }
    public int UsersHoldingRole { get; set; }
}

public sealed class HistoryRow
{
    public int Log_ID { get; set; }
    public DateTime Changed_On { get; set; }
    public string? ChangedBy { get; set; }
    public string? Target { get; set; }
    public string? Scope { get; set; }
    public string? Branch { get; set; }
    public string? Old_Value { get; set; }
    public string? New_Value { get; set; }
    public string? Reason { get; set; }
}

public sealed class ExplainRow
{
    public int Scope { get; set; }
    public string ScopeName { get; set; } = string.Empty;
    public string? Target { get; set; }
    public string Source { get; set; } = string.Empty;
    public string? Who { get; set; }
    public string Permission { get; set; } = "D";
    public string? Reason { get; set; }
    public DateTime? ChangedOn { get; set; }
}

public sealed class ExplainLevel
{
    public int Scope { get; set; }
    public string ScopeName { get; set; } = string.Empty;
    public string? Title { get; set; }
}

public sealed class DecisionLogRow
{
    public long Log_ID { get; set; }
    public DateTime Logged_On { get; set; }
    public string App { get; set; } = string.Empty;
    public string Mode { get; set; } = string.Empty;
    public string Outcome { get; set; } = string.Empty;
    public int? User_ID { get; set; }
    public string? UserName { get; set; }
    public string? BranchName { get; set; }
    public string Http_Method { get; set; } = string.Empty;
    public string Controller { get; set; } = string.Empty;
    public string Action { get; set; } = string.Empty;
    public string? Path { get; set; }
    public string? Page_Code { get; set; }
    public string? Control_Code { get; set; }
    public int? Decided_At_Scope { get; set; }
    public string? Decided_By { get; set; }
}

public sealed class LookupItem
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;
    public string? Extra { get; set; }
}

public sealed class UserGrantsHeader
{
    public int Id { get; set; }
    public string Username { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public bool IsSuperAdmin { get; set; }
    public bool IsActive { get; set; }
    public int? CompanyId { get; set; }
}

public sealed class UserRoleRow
{
    public int RoleId { get; set; }
    public string RoleName { get; set; } = string.Empty;
    public int? Branch_ID { get; set; }
    /// <summary>Where the user holds the role ("All branches" or branch names) - one entry per role on the screens.</summary>
    public string? Branches { get; set; }
}

/// <summary>Page shell for all four screens: lists for the pickers, the current mode, and what the viewer may do.</summary>
public sealed class SecurityPageViewModel
{
    public string Screen { get; set; } = string.Empty;
    public List<LookupItem> Roles { get; set; } = new();
    public List<LookupItem> Users { get; set; } = new();
    public List<LookupItem> Branches { get; set; } = new();
    public string Mode { get; set; } = "Audit";
    public List<string> EnforceModules { get; set; } = new();
    public bool CanEdit { get; set; }
    public bool CanExport { get; set; }
    public int? PreselectId { get; set; }
    public int? PreselectBranchId { get; set; }
}
