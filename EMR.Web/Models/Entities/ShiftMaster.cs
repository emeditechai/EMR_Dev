using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("ShiftMaster", Schema = "dbo")]
public class ShiftMaster
{
    [Key]
    public int ShiftMaster_ID { get; set; }

    public int CompanyId { get; set; } = 1;

    [Required]
    [Column("Branch_ID")]
    public int Branch_ID { get; set; }

    [Required, MaxLength(50)]
    public string ShiftCode { get; set; } = string.Empty;

    [Required, MaxLength(100)]
    public string ShiftName { get; set; } = string.Empty;

    [Required]
    public TimeSpan StartTime { get; set; }

    [Required]
    public TimeSpan EndTime { get; set; }

    public int GraceTimeMinutes { get; set; } = 15;

    public int BreakDurationMinutes { get; set; } = 30;

    public bool IsNightShift { get; set; } = false;

    public bool Status { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    // Navigation property
    [ForeignKey("Branch_ID")]
    public virtual BranchMaster? Branch { get; set; }
}
