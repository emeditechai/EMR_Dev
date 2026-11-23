using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabRateCardService(IDbConnectionFactory db) : ILabRateCardService
{
    public async Task<IEnumerable<LabRateCardHeaderModel>> GetListAsync(string? rateType, int? branchId, bool? status, int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabRateCardHeaderModel>(
            "usp_Api_LabRateCardMaster_GetList",
            new { RateType = rateType, BranchId = branchId, Status = status, CompanyId = companyId },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<LabRateCardFullModel?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        using var multi = await con.QueryMultipleAsync(
            "usp_Api_LabRateCardMaster_GetById",
            new { RateCard_ID = id },
            commandType: CommandType.StoredProcedure
        );

        var header = await multi.ReadFirstOrDefaultAsync<LabRateCardHeaderModel>();
        if (header == null) return null;

        var details = (await multi.ReadAsync<LabRateCardDetailModel>()).ToList();

        // government scheme flag and the scheme's code of each item (SQLScripts/2532)
        using (var scheme = await con.QueryMultipleAsync("usp_Api_LabRateCard_GetScheme", new { RateCard_ID = id }, commandType: CommandType.StoredProcedure))
        {
            var flag = await scheme.ReadFirstOrDefaultAsync<(bool Is_Govt_Scheme, string? Scheme_Name)>();
            header.Is_Govt_Scheme = flag.Is_Govt_Scheme;
            header.Scheme_Name = flag.Scheme_Name;
            var codes = (await scheme.ReadAsync<(string Item_Type, int Item_ID, string Scheme_Code)>())
                .ToDictionary(c => (c.Item_Type, c.Item_ID), c => c.Scheme_Code);
            foreach (var d in details)
                if (codes.TryGetValue((d.Item_Type, d.Item_ID), out var code)) d.Scheme_Code = code;
        }

        return new LabRateCardFullModel
        {
            Header = header,
            Details = details
        };
    }

    public async Task<int> SaveAsync(LabRateCardSaveRequest req)
    {
        using var con = db.CreateConnection();

        // Create DataTable for UDT
        var dt = new DataTable();
        dt.Columns.Add("Detail_ID", typeof(int));
        dt.Columns.Add("Item_Type", typeof(string));
        dt.Columns.Add("Item_ID", typeof(int));
        dt.Columns.Add("Rate", typeof(decimal));
        dt.Columns.Add("Is_Discount_Allowed", typeof(bool));
        dt.Columns.Add("Status", typeof(bool));

        foreach (var item in req.Details)
        {
            dt.Rows.Add(
                item.Detail_ID > 0 ? item.Detail_ID : DBNull.Value,
                item.Item_Type,
                item.Item_ID,
                item.Rate,
                item.Is_Discount_Allowed,
                item.Status
            );
        }

        var p = new DynamicParameters();
        p.Add("@RateCard_ID", req.RateCard_ID, dbType: DbType.Int32, direction: ParameterDirection.InputOutput);
        p.Add("@CompanyId", req.CompanyId);
        p.Add("@Branch_ID", req.Branch_ID);
        p.Add("@B2CIdentity_ID", req.B2CIdentity_ID);
        p.Add("@Rate_Type", req.Rate_Type);
        p.Add("@Effective_From", req.Effective_From);
        p.Add("@Effective_To", req.Effective_To);
        p.Add("@Status", req.Status);
        p.Add("@UserId", req.UserId);
        p.Add("@Details", dt.AsTableValuedParameter("dbo.udt_LabRateCardDetail"));

        await con.ExecuteAsync("usp_Api_LabRateCardMaster_Save", p, commandType: CommandType.StoredProcedure);
        var rateCardId = p.Get<int>("@RateCard_ID");

        // government scheme (e.g. WBHS): flag, name and the scheme code of each item (SQLScripts/2532)
        await con.ExecuteAsync("usp_Api_LabRateCard_SaveScheme", new
        {
            RateCard_ID = rateCardId,
            req.Is_Govt_Scheme,
            req.Scheme_Name,
            CodesJson = req.Is_Govt_Scheme
                ? System.Text.Json.JsonSerializer.Serialize(req.Details.Select(d => new { d.Item_Type, d.Item_ID, d.Scheme_Code }))
                : null,
            req.UserId
        }, commandType: CommandType.StoredProcedure);
        return rateCardId;
    }

    public async Task ToggleStatusAsync(LabRateCardToggleStatusRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabRateCardMaster_ToggleStatus",
            new
            {
                RateCard_ID = req.RateCard_ID,
                Status = req.Status,
                UserId = req.UserId
            },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task DeleteAsync(int id, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabRateCardMaster_Delete",
            new { RateCard_ID = id, UserId = userId },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<IEnumerable<LabItemModel>> GetAllItemsAsync(int companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabItemModel>(
            "usp_Api_LabItems_GetAll",
            new { CompanyId = companyId },
            commandType: CommandType.StoredProcedure
        );
    }
}
