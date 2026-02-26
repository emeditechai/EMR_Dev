using System.Data;
using Microsoft.Data.SqlClient;

namespace EMR.Web.Data;

public class DbConnectionFactory(IConfiguration configuration) : IDbConnectionFactory
{
    private readonly string _connectionString =
        configuration.GetConnectionString("DefaultConnection")
        ?? throw new InvalidOperationException("DefaultConnection not configured.");

    public IDbConnection CreateConnection() => new SqlConnection(_connectionString);
}
