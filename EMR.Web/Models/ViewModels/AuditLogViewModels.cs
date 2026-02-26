namespace EMR.Web.Models.ViewModels;

public class AuditLogFilterViewModel
{
    public string? Search { get; set; }          // username / action / description
    public string? EventType { get; set; }       // exact event type filter
    public DateTime? DateFrom { get; set; }
    public DateTime? DateTo { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 50;
}

public class AuditLogPagedResult
{
    public List<AuditLogListItemViewModel> Items { get; set; } = new();
    public AuditLogFilterViewModel Filter { get; set; } = new();
    public int TotalCount { get; set; }
    public int TotalPages => (int)Math.Ceiling((double)TotalCount / Filter.PageSize);
    public List<string> AvailableEventTypes { get; set; } = new();
}

public class AuditLogListItemViewModel
{
    public long Id { get; set; }
    public DateTime CreatedDate { get; set; }
    public string EventType { get; set; } = string.Empty;
    public string ActionName { get; set; } = string.Empty;
    public string? ControllerName { get; set; }
    public string? RoutePath { get; set; }
    public string? HttpMethod { get; set; }
    public string? UserAgent { get; set; }
    public string Username { get; set; } = "System";
    public string BranchName { get; set; } = "N/A";
    public string? IpAddress { get; set; }
    public string? Description { get; set; }
}
