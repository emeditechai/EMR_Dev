using System.Data;
using Dapper;
using EMR.Web.Data;

namespace EMR.Web.Services;

public class DiscountTypeService(IDbConnectionFactory db) : IDiscountTypeService
{
    public async Task<bool> NameExistsAsync(string name, int? excludeId = null, int? companyId = null)
    {
        using var conn = db.CreateConnection();
        const string sql = @"
            SELECT COUNT(1) FROM dbo.DiscountTypeMaster 
            WHERE DiscountTypeName = @Name
              AND (@CompanyId IS NULL OR CompanyId = @CompanyId)
              AND (@ExcludeId IS NULL OR DiscountTypeId <> @ExcludeId)";
        var count = await conn.ExecuteScalarAsync<int>(sql, new { Name = name.Trim(), CompanyId = companyId, ExcludeId = excludeId });
        return count > 0;
    }
}
