using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabFranchiseBarcodeService
{
    Task<LabFranchiseBarcodeSeriesGeneratedModel> GenerateSeriesAsync(GenerateBarcodeSeriesRequestModel request);
    Task<IEnumerable<LabFranchiseBarcodeSeriesModel>> GetSeriesListAsync(int franchiseId);
    Task CancelSeriesAsync(int seriesId, CancelBarcodeSeriesRequestModel request);
    Task<int> GetAvailableCountAsync(int franchiseId);
    Task<LabFranchiseBarcodePoolModel?> GetBarcodeStatusAsync(string barcodeNo);
    Task<IEnumerable<LabFranchiseBarcodePoolModel>> GetSeriesBarcodesAsync(int seriesId);
    Task<ValidateConsumeBarcodeResponseModel> ValidateAndConsumeAsync(ValidateConsumeBarcodeRequestModel request);
}
