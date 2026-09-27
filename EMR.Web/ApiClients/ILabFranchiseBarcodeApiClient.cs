using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabFranchiseBarcodeApiClient
{
    Task<IEnumerable<LabFranchiseBarcodeSeriesModel>> GetSeriesListAsync(int franchiseId);
    Task<LabFranchiseBarcodeSeriesGeneratedModel> GenerateSeriesAsync(GenerateBarcodeSeriesRequestModel request);
    Task CancelSeriesAsync(int seriesId, CancelBarcodeSeriesRequestModel request);
    Task<IEnumerable<LabFranchiseBarcodePoolModel>> GetSeriesBarcodesAsync(int seriesId);
    Task<ValidateConsumeBarcodeResponseModel> ValidateAndConsumeAsync(ValidateConsumeBarcodeRequestModel request);
}
