namespace EMR.Web.Models.Entities;

public class UserRole
{
    public int Id { get; set; }
    public int UserId { get; set; }
    public int RoleId { get; set; }
    /// <summary>The branch this role applies in; NULL = every branch the user is mapped to.</summary>
    public int? Branch_ID { get; set; }
    public bool IsActive { get; set; } = true;
    public DateTime AssignedDate { get; set; } = DateTime.Now;
    public int? AssignedBy { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    public User User { get; set; } = default!;
    public Role Role { get; set; } = default!;
}
