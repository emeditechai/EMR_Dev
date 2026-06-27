using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("EmrMedicationMaster", Schema = "dbo")]
public class EmrMedicationMaster
{
    [Key]
    public int MedicationId { get; set; }

    [Required, MaxLength(200)]
    public string MedicationName { get; set; } = string.Empty;

    [MaxLength(200)]
    public string? GenericName { get; set; }

    [MaxLength(100)]
    public string? Category { get; set; }

    [MaxLength(100)]
    public string? Strength { get; set; }

    [MaxLength(50)]
    public string? Unit { get; set; }

    [MaxLength(100)]
    public string? RouteOfAdministration { get; set; }

    public bool IsActive { get; set; } = true;

    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int CreatedBy { get; set; } = 0;
    public DateTime? ModifiedDate { get; set; }
    public int? ModifiedBy { get; set; }
}
