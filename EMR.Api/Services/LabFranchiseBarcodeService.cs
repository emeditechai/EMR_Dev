using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabFranchiseBarcodeService(IDbConnectionFactory connectionFactory) : ILabFranchiseBarcodeService
{
    public async Task<LabFranchiseBarcodeSeriesGeneratedModel> GenerateSeriesAsync(GenerateBarcodeSeriesRequestModel request)
    {
        using var connection = connectionFactory.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@Franchise_ID", request.Franchise_ID);
        parameters.Add("@Quantity", request.Quantity);
        parameters.Add("@SampleCategoryCode", request.SampleCategoryCode);
        parameters.Add("@CreatedBy", request.CreatedBy);

        var result = await connection.QueryFirstOrDefaultAsync<LabFranchiseBarcodeSeriesGeneratedModel>(
            "dbo.usp_Api_LabFranchiseBarcodeSeries_Generate",
            parameters,
            commandType: CommandType.StoredProcedure
        );

        return result ?? throw new InvalidOperationException("The series was not generated.");
    }

    public async Task<IEnumerable<LabFranchiseBarcodeSeriesModel>> GetSeriesListAsync(int franchiseId)
    {
        using var connection = connectionFactory.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@Franchise_ID", franchiseId);

        return await connection.QueryAsync<LabFranchiseBarcodeSeriesModel>(
            "dbo.usp_Api_LabFranchiseBarcodeSeries_GetList",
            parameters,
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task CancelSeriesAsync(int seriesId, CancelBarcodeSeriesRequestModel request)
    {
        using var connection = connectionFactory.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@SeriesId", seriesId);
        parameters.Add("@Reason", request.Reason);
        parameters.Add("@UserId", request.UserId);

        await connection.ExecuteAsync(
            "dbo.usp_Api_LabFranchiseBarcodeSeries_Cancel",
            parameters,
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<int> GetAvailableCountAsync(int franchiseId)
    {
        using var connection = connectionFactory.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@Franchise_ID", franchiseId);

        var series = await connection.QueryAsync<LabFranchiseBarcodeSeriesModel>(
            "dbo.usp_Api_LabFranchiseBarcodeSeries_GetList",
            parameters,
            commandType: CommandType.StoredProcedure
        );

        return series.Sum(s => s.AvailableCount);
    }

    public async Task<LabFranchiseBarcodePoolModel?> GetBarcodeStatusAsync(string barcodeNo)
    {
        using var connection = connectionFactory.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@BarcodeNo", barcodeNo);

        return await connection.QueryFirstOrDefaultAsync<LabFranchiseBarcodePoolModel>(
            "dbo.usp_Lab_GetFranchiseBarcodeStatus",
            parameters,
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<IEnumerable<LabFranchiseBarcodePoolModel>> GetSeriesBarcodesAsync(int seriesId)
    {
        using var connection = connectionFactory.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@SeriesId", seriesId);

        return await connection.QueryAsync<LabFranchiseBarcodePoolModel>(
            "dbo.usp_Lab_GetSeriesBarcodes",
            parameters,
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<ValidateConsumeBarcodeResponseModel> ValidateAndConsumeAsync(ValidateConsumeBarcodeRequestModel request)
    {
        using var connection = connectionFactory.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@BarcodeNo", request.BarcodeNo);
        parameters.Add("@Franchise_ID", request.Franchise_ID);
        parameters.Add("@LabOrderId", request.LabOrderId);
        parameters.Add("@SamplecollectionID", request.SamplecollectionID);
        parameters.Add("@InvestigationId", request.InvestigationId);
        parameters.Add("@UserId", request.UserId);
        parameters.Add("@Success", dbType: DbType.Boolean, direction: ParameterDirection.Output);
        parameters.Add("@ErrorMessage", dbType: DbType.String, size: 500, direction: ParameterDirection.Output);

        await connection.ExecuteAsync(
            "dbo.usp_Lab_ValidateAndConsumeFranchiseBarcode",
            parameters,
            commandType: CommandType.StoredProcedure
        );

        var success = parameters.Get<bool>("@Success");
        return new ValidateConsumeBarcodeResponseModel
        {
            Success = success,
            Message = parameters.Get<string?>("@ErrorMessage"),
            BarcodeNo = request.BarcodeNo
        };
    }
}
