using EMR.Web.Services;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Extensions;

public static class QueryStringEncryptionExtensions
{
    public static string EncryptedUrl(this IHtmlHelper html, string action, string controller, object routeValues)
    {
        var encryptionService = html.ViewContext.HttpContext.RequestServices.GetService(typeof(IQueryStringEncryptionService)) as IQueryStringEncryptionService;
        string baseUrl = $"/{controller}/{action}";

        if (encryptionService == null || routeValues == null)
            return baseUrl;

        var dict = new Dictionary<string, string?>();
        var props = routeValues.GetType().GetProperties();
        foreach (var prop in props)
        {
            var val = prop.GetValue(routeValues);
            if (val != null)
            {
                dict[prop.Name] = val.ToString();
            }
        }

        if (dict.Count == 0)
            return baseUrl;

        string token = encryptionService.EncryptParameters(dict);
        return $"{baseUrl}?q={token}";
    }

    public static string EncryptId(this IHtmlHelper html, object id)
    {
        var encryptionService = html.ViewContext.HttpContext.RequestServices.GetService(typeof(IQueryStringEncryptionService)) as IQueryStringEncryptionService;
        if (encryptionService == null || id == null)
            return id?.ToString() ?? string.Empty;

        return encryptionService.Encrypt(id.ToString()!);
    }
}
