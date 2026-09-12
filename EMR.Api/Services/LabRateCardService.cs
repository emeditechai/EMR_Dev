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
        return p.Get<int>("@RateCard_ID");
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
