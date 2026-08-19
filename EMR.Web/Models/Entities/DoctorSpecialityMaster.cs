using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("DoctorSpecialityMaster", Schema = "dbo")]
public class DoctorSpecialityMaster
{
    [Key]
    public int SpecialityId { get; set; }

    [Required, MaxLength(100)]
    public string SpecialityName { get; set; } = string.Empty;

    [Required, MaxLength(50)]
    public string SpecialityCode { get; set; } = string.Empty;

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }

    public ICollection<DoctorSubSpecialityMaster> SubSpecialities { get; set; } = new List<DoctorSubSpecialityMaster>();
}

