using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class Role
{
    public int Id { get; set; }

    [Required]
    [MaxLength(100)]
    public string Name { get; set; } = string.Empty;

    [MaxLength(255)]
    public string? Description { get; set; }

    public bool IsSystemRole { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;
    public DateTime? LastModifiedDate { get; set; }
    public int? BranchId { get; set; }

    [MaxLength(100)]
    public string? IconClass { get; set; }

    public BranchMaster? Branch { get; set; }
    public ICollection<UserRole> UserRoles { get; set; } = new List<UserRole>();
}
