using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("ReferralDoctorMaster")]
public class ReferralDoctorMaster
{
    [Key]
    public int ReferralDoctorId { get; set; }

    [MaxLength(10)]
    public string? Salutation { get; set; }

    [Required]
    [MaxLength(150)]
    public string DoctorName { get; set; } = string.Empty;

    [MaxLength(15)]
    public string? PhoneNumber { get; set; }

    [MaxLength(150)]
    [EmailAddress]
    public string? EmailId { get; set; }

    [MaxLength(50)]
    public string? RegistrationNumber { get; set; }

    public bool IsActive { get; set; } = true;

    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}
