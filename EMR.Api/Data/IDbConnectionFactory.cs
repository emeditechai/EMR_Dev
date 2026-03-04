using System.Data;

namespace EMR.Api.Data;

public interface IDbConnectionFactory
{
    IDbConnection CreateConnection();
}
