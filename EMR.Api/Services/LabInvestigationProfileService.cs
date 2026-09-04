using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabInvestigationProfileService(IDbConnectionFactory db) : ILabInvestigationProfileService
{
    public async Task<IEnumerable<LabInvestigationProfileHeaderListItem>> GetListAsync(int? profileType = null, bool? status = null, string? search = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        var param = new DynamicParameters();
        param.Add("@ProfileType", profileType);
        param.Add("@Status", status);
        param.Add("@SearchTerm", search);
        param.Add("@CompanyId", companyId);

        return await con.QueryAsync<LabInvestigationProfileHeaderListItem>(
            "usp_Api_LabInvestigationProfile_GetList",
            param,
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<LabInvestigationProfileFullDetail?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var param = new DynamicParameters();
        param.Add("@Profile_ID", id);

        using var multi = await con.QueryMultipleAsync(
            "usp_Api_LabInvestigationProfile_GetById",
            param,
            commandType: CommandType.StoredProcedure
        );

        var header = await multi.ReadFirstOrDefaultAsync<LabInvestigationProfileHeaderListItem>();
        if (header == null) return null;

        var details = (await multi.ReadAsync<LabInvestigationProfileDetailListItem>()).ToList();

        return new LabInvestigationProfileFullDetail
        {
            Header = header,
            Details = details
        };
    }

    public async Task<int> SaveAsync(LabInvestigationProfileSaveRequest req)
    {
        using var con = db.CreateConnection();

        // Build DataTable for UDT
        var dt = new DataTable();
        dt.Columns.Add("Detail_ID", typeof(int));
        dt.Columns.Add("Test_ID", typeof(int));
        dt.Columns.Add("Sequence", typeof(int));

        foreach (var d in req.Details)
        {
            dt.Rows.Add(d.Detail_ID.HasValue && d.Detail_ID.Value > 0 ? d.Detail_ID.Value : DBNull.Value, d.Test_ID, d.Sequence);
        }

        var param = new DynamicParameters();
        param.Add("@Profile_ID", req.Profile_ID, DbType.Int32, ParameterDirection.InputOutput);
        param.Add("@CompanyId", req.CompanyId);
        param.Add("@Profile_Name", req.Profile_Name);
        param.Add("@Profile_Type", req.Profile_Type);
        param.Add("@Test_ID", req.Test_ID);
        param.Add("@MRP", req.MRP);
        param.Add("@Discount_Pct", req.Discount_Pct);
        param.Add("@Effective_Start_Date", req.Effective_Start_Date);
        param.Add("@Effective_End_Date", req.Effective_End_Date);
        param.Add("@Age_Operator", req.Age_Operator);
        param.Add("@Applicable_Age", req.Applicable_Age);
        param.Add("@Applicable_Gender", req.Applicable_Gender);
        param.Add("@Profile_TAT_Hours", req.Profile_TAT_Hours);
        param.Add("@Profile_NABL_Accredited", req.Profile_NABL_Accredited);
        param.Add("@Report_Print_Sequence", req.Report_Print_Sequence);
        param.Add("@Status", req.Status);
        param.Add("@UserId", req.UserId);
        param.Add("@Details", dt.AsTableValuedParameter("dbo.udt_LabInvestigationProfileDetail"));

        await con.ExecuteAsync(
            "usp_Api_LabInvestigationProfile_Save",
            param,
            commandType: CommandType.StoredProcedure
        );

        return param.Get<int>("@Profile_ID");
    }

    public async Task ToggleStatusAsync(LabInvestigationProfileToggleStatusRequest req)
    {
        using var con = db.CreateConnection();
        var param = new DynamicParameters();
        param.Add("@Profile_ID", req.Profile_ID);
        param.Add("@Status", req.Status);
        param.Add("@UserId", req.UserId);

        await con.ExecuteAsync(
            "usp_Api_LabInvestigationProfile_ToggleStatus",
            param,
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task DeleteAsync(int id)
    {
        using var con = db.CreateConnection();
        var param = new DynamicParameters();
        param.Add("@Profile_ID", id);

        await con.ExecuteAsync(
            "usp_Api_LabInvestigationProfile_Delete",
            param,
            commandType: CommandType.StoredProcedure
        );
    }
}
