using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("HKLocationMaster", Schema = "dbo")]
public class HKLocationMaster
{
    [Key]
    public int Location_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    [Required]
    [Column("Branch_ID")]
    public int Branch_ID { get; set; }

    [Required, MaxLength(50)]
    public string LocationType { get; set; } = "Ward"; // Ward, Room, Toilet, ICU, OT, OPD, Public Area

    [Column("Reference_ID")]
    public int Reference_ID { get; set; } = 0;

    [Required, MaxLength(50)]
    public string LocationCode { get; set; } = string.Empty;

    [Required, MaxLength(200)]
    public string LocationName { get; set; } = string.Empty;

    [Column("Floor_ID")]
    public int? Floor_ID { get; set; }

    [Column("Building_ID")]
    public int? Building_ID { get; set; }

    [Required, MaxLength(50)]
    public string RiskLevel { get; set; } = "Moderate Risk";

    public bool Status { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    // Navigation properties
    [ForeignKey("Branch_ID")]
    public virtual BranchMaster? Branch { get; set; }

    [ForeignKey("Floor_ID")]
    public virtual FloorMaster? Floor { get; set; }

    [ForeignKey("Building_ID")]
    public virtual BuildingMaster? Building { get; set; }
}
