using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class ServiceMaster
{
    public int ServiceId { get; set; }

    [Required, MaxLength(20)]
    public string ItemCode { get; set; } = string.Empty;

    [Required, MaxLength(150)]
    public string ItemName { get; set; } = string.Empty;

    [Required, MaxLength(20)]
    public string ServiceType { get; set; } = string.Empty;

    public decimal ItemCharges { get; set; }
    public int BranchId { get; set; }
    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}
