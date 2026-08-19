using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("DepartmentMaster", Schema = "dbo")]
public class DepartmentMaster
{
    [Key]
    public int DeptId { get; set; }

    [Required, MaxLength(20)]
    public string DeptCode { get; set; } = string.Empty;

    [Required, MaxLength(150)]
    public string DeptName { get; set; } = string.Empty;

    [Required, MaxLength(20)]
    public string DeptType { get; set; } = string.Empty;

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}
