using EMR.Web.ApiClients;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public interface ILabMasterDashboardService
{
    Task<LabMasterDashboardViewModel> GetDashboardAsync(int branchId, int companyId, string activeModule);
}

public class LabMasterDashboardService(
    ILabTestCategoryApiClient categoryApiClient,
    ILabTestSubCategoryApiClient subCategoryApiClient,
    ILabSampleTypeApiClient sampleTypeApiClient,
    ILabTestMethodApiClient methodApiClient,
    ILabUnitApiClient unitApiClient) : ILabMasterDashboardService
{
    public async Task<LabMasterDashboardViewModel> GetDashboardAsync(int branchId, int companyId, string activeModule)
    {
        var categoriesTask = categoryApiClient.GetListAsync(branchId: branchId, companyId: companyId);
        var subCategoriesTask = subCategoryApiClient.GetListAsync(branchId: branchId, companyId: companyId);
        var sampleTypesTask = sampleTypeApiClient.GetListAsync(branchId: branchId, companyId: companyId);
        var methodsTask = methodApiClient.GetListAsync(branchId: branchId, companyId: companyId);
        var unitsTask = unitApiClient.GetListAsync(branchId: branchId, companyId: companyId);

        await Task.WhenAll(categoriesTask, subCategoriesTask, sampleTypesTask, methodsTask, unitsTask);

        var categories = (await categoriesTask).ToList();
        var subCategories = (await subCategoriesTask).ToList();
        var sampleTypes = (await sampleTypesTask).ToList();
        var methods = (await methodsTask).ToList();
        var units = (await unitsTask).ToList();

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
            ActiveUnits = units.Count(u => u.Status)
        };
    }
}
