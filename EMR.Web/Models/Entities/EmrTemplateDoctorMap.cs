using System.ComponentModel.DataAnnotations.Schema;

namespace EMR.Web.Models.Entities;

/// <summary>EMR template for particular doctors (SQLScripts/2480): a template with doctors is doctor-specific, without them
/// it is the default of its specialities.</summary>
[Table("EmrTemplateDoctorMap", Schema = "dbo")]
public class EmrTemplateDoctorMap
{
    public int TemplateId { get; set; }
    public int DoctorId { get; set; }
    public int CompanyId { get; set; } = 1;
    public bool IsActive { get; set; } = true;
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;

    [ForeignKey("TemplateId")]
    public EmrTemplate? Template { get; set; }
}
