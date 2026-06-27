using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public interface IEmrTemplateService
{
    Task<IEnumerable<EmrTemplateListViewModel>> GetListAsync();
    Task<EmrTemplateViewModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(EmrTemplateViewModel model, int userId);
    Task<bool> UpdateAsync(EmrTemplateViewModel model, int userId);
    Task<bool> ToggleActiveAsync(int id);
}
