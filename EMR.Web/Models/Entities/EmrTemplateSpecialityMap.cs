using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

[Table("EmrTemplateSpecialityMap", Schema = "dbo")]
public class EmrTemplateSpecialityMap
{
    public int TemplateId { get; set; }
    public int SpecialityId { get; set; }
    public bool IsActive { get; set; } = true;
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;

    [ForeignKey("TemplateId")]
    public EmrTemplate? Template { get; set; }

    [ForeignKey("SpecialityId")]
    public DoctorSpecialityMaster? Speciality { get; set; }
}
