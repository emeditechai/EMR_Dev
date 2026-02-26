using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class BranchMaster
{
    public int BranchId { get; set; }

    [Required]
    [MaxLength(150)]
    public string BranchName { get; set; } = string.Empty;

    [Required]
    [MaxLength(50)]
    public string BranchCode { get; set; } = string.Empty;

    [MaxLength(100)]
    public string? Country { get; set; }

    [MaxLength(100)]
    public string? State { get; set; }

    [MaxLength(100)]
    public string? City { get; set; }

    [MaxLength(250)]
    public string? Address { get; set; }

    [MaxLength(20)]
    public string? Pincode { get; set; }

    public bool IsHOBranch { get; set; }
    public bool IsActive { get; set; } = true;
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    public ICollection<UserBranch> UserBranches { get; set; } = new List<UserBranch>();
    public ICollection<Role> Roles { get; set; } = new List<Role>();
}
