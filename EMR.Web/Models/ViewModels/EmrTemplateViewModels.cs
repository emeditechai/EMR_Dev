using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class EmrTemplateListViewModel
{
    public int TemplateId { get; set; }
    public string TemplateName { get; set; } = string.Empty;
    public string? Description { get; set; }
    public bool IsActive { get; set; }
    public List<string> MappedSpecialityNames { get; set; } = [];
    /// <summary>Doctors of a doctor-specific template (SQLScripts/2480); empty = the specialities' default template.</summary>
    public List<string> MappedDoctorNames { get; set; } = [];
}

public class EmrTemplateViewModel
{
    public int TemplateId { get; set; }

    [Required(ErrorMessage = "Template Name is required.")]
    [MaxLength(150, ErrorMessage = "Template Name cannot exceed 150 characters.")]
    [Display(Name = "Template Name")]
    public string TemplateName { get; set; } = string.Empty;

    [MaxLength(500, ErrorMessage = "Description cannot exceed 500 characters.")]
    public string? Description { get; set; }

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;

    [Required(ErrorMessage = "At least one Doctor Speciality must be selected.")]
    [Display(Name = "Mapped Specialities")]
    public List<int> SelectedSpecialityIds { get; set; } = [];

    /// <summary>Optional (SQLScripts/2480): doctors of the chosen specialities who get this template; none = the default of the specialities.</summary>
    public List<int> SelectedDoctorIds { get; set; } = [];

    public List<EmrSectionViewModel> Sections { get; set; } = [];

    public List<SelectListItem> SpecialityOptions { get; set; } = [];

    /// <summary>The selected doctors as options (name, speciality), so the page shows them before the doctor list loads.</summary>
    public List<EmrTemplateDoctorOption> DoctorOptions { get; set; } = [];
}

public class EmrSectionViewModel
{
    public int SectionId { get; set; }

    [Required(ErrorMessage = "Section Name is required.")]
    [MaxLength(100)]
    public string SectionName { get; set; } = string.Empty;

    public int DisplayOrder { get; set; }

    public List<EmrFieldViewModel> Fields { get; set; } = [];
}

public class EmrFieldViewModel
{
    public int FieldId { get; set; }

    [Required(ErrorMessage = "Field Name is required.")]
    [MaxLength(100)]
    public string FieldName { get; set; } = string.Empty;

    [Required(ErrorMessage = "Field Type is required.")]
    public string FieldType { get; set; } = "Text"; // Text, TextArea, Select, MultiSelect, Number, Checkbox, Date, ImageUpload, Paint, FileUpload, RichText

    public string? OptionsString { get; set; } // Comma-separated choice values (e.g. "None, Regular, Occasional")

    public bool IsRequired { get; set; }
    public int DisplayOrder { get; set; }
}

/// <summary>A doctor offered on the EMR template form (SQLScripts/2480).</summary>
public class EmrTemplateDoctorOption
{
    public int DoctorId { get; set; }
    public string Name { get; set; } = string.Empty;
    public int? SpecialityId { get; set; }
    public string? SpecialityName { get; set; }
    /// <summary>The doctor's other active doctor-specific template, if any (shown as a warning).</summary>
    public string? OtherTemplate { get; set; }
}
