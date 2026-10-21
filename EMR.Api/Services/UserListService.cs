using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IUserListService
{
    Task<UserListPage> GetPagedAsync(UserListQuery query);
}

/// <summary>Settings > User Master list, paged and filtered on the server (SQLScripts/2314).</summary>
public class UserListService(IDbConnectionFactory connectionFactory) : IUserListService
{
    public async Task<UserListPage> GetPagedAsync(UserListQuery q)
    {
        var page = Math.Max(1, q.Page);
        var size = q.PageSize is < 1 or > 200 ? 25 : q.PageSize;
        using var db = connectionFactory.CreateConnection();
        using var multi = await db.QueryMultipleAsync("dbo.usp_Api_Users_GetPaged", new
        {
            q.CompanyId,
            VisibleBranchIds = q.VisibleBranchIds is null ? null : string.Join(",", q.VisibleBranchIds),
            q.CurrentBranchId,
            q.Search,
            q.UserType,
            q.Status,
            q.Role,
            PageNumber = page,
            PageSize = size
        }, commandType: CommandType.StoredProcedure);

        var result = new UserListPage
        {
            Kpis = await multi.ReadSingleOrDefaultAsync<UserListKpis>() ?? new UserListKpis(),
            FilteredCount = await multi.ReadSingleAsync<int>(),
            Page = page,
            PageSize = size
        };
        result.Items = (await multi.ReadAsync<UserListRow>()).ToList();
        return result;
    }
}
