using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("IcuMaster", Schema = "dbo")]
public class IcuMaster
{
    [Key]
    public int IcuId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; }

    [Required]
    public int WardId { get; set; }

    [Required]
    [StringLength(50)]
    public string IcuCode { get; set; } = string.Empty;

    [Required]
    [StringLength(100)]
    public string IcuName { get; set; } = string.Empty;

    [Required]
    [StringLength(50)]
    public string IcuType { get; set; } = "ICU"; // ICU, HDU, NICU, PICU, CCU, etc.

    public int BedCapacity { get; set; } = 1;

    public int VentilatorCapacity { get; set; } = 0;

    public int IsolationCapacity { get; set; } = 0;

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

    [ForeignKey(nameof(WardId))]
    public virtual WardMaster? Ward { get; set; }

    public virtual ICollection<IcuTariffMaster> Tariffs { get; set; } = new List<IcuTariffMaster>();
}
