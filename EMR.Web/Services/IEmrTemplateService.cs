using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public interface IEmrTemplateService
{
    Task<IEnumerable<EmrTemplateListViewModel>> GetListAsync();
    Task<EmrTemplateViewModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(EmrTemplateViewModel model, int userId);
    Task<bool> UpdateAsync(EmrTemplateViewModel model, int userId);
    Task<bool> ToggleActiveAsync(int id);
    /// <summary>Activates / deactivates, checking the one-default-per-speciality / one-template-per-doctor rule (throws EmrTemplateRuleException).</summary>
    Task<bool> SetActiveCheckedAsync(int id, bool active);
    Task<string?> SpecialityDefaultAsync(int specialityId, int excludeTemplateId);
    /// <summary>Active doctors of the specialities (plus the given doctors) for the template form; excludeTemplateId = the template being edited.</summary>
    /// <summary>Copy From on Create: the templates of a speciality (and the one a doctor of it uses).</summary>
    Task<object> CopySourcesAsync(int specialityId, int? doctorId);
    Task<List<EmrTemplateDoctorOption>> DoctorOptionsAsync(IEnumerable<int> specialityIds, int excludeTemplateId, IEnumerable<int>? alsoDoctorIds = null);
}
