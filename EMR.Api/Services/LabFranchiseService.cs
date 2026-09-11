using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabFranchiseService(IDbConnectionFactory connectionFactory) : ILabFranchiseService
{
    public async Task<IEnumerable<LabFranchiseModel>> GetListAsync(bool? status = null, bool? isActive = null, string? search = null, int? companyId = null, int? franchiseType = null, int? parentBranchId = null)
    {
        using var connection = connectionFactory.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@Status", status);
        parameters.Add("@IsActive", isActive);
        parameters.Add("@Search", search);
        parameters.Add("@CompanyId", companyId);
        parameters.Add("@FranchiseType", franchiseType);
        parameters.Add("@ParentBranchId", parentBranchId);

        return await connection.QueryAsync<LabFranchiseModel>(
            "dbo.usp_Api_LabFranchiseMaster_GetList",
            parameters,
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<LabFranchiseModel?> GetByIdAsync(int id)
    {
        using var connection = connectionFactory.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@Franchise_ID", id);

        return await connection.QueryFirstOrDefaultAsync<LabFranchiseModel>(
            "dbo.usp_Api_LabFranchiseMaster_GetById",
            parameters,
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<int> CreateAsync(LabFranchiseCreateRequestModel request)
    {
        using var connection = connectionFactory.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@CompanyId", request.CompanyId);
        parameters.Add("@Franchise_Name", request.Franchise_Name);
        parameters.Add("@Mobile_No", request.Mobile_No);
        parameters.Add("@Email", request.Email);
        parameters.Add("@Franchise_Type", request.Franchise_Type);
        parameters.Add("@Parent_Branch_ID", request.Parent_Branch_ID);
        parameters.Add("@Onboarding_Date", request.Onboarding_Date);
        parameters.Add("@Go_Live_Date", request.Go_Live_Date);
        parameters.Add("@Agreement_Doc_Path", request.Agreement_Doc_Path);
        parameters.Add("@Agreement_Valid_From", request.Agreement_Valid_From);
        parameters.Add("@Agreement_Valid_To", request.Agreement_Valid_To);
        parameters.Add("@Status", request.Status);
        parameters.Add("@IsActive", request.IsActive);
        parameters.Add("@Credit_Facility_Type", request.Credit_Facility_Type);
        parameters.Add("@Credit_Limit", request.Credit_Limit);
        parameters.Add("@Credit_Days", request.Credit_Days);
        parameters.Add("@Grace_Days", request.Grace_Days);
        parameters.Add("@Security_Deposit_Amount", request.Security_Deposit_Amount);
        parameters.Add("@Security_Deposit_Received_On", request.Security_Deposit_Received_On);
        parameters.Add("@Interest_On_Overdue_Percent", request.Interest_On_Overdue_Percent);
        parameters.Add("@Temporary_Limit_Increase", request.Temporary_Limit_Increase);
        parameters.Add("@Temp_Limit_Valid_Till", request.Temp_Limit_Valid_Till);
        parameters.Add("@UserId", request.UserId);
        parameters.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await connection.ExecuteAsync(
            "dbo.usp_Api_LabFranchiseMaster_Create",
            parameters,
            commandType: CommandType.StoredProcedure
        );

        return parameters.Get<int>("@NewId");
    }

    public async Task UpdateAsync(LabFranchiseUpdateRequestModel request)
    {
        using var connection = connectionFactory.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@Franchise_ID", request.Franchise_ID);
        parameters.Add("@Franchise_Name", request.Franchise_Name);
        parameters.Add("@Mobile_No", request.Mobile_No);
        parameters.Add("@Email", request.Email);
        parameters.Add("@Franchise_Type", request.Franchise_Type);
        parameters.Add("@Parent_Branch_ID", request.Parent_Branch_ID);
        parameters.Add("@Onboarding_Date", request.Onboarding_Date);
        parameters.Add("@Go_Live_Date", request.Go_Live_Date);
        parameters.Add("@Agreement_Doc_Path", request.Agreement_Doc_Path);
        parameters.Add("@Agreement_Valid_From", request.Agreement_Valid_From);
        parameters.Add("@Agreement_Valid_To", request.Agreement_Valid_To);
        parameters.Add("@Status", request.Status);
        parameters.Add("@IsActive", request.IsActive);
        parameters.Add("@Credit_Facility_Type", request.Credit_Facility_Type);
        parameters.Add("@Credit_Limit", request.Credit_Limit);
        parameters.Add("@Credit_Days", request.Credit_Days);
        parameters.Add("@Grace_Days", request.Grace_Days);
        parameters.Add("@Security_Deposit_Amount", request.Security_Deposit_Amount);
        parameters.Add("@Security_Deposit_Received_On", request.Security_Deposit_Received_On);
        parameters.Add("@Interest_On_Overdue_Percent", request.Interest_On_Overdue_Percent);
        parameters.Add("@Temporary_Limit_Increase", request.Temporary_Limit_Increase);
        parameters.Add("@Temp_Limit_Valid_Till", request.Temp_Limit_Valid_Till);
        parameters.Add("@UserId", request.UserId);

        await connection.ExecuteAsync(
            "dbo.usp_Api_LabFranchiseMaster_Update",
            parameters,
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task ToggleStatusAsync(LabFranchiseToggleStatusRequestModel request)
    {
        using var connection = connectionFactory.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@Franchise_ID", request.Franchise_ID);
        parameters.Add("@IsActive", request.IsActive);
        parameters.Add("@UserId", request.UserId);

        await connection.ExecuteAsync(
            "dbo.usp_Api_LabFranchiseMaster_ToggleStatus",
            parameters,
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task ToggleSuspensionAsync(LabFranchiseToggleSuspensionRequestModel request)
    {
        using var connection = connectionFactory.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@Franchise_ID", request.Franchise_ID);
        parameters.Add("@Status", request.Status);
        parameters.Add("@Suspension_Reason", request.Suspension_Reason);
        parameters.Add("@UserId", request.UserId);

        await connection.ExecuteAsync(
            "dbo.usp_Api_LabFranchiseMaster_ToggleSuspension",
            parameters,
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task DeleteAsync(int id, int? userId = null)
    {
        using var connection = connectionFactory.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@Franchise_ID", id);
        parameters.Add("@UserId", userId);

        await connection.ExecuteAsync(
            "dbo.usp_Api_LabFranchiseMaster_Delete",
            parameters,
            commandType: CommandType.StoredProcedure
        );
    }
}
