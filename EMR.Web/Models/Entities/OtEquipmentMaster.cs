using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("OtEquipmentMaster", Schema = "dbo")]
public class OtEquipmentMaster
{
    [Key]
    public int EquipmentId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; }

    public int OtId { get; set; }

    [Required]
    [StringLength(50)]
    public string EquipmentCode { get; set; } = string.Empty;

    [Required]
    [StringLength(200)]
    public string EquipmentName { get; set; } = string.Empty;

    [StringLength(100)]
    public string? EquipmentType { get; set; }

    [StringLength(100)]
    public string? SerialNo { get; set; }

    public bool CalibrationRequired { get; set; } = false;

    public DateTime? LastCalibrationDate { get; set; }

    public DateTime? CalibrationDueDate { get; set; }

    [StringLength(500)]
    public string? Description { get; set; }

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }

    public DateTime CreatedDate { get; set; } = DateTime.Now;

    public int? ModifiedBy { get; set; }

    public DateTime? ModifiedDate { get; set; }

    // Navigation properties
    [ForeignKey(nameof(BranchId))]
    public virtual BranchMaster? Branch { get; set; }

    [ForeignKey(nameof(OtId))]
    public virtual OtMaster? Ot { get; set; }
}
