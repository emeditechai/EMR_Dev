using System.Data;

namespace EMR.Web.Data;

public interface IDbConnectionFactory
{
    IDbConnection CreateConnection();
}
