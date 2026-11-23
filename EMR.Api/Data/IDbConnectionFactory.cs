using System.Data;

namespace EMR.Api.Data;

public interface IDbConnectionFactory : EMR.Common.IDbConnections
{
    IDbConnection CreateConnection();
}
