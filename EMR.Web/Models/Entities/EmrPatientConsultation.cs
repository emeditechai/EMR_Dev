using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("EmrPatientConsultation", Schema = "dbo")]
public class EmrPatientConsultation
{
    [Key]
    public int ConsultationId { get; set; }

    public int OPDServiceId { get; set; }

    public int PatientId { get; set; }

    public int DoctorId { get; set; }

    public int TemplateId { get; set; }

    [Required, MaxLength(50)]
    public string OPDBillNo { get; set; } = string.Empty;

    [Required, MaxLength(50)]
    public string PatientCode { get; set; } = string.Empty;

    [Required, MaxLength(150)]
    public string PatientName { get; set; } = string.Empty;

    [MaxLength(20)]
    public string? Gender { get; set; }

    [MaxLength(20)]
    public string? Age { get; set; }

    [MaxLength(20)]
    public string? MobileNumber { get; set; }

    public DateTime VisitDate { get; set; }

    [Required, MaxLength(20)]
    public string VisitType { get; set; } = "New"; // 'New' or 'Follow-up'

    [Required, MaxLength(20)]
    public string ConsultationType { get; set; } = "Walking"; // 'Walking' or 'Video'

    [Required]
    public string EmrDataJson { get; set; } = "{}";

    public int CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}
