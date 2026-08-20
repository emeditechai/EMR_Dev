using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("ProcedureMaster", Schema = "dbo")]
public class ProcedureMaster
{
    [Key]
    public int ProcedureId { get; set; }

    public int CompanyId { get; set; } = 1;

    public int BranchId { get; set; }

    public int DepartmentId { get; set; }

    public int SpecialityId { get; set; }

    [Required]
    [StringLength(50)]
    public string ProcedureCode { get; set; } = string.Empty;

    [Required]
    [StringLength(200)]
    public string ProcedureName { get; set; } = string.Empty;

    [Required]
    [StringLength(100)]
    public string ProcedureCategory { get; set; } = string.Empty;

    public int DurationHours { get; set; } = 0;

    public int DurationMinutes { get; set; } = 0;

    public int DurationSeconds { get; set; } = 0;

    public bool AnaesthesiaRequired { get; set; } = false;

    public bool ConsentRequired { get; set; } = true;

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

    [ForeignKey(nameof(DepartmentId))]
    public virtual DepartmentMaster? Department { get; set; }

    [ForeignKey(nameof(SpecialityId))]
    public virtual DoctorSpecialityMaster? Speciality { get; set; }

    public virtual ICollection<ProcedureTariffMaster> Tariffs { get; set; } = new List<ProcedureTariffMaster>();

    [NotMapped]
    public string DurationFormatted => $"{DurationHours:D2}h {DurationMinutes:D2}m {(DurationSeconds > 0 ? $"{DurationSeconds:D2}s" : "")}".Trim();
}
