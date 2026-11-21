using System.Data;

namespace EMR.Web.Data;

public interface IDbConnectionFactory : EMR.Common.IDbConnections
{
    IDbConnection CreateConnection();
}
