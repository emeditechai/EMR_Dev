using System.Xml.Linq;
using Dapper;
using EMR.Api.Data;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.DataProtection.KeyManagement;
using Microsoft.AspNetCore.DataProtection.Repositories;

namespace EMR.Api.Services;

/// <summary>
/// EMR.Web's ASP.NET data protection key ring (dbo.DataProtectionKeys, application "EMR_Web_App"), read from the database
/// and never written: EMR.Api decrypts what EMR.Web encrypted with it - the SMTP and the LAB FTP passwords.
/// </summary>
public static class WebKeyRing
{
    private static readonly object Gate = new();
    private static IDataProtectionProvider? _provider;

    public static IDataProtectionProvider Provider(IDbConnectionFactory db)
    {
        lock (Gate)
        {
            if (_provider != null) return _provider;
            var services = new ServiceCollection();
            services.AddDataProtection().SetApplicationName("EMR_Web_App").DisableAutomaticKeyGeneration();
            services.Configure<KeyManagementOptions>(o => o.XmlRepository = new DbKeyRing(db));
            return _provider = services.BuildServiceProvider().GetRequiredService<IDataProtectionProvider>();
        }
    }

    private sealed class DbKeyRing(IDbConnectionFactory db) : IXmlRepository
    {
        public IReadOnlyCollection<XElement> GetAllElements()
        {
            using var con = db.CreateConnection();
            return con.Query<string>("SELECT Xml FROM dbo.DataProtectionKeys WHERE Xml IS NOT NULL").Select(x => XElement.Parse(x)).ToList();
        }

        public void StoreElement(XElement element, string friendlyName) =>
            throw new InvalidOperationException("EMR.Api reads EMR.Web's key ring; it does not write keys.");
    }
}
