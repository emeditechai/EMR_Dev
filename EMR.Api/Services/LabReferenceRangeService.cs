using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabReferenceRangeService(IDbConnectionFactory db) : ILabReferenceRangeService
{
    public async Task<IEnumerable<LabReferenceRangeListItem>> GetListAsync(int? testId, string? gender, bool? status, string? search, int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabReferenceRangeListItem>(
            "usp_Api_LabReferenceRange_GetList",
            new { Test_ID = testId, Gender = gender, Status = status, Search = search, CompanyId = companyId ?? 1 },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<LabReferenceRangeDetail?> GetByIdAsync(int id, int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<LabReferenceRangeDetail>(
            "usp_Api_LabReferenceRange_GetById",
            new { RefRange_ID = id, CompanyId = companyId ?? 1 },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<int> CreateAsync(LabReferenceRangeCreateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@CompanyId", req.CompanyId);
        p.Add("@Test_ID", req.Test_ID);
        p.Add("@Method_ID", req.Method_ID);
        p.Add("@Unit_ID", req.Unit_ID);
        p.Add("@Is_Common_For_All", req.Is_Common_For_All);
        p.Add("@Age_From", req.Age_From);
        p.Add("@Age_To", req.Age_To);
        p.Add("@Age_Unit", req.Age_Unit);
        p.Add("@Gender", req.Gender);
        p.Add("@Pregnancy_Trimester", req.Pregnancy_Trimester);
        p.Add("@Low_Value", req.Low_Value);
        p.Add("@High_Value", req.High_Value);
        p.Add("@Tier", req.Tier);
        p.Add("@Low_Threshold", req.Low_Threshold);
        p.Add("@High_Threshold", req.High_Threshold);
        p.Add("@Notification_Required", req.Notification_Required);
        p.Add("@Acknowledgement_Required", req.Acknowledgement_Required);
        p.Add("@Special_Remarks", req.Special_Remarks);
        p.Add("@Range_Source", req.Range_Source);
        p.Add("@Effective_From", req.Effective_From);
        p.Add("@Effective_To", req.Effective_To);
        p.Add("@Status", req.Status);
        p.Add("@CreatedBy", req.UserId);
        p.Add("@NewRefRange_ID", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await con.ExecuteAsync("usp_Api_LabReferenceRange_Create", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewRefRange_ID");
    }

    public async Task<int> BulkSaveAsync(LabReferenceRangeBulkSaveRequest req)
    {
        using var con = db.CreateConnection();
        var json = System.Text.Json.JsonSerializer.Serialize(req.RangeItems);
        var p = new DynamicParameters();
        p.Add("@CompanyId", req.CompanyId);
        p.Add("@Test_ID", req.Test_ID);
        p.Add("@Method_ID", req.Method_ID);
        p.Add("@Unit_ID", req.Unit_ID);
        p.Add("@Is_Common_For_All", req.Is_Common_For_All);
        p.Add("@Notification_Required", req.Notification_Required);
        p.Add("@Acknowledgement_Required", req.Acknowledgement_Required);
        p.Add("@Range_Source", req.Range_Source);
        p.Add("@Effective_From", req.Effective_From);
        p.Add("@Effective_To", req.Effective_To);
        p.Add("@RangeItemsJson", json);
        p.Add("@CreatedBy", req.UserId);
        p.Add("@InsertedCount", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await con.ExecuteAsync("usp_Api_LabReferenceRange_BulkSave", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@InsertedCount");
    }

    public async Task UpdateAsync(LabReferenceRangeUpdateRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabReferenceRange_Update",
            new
            {
                RefRange_ID = req.RefRange_ID,
                CompanyId = req.CompanyId,
                Test_ID = req.Test_ID,
                Method_ID = req.Method_ID,
                Unit_ID = req.Unit_ID,
                Is_Common_For_All = req.Is_Common_For_All,
                Age_From = req.Age_From,
                Age_To = req.Age_To,
                Age_Unit = req.Age_Unit,
                Gender = req.Gender,
                Pregnancy_Trimester = req.Pregnancy_Trimester,
                Low_Value = req.Low_Value,
                High_Value = req.High_Value,
                Tier = req.Tier,
                Low_Threshold = req.Low_Threshold,
                High_Threshold = req.High_Threshold,
                Notification_Required = req.Notification_Required,
                Acknowledgement_Required = req.Acknowledgement_Required,
                Special_Remarks = req.Special_Remarks,
                Range_Source = req.Range_Source,
                Effective_From = req.Effective_From,
                Effective_To = req.Effective_To,
                Status = req.Status,
                ModifiedBy = req.UserId
            },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task DeleteAsync(int id, int companyId, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabReferenceRange_Delete",
            new { RefRange_ID = id, CompanyId = companyId, ModifiedBy = userId },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<bool> ToggleStatusAsync(int id, int companyId, int? userId)
    {
        using var con = db.CreateConnection();
        var newStatus = await con.ExecuteScalarAsync<bool>(
            "usp_Api_LabReferenceRange_ToggleStatus",
            new { RefRange_ID = id, CompanyId = companyId, ModifiedBy = userId },
            commandType: CommandType.StoredProcedure
        );
        return newStatus;
    }

    public async Task<IEnumerable<LabNumericTestOption>> GetNumericTestsAsync(int companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabNumericTestOption>(
            "usp_Api_LabReferenceRange_GetNumericTests",
            new { CompanyId = companyId },
            commandType: CommandType.StoredProcedure
        );
    }
}
