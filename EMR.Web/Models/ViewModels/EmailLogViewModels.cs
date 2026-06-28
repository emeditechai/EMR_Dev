namespace EMR.Web.Models.ViewModels;

public class EmailLogFilterViewModel
{
    public string? Search { get; set; }
    public string? Status { get; set; }
    public DateTime? DateFrom { get; set; }
    public DateTime? DateTo { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 50;
}

public class EmailLogListItemViewModel
{
    public int Id { get; set; }
    public string RecipientEmail { get; set; } = string.Empty;
    public string? Subject { get; set; }
    public DateTime SentDate { get; set; }
    public string Status { get; set; } = string.Empty;
    public string? ErrorMessage { get; set; }
    
    // Joined properties
    public string ConfigName { get; set; } = string.Empty;
    public string ProviderType { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;
}

public class EmailLogPagedResult
{
    public required List<EmailLogListItemViewModel> Items { get; set; }
    public required EmailLogFilterViewModel Filter { get; set; }
    public int TotalCount { get; set; }
    
    public int TotalPages => TotalCount == 0 ? 1 : (int)Math.Ceiling(TotalCount / (double)Filter.PageSize);
    
    // Stats for UI
    public int TotalSuccess { get; set; }
    public int TotalFailed { get; set; }
}
