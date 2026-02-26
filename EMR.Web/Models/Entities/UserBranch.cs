namespace EMR.Web.Models.Entities;

public class UserBranch
{
    public int Id { get; set; }
    public int UserId { get; set; }
    public int BranchId { get; set; }
    public string? EmployeeCode { get; set; }
    public bool IsActive { get; set; } = true;
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    public User User { get; set; } = default!;
    public BranchMaster Branch { get; set; } = default!;
}
