using System.Data;
using Microsoft.Data.SqlClient;

namespace EMR.Api.Data;

public class DbConnectionFactory(IConfiguration configuration) : IDbConnectionFactory
{
    private readonly string _cs =
        configuration.GetConnectionString("DefaultConnection")
        ?? throw new InvalidOperationException("DefaultConnection is not configured.");

    public IDbConnection CreateConnection() => new SqlConnection(_cs);
}
