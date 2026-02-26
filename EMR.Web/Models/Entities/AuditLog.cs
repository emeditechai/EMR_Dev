using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class AuditLog
{
    public long Id { get; set; }
    public int? UserId { get; set; }
    public int? BranchId { get; set; }

    [Required]
    [MaxLength(100)]
    public string EventType { get; set; } = string.Empty;

    [Required]
    [MaxLength(250)]
    public string ActionName { get; set; } = string.Empty;

    [MaxLength(100)]
    public string? ControllerName { get; set; }

    [MaxLength(500)]
    public string? RoutePath { get; set; }

    [MaxLength(50)]
    public string? HttpMethod { get; set; }

    [MaxLength(64)]
    public string? IpAddress { get; set; }

    [MaxLength(500)]
    public string? UserAgent { get; set; }

    [MaxLength(2000)]
    public string? Description { get; set; }

    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;
}
