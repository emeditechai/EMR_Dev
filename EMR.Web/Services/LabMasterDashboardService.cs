using EMR.Web.ApiClients;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public interface ILabMasterDashboardService
{
    Task<LabMasterDashboardViewModel> GetDashboardAsync(int companyId, string activeModule);
}

public class LabMasterDashboardService(
    ILabTestCategoryApiClient categoryApiClient,
    ILabTestSubCategoryApiClient subCategoryApiClient,
    ILabSampleTypeApiClient sampleTypeApiClient,
    ILabTestMethodApiClient methodApiClient,
    ILabUnitApiClient unitApiClient,
    ILabSampleRejectionApiClient sampleRejectionApiClient) : ILabMasterDashboardService
{
    public async Task<LabMasterDashboardViewModel> GetDashboardAsync(int companyId, string activeModule)
    {
        var categoriesTask = categoryApiClient.GetListAsync(companyId: companyId);
        var subCategoriesTask = subCategoryApiClient.GetListAsync(companyId: companyId);
        var sampleTypesTask = sampleTypeApiClient.GetListAsync(companyId: companyId);
        var methodsTask = methodApiClient.GetListAsync(companyId: companyId);
        var unitsTask = unitApiClient.GetListAsync(companyId: companyId);
        var rejectionsTask = sampleRejectionApiClient.GetListAsync(companyId: companyId);

        await Task.WhenAll(categoriesTask, subCategoriesTask, sampleTypesTask, methodsTask, unitsTask, rejectionsTask);

        var categories = (await categoriesTask).ToList();
        var subCategories = (await subCategoriesTask).ToList();
        var sampleTypes = (await sampleTypesTask).ToList();
        var methods = (await methodsTask).ToList();
        var units = (await unitsTask).ToList();
        var rejections = (await rejectionsTask).ToList();

        return new LabMasterDashboardViewModel
        {
            ActiveModule = activeModule,
            TotalCategories = categories.Count,
            ActiveCategories = categories.Count(c => c.Status),
            TotalSubCategories = subCategories.Count,
            ActiveSubCategories = subCategories.Count(sc => sc.Status),
            TotalSampleTypes = sampleTypes.Count,
            ActiveSampleTypes = sampleTypes.Count(st => st.Status),
            TotalTestMethods = methods.Count,
            ActiveTestMethods = methods.Count(m => m.Status),
            TotalUnits = units.Count,
            ActiveUnits = units.Count(u => u.Status),
            TotalSampleRejections = rejections.Count,
            ActiveSampleRejections = rejections.Count(r => r.Status)
        };
    }
}
