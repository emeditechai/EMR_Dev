using System.Data;

namespace EMR.Common;

/// <summary>A new SQL connection to the EMR database: EMR.Web's and EMR.Api's IDbConnectionFactory are both one.</summary>
public interface IDbConnections
{
    IDbConnection CreateConnection();
}
