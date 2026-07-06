namespace EMR.Web.Models.Entities;

/// <summary>
/// Stores Whereby API configuration dynamically (API key, base URL, grace time, etc.).
/// Mapped to tbl_VideoSystemConfig.
/// </summary>
public class VideoSystemConfig
{
    public int ConfigId { get; set; }
    public string ConfigKey { get; set; } = string.Empty;
    public string ConfigValue { get; set; } = string.Empty;
    public string? MeetingCreationUrl { get; set; }
    public bool IsActive { get; set; } = true;
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public DateTime? ModifiedDate { get; set; }
    public string? ModifiedBy { get; set; }
}
