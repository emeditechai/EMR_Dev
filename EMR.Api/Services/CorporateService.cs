using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class CorporateService(IDbConnectionFactory db) : ICorporateService
{
    public async Task<IEnumerable<CorporateListItemDto>> GetListAsync(
        int? branchId = null,
        string? corporateType = null,
        bool? status = null,
        string? search = null,
        int? companyId = null)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@BranchId", branchId);
        parameters.Add("@CorporateType", string.IsNullOrWhiteSpace(corporateType) ? null : corporateType);
        parameters.Add("@Status", status);
        parameters.Add("@Search", string.IsNullOrWhiteSpace(search) ? null : search.Trim());
        parameters.Add("@CompanyId", companyId);

        return await conn.QueryAsync<CorporateListItemDto>(
            "dbo.usp_Api_Corporate_GetList",
            parameters,
            commandType: CommandType.StoredProcedure);
    }

    public async Task<CorporateDetailDto?> GetByIdAsync(int id)
    {
        using var conn = db.CreateConnection();
        return await conn.QueryFirstOrDefaultAsync<CorporateDetailDto>(
            "dbo.usp_Corporate_GetById",
            new { Corporate_ID = id },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(CorporateSaveRequest request)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@CompanyId", request.CompanyId);
        parameters.Add("@Branch_ID", request.Branch_ID);
        parameters.Add("@Corporate_Code", string.IsNullOrWhiteSpace(request.Corporate_Code) ? null : request.Corporate_Code.Trim().ToUpper());
        parameters.Add("@Corporate_Name", request.Corporate_Name.Trim());
        parameters.Add("@Corporate_Type", request.Corporate_Type.Trim());
        parameters.Add("@Effective_From", request.Effective_From);
        parameters.Add("@Effective_To", request.Effective_To);
        parameters.Add("@Credit_Limit", request.Credit_Limit);
        parameters.Add("@Credit_Days", request.Credit_Days);
        parameters.Add("@BillingCycle", request.BillingCycle.Trim());
        parameters.Add("@Contact_No", request.Contact_No.Trim());
        parameters.Add("@Email", string.IsNullOrWhiteSpace(request.Email) ? null : request.Email.Trim());
        parameters.Add("@Address", string.IsNullOrWhiteSpace(request.Address) ? null : request.Address.Trim());
        parameters.Add("@Pincode", string.IsNullOrWhiteSpace(request.Pincode) ? null : request.Pincode.Trim());
        parameters.Add("@Status", request.Status);
        parameters.Add("@CreatedBy", request.UserId);
        parameters.Add("@NewCorporate_ID", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await conn.ExecuteAsync("dbo.usp_Corporate_Create", parameters, commandType: CommandType.StoredProcedure);
        return parameters.Get<int>("@NewCorporate_ID");
    }

    public async Task<bool> UpdateAsync(int id, CorporateSaveRequest request)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@Corporate_ID", id);
        parameters.Add("@Branch_ID", request.Branch_ID);
        parameters.Add("@Corporate_Code", string.IsNullOrWhiteSpace(request.Corporate_Code) ? null : request.Corporate_Code.Trim().ToUpper());
        parameters.Add("@Corporate_Name", request.Corporate_Name.Trim());
        parameters.Add("@Corporate_Type", request.Corporate_Type.Trim());
        parameters.Add("@Effective_From", request.Effective_From);
        parameters.Add("@Effective_To", request.Effective_To);
        parameters.Add("@Credit_Limit", request.Credit_Limit);
        parameters.Add("@Credit_Days", request.Credit_Days);
        parameters.Add("@BillingCycle", request.BillingCycle.Trim());
        parameters.Add("@Contact_No", request.Contact_No.Trim());
        parameters.Add("@Email", string.IsNullOrWhiteSpace(request.Email) ? null : request.Email.Trim());
        parameters.Add("@Address", string.IsNullOrWhiteSpace(request.Address) ? null : request.Address.Trim());
        parameters.Add("@Pincode", string.IsNullOrWhiteSpace(request.Pincode) ? null : request.Pincode.Trim());
        parameters.Add("@Status", request.Status);
        parameters.Add("@ModifiedBy", request.UserId);

        var affected = await conn.ExecuteAsync("dbo.usp_Corporate_Update", parameters, commandType: CommandType.StoredProcedure);
        return affected > 0;
    }

    public async Task<bool> ToggleStatusAsync(int id, int? userId = null)
    {
        using var conn = db.CreateConnection();
        var result = await conn.QueryFirstOrDefaultAsync<bool>(
            "dbo.usp_Corporate_ToggleStatus",
            new { Corporate_ID = id, ModifiedBy = userId },
            commandType: CommandType.StoredProcedure);
        return result;
    }

    public async Task<bool> DeleteAsync(int id, int? userId = null)
    {
        using var conn = db.CreateConnection();
        var affected = await conn.ExecuteAsync(
            "dbo.usp_Corporate_Delete",
            new { Corporate_ID = id, ModifiedBy = userId },
            commandType: CommandType.StoredProcedure);
        return affected > 0;
    }
}
