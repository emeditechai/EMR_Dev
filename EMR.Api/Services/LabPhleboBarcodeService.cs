using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

/// <summary>Phlebotomist pre-printed barcodes (SQLScripts/2401): series, pool, and the app's validate-and-consume.</summary>
public interface ILabPhleboBarcodeService
{
    Task<IEnumerable<LabPhleboBarcodePhlebotomistModel>> GetPhlebotomistsAsync(int companyId, int branchId);
    Task<IEnumerable<LabPhleboBarcodeSeriesModel>> GetSeriesListAsync(int branchId, int phlebotomistId);
    Task<LabPhleboBarcodeGeneratedModel> GenerateAsync(LabPhleboBarcodeGenerateRequest r);
    Task CancelAsync(int seriesId, LabPhleboBarcodeCancelRequest r);
    Task<IEnumerable<LabPhleboBarcodeModel>> GetBarcodesAsync(int branchId, int seriesId);
    Task<(bool Success, string? Message)> ValidateConsumeAsync(LabPhleboBarcodeConsumeRequest r);
}

public class LabPhleboBarcodeService(IDbConnectionFactory db) : ILabPhleboBarcodeService
{
    public async Task<IEnumerable<LabPhleboBarcodePhlebotomistModel>> GetPhlebotomistsAsync(int companyId, int branchId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabPhleboBarcodePhlebotomistModel>("dbo.usp_Api_LabPhleboBarcode_Phlebotomists",
            new { CompanyId = companyId, BranchId = branchId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<LabPhleboBarcodeSeriesModel>> GetSeriesListAsync(int branchId, int phlebotomistId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabPhleboBarcodeSeriesModel>("dbo.usp_Api_LabPhleboBarcode_GetList",
            new { BranchId = branchId, PhlebotomistId = phlebotomistId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<LabPhleboBarcodeGeneratedModel> GenerateAsync(LabPhleboBarcodeGenerateRequest r)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<LabPhleboBarcodeGeneratedModel>("dbo.usp_Api_LabPhleboBarcode_Generate",
            new { r.CompanyId, r.BranchId, r.PhlebotomistId, r.Quantity, r.SampleCategoryCode, r.CreatedBy }, commandType: CommandType.StoredProcedure)
            ?? throw new InvalidOperationException("The series was not generated.");
    }

    public async Task CancelAsync(int seriesId, LabPhleboBarcodeCancelRequest r)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("dbo.usp_Api_LabPhleboBarcode_Cancel",
            new { r.BranchId, SeriesId = seriesId, r.Reason, r.UserId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<LabPhleboBarcodeModel>> GetBarcodesAsync(int branchId, int seriesId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabPhleboBarcodeModel>("dbo.usp_Api_LabPhleboBarcode_GetBarcodes",
            new { BranchId = branchId, SeriesId = seriesId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<(bool Success, string? Message)> ValidateConsumeAsync(LabPhleboBarcodeConsumeRequest r)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@BarcodeNo", r.BarcodeNo);
        p.Add("@PhlebotomistId", r.PhlebotomistId);
        p.Add("@LabOrderId", r.LabOrderId);
        p.Add("@SamplecollectionID", r.SamplecollectionID);
        p.Add("@UserId", r.UserId);
        p.Add("@Success", dbType: DbType.Boolean, direction: ParameterDirection.Output);
        p.Add("@ErrorMessage", dbType: DbType.String, size: 500, direction: ParameterDirection.Output);
        await con.ExecuteAsync("dbo.usp_Api_LabPhleboBarcode_ValidateConsume", p, commandType: CommandType.StoredProcedure);
        return (p.Get<bool>("@Success"), p.Get<string?>("@ErrorMessage"));
    }
}
