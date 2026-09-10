using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabSampleRejectionReasonService(IDbConnectionFactory connectionFactory) : ILabSampleRejectionReasonService
{
    public async Task<IEnumerable<LabSampleRejectionReasonModel>> GetListAsync(bool? status = null, int? sampleTypeId = null, string? search = null, int? companyId = null)
    {
        using var db = connectionFactory.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@Status", status);
        parameters.Add("@Sample_Type_ID", sampleTypeId);
        parameters.Add("@Search", search);
        parameters.Add("@CompanyId", companyId);

        return await db.QueryAsync<LabSampleRejectionReasonModel>(
            "dbo.usp_Api_LabSampleRejectionReasonMaster_GetList",
            parameters,
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<LabSampleRejectionReasonModel?> GetByIdAsync(int id)
    {
        using var db = connectionFactory.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@Reason_ID", id);

        return await db.QueryFirstOrDefaultAsync<LabSampleRejectionReasonModel>(
            "dbo.usp_Api_LabSampleRejectionReasonMaster_GetById",
            parameters,
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<int> CreateAsync(LabSampleRejectionReasonCreateRequestModel request)
    {
        using var db = connectionFactory.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@Reason_Text", request.Reason_Text);
        parameters.Add("@Applicable_Sample_Type_ID", request.Applicable_Sample_Type_ID);
        parameters.Add("@Display_Order", request.Display_Order);
        parameters.Add("@CompanyId", request.CompanyId);
        parameters.Add("@UserId", request.UserId);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await db.ExecuteAsync(
            "dbo.usp_Api_LabSampleRejectionReasonMaster_Create",
            parameters,
            commandType: CommandType.StoredProcedure
        );

        return parameters.Get<int>("@NewId");
    }

    public async Task UpdateAsync(LabSampleRejectionReasonUpdateRequestModel request)
    {
        using var db = connectionFactory.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@Reason_ID", request.Reason_ID);
        parameters.Add("@Reason_Text", request.Reason_Text);
        parameters.Add("@Applicable_Sample_Type_ID", request.Applicable_Sample_Type_ID);
        parameters.Add("@Display_Order", request.Display_Order);
        parameters.Add("@Status", request.Status);
        parameters.Add("@UserId", request.UserId);

        await db.ExecuteAsync(
            "dbo.usp_Api_LabSampleRejectionReasonMaster_Update",
            parameters,
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task ToggleStatusAsync(LabSampleRejectionReasonToggleStatusRequestModel request)
    {
        using var db = connectionFactory.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@Reason_ID", request.Reason_ID);
        parameters.Add("@Status", request.Status);
        parameters.Add("@UserId", request.UserId);

        await db.ExecuteAsync(
            "dbo.usp_Api_LabSampleRejectionReasonMaster_ToggleStatus",
            parameters,
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task DeleteAsync(int id, int? userId = null)
    {
        using var db = connectionFactory.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@Reason_ID", id);
        parameters.Add("@UserId", userId);

        await db.ExecuteAsync(
            "dbo.usp_Api_LabSampleRejectionReasonMaster_Delete",
            parameters,
            commandType: CommandType.StoredProcedure
        );
    }
}
