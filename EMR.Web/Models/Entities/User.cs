using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class User
{
    public int Id { get; set; }

    [Required]
    [MaxLength(100)]
    public string Username { get; set; } = string.Empty;

    [MaxLength(200)]
    public string? Email { get; set; }

    [Required]
    public string PasswordHash { get; set; } = string.Empty;

    [MaxLength(255)]
    public string? Salt { get; set; }

    [MaxLength(100)]
    public string? FirstName { get; set; }

    [MaxLength(100)]
    public string? LastName { get; set; }

    [MaxLength(20)]
    public string? PhoneNumber { get; set; }

    [MaxLength(20)]
    public string? Phone { get; set; }

    [MaxLength(200)]
    public string? FullName { get; set; }

    [MaxLength(100)]
    public string? Role { get; set; }

    public bool IsActive { get; set; } = true;
    public bool IsLockedOut { get; set; }
    public int FailedLoginAttempts { get; set; }
    public DateTime? LastLoginDate { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;
    public DateTime? LastModifiedDate { get; set; }
    public bool MustChangePassword { get; set; }
    public DateTime? PasswordLastChanged { get; set; }
    public bool RequiresMFA { get; set; }

    public ICollection<UserBranch> UserBranches { get; set; } = new List<UserBranch>();
    public ICollection<UserRole> UserRoles { get; set; } = new List<UserRole>();
}
