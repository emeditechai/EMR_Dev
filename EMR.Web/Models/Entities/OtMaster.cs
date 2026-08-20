using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("OtMaster", Schema = "dbo")]
public class OtMaster
{
    [Key]
    public int OtId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; }

    public int FloorId { get; set; }

    [Required]
    [StringLength(50)]
    public string OtCode { get; set; } = string.Empty;

    [Required]
    [StringLength(200)]
    public string OtName { get; set; } = string.Empty;

    [Required]
    [StringLength(100)]
    public string OtType { get; set; } = string.Empty;

    [Required]
    [StringLength(100)]
    public string Capacity { get; set; } = string.Empty;

    public bool EmergencyAvailable { get; set; } = false;

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

    [ForeignKey(nameof(FloorId))]
    public virtual FloorMaster? Floor { get; set; }

    public virtual ICollection<OtEquipmentMaster> Equipments { get; set; } = new List<OtEquipmentMaster>();

    public virtual ICollection<OtTariffMaster> Tariffs { get; set; } = new List<OtTariffMaster>();
}
