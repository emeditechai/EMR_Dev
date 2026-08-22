using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("HKStaffMaster", Schema = "dbo")]
public class HKStaffMaster
{
    [Key]
    public int HKStaff_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    [Required]
    [Column("Branch_ID")]
    public int Branch_ID { get; set; }

    [Required]
    [Column("Staff_ID")]
    public int Staff_ID { get; set; }

    [Required]
    [Column("ShiftMaster_ID")]
    public int ShiftMaster_ID { get; set; }

    [Column("Supervisor_ID")]
    public int? Supervisor_ID { get; set; }

    [Required]
    [Column("AreaAllocation_ID")]
    public int AreaAllocation_ID { get; set; }

    public bool Status { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    [ForeignKey("Branch_ID")]
    public virtual BranchMaster? Branch { get; set; }

    [ForeignKey("Staff_ID")]
    public virtual User? StaffUser { get; set; }

    [ForeignKey("ShiftMaster_ID")]
    public virtual ShiftMaster? Shift { get; set; }

    [ForeignKey("Supervisor_ID")]
    public virtual User? SupervisorUser { get; set; }

    [ForeignKey("AreaAllocation_ID")]
    public virtual HKLocationMaster? AreaAllocation { get; set; }
}
