using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class DepartmentMaster
{
    public int DeptId { get; set; }

    [Required, MaxLength(20)]
    public string DeptCode { get; set; } = string.Empty;

    [Required, MaxLength(150)]
    public string DeptName { get; set; } = string.Empty;

    [Required, MaxLength(20)]
    public string DeptType { get; set; } = string.Empty;

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}
