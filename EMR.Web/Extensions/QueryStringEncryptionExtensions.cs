using EMR.Web.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.AspNetCore.Routing;

namespace EMR.Web.Extensions;

/// <summary>
/// Encrypted query strings (QUERY_STRING_ENCRYPTION_ARCHITECTURE.md): every parameter goes into one token, ?q=...,
/// which QueryStringDecryptionMiddleware decrypts before model binding. Use these instead of the plain versions:
///   Url.Action("Edit", new { id })               -> Url.ActionEncrypted("Edit", new { id })
///   RedirectToAction(nameof(Edit), new { id })   -> this.RedirectToActionEncrypted(nameof(Edit), new { id })
///   asp-route-id / asp-route-x (Razor)           -> asp-encrypted-id / asp-encrypted-route-x
/// </summary>
public static class QueryStringEncryptionExtensions
{
    private static IQueryStringEncryptionService? Service(HttpContext? ctx) =>
        ctx?.RequestServices.GetService(typeof(IQueryStringEncryptionService)) as IQueryStringEncryptionService;

    /// <summary>The route values as name -> text (nulls left out, as routing does).</summary>
    private static Dictionary<string, string?> Values(object? routeValues)
    {
        var dict = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
        if (routeValues is null) return dict;
        foreach (var kv in routeValues as IDictionary<string, object?> ?? new RouteValueDictionary(routeValues))
            if (kv.Value is not null)
                dict[kv.Key] = kv.Value switch
                {
                    bool b => b ? "true" : "false",
                    IFormattable f => f.ToString(null, System.Globalization.CultureInfo.InvariantCulture),
                    _ => kv.Value.ToString()
                };
        return dict;
    }

    /// <summary>url + ?q=token (or &amp;q= when it already has a query); a #fragment is kept at the end.</summary>
    public static string AppendEncrypted(string url, IQueryStringEncryptionService? service, object? routeValues)
    {
        var values = Values(routeValues);
        if (service is null || values.Count == 0) return url;
        var hash = url.IndexOf('#');
        var fragment = hash >= 0 ? url[hash..] : string.Empty;
        var path = hash >= 0 ? url[..hash] : url;
        return $"{path}{(path.Contains('?') ? '&' : '?')}q={service.EncryptParameters(values)}{fragment}";
    }

    /// <summary>Url.Action with the route values encrypted into ?q=.</summary>
    public static string ActionEncrypted(this IUrlHelper url, string? action, object? routeValues) =>
        url.ActionEncrypted(action, null, routeValues);

    /// <summary>Url.Action with the route values encrypted into ?q=.</summary>
    public static string ActionEncrypted(this IUrlHelper url, string? action, string? controller, object? routeValues)
    {
        var baseUrl = url.Action(action, controller) ?? string.Empty;
        return AppendEncrypted(baseUrl, Service(url.ActionContext.HttpContext), routeValues);
    }

    /// <summary>RedirectToAction with the route values encrypted into ?q=.</summary>
    public static RedirectResult RedirectToActionEncrypted(this Controller c, string? action, object? routeValues) =>
        c.RedirectToActionEncrypted(action, null, routeValues);

    /// <summary>RedirectToAction with the route values encrypted into ?q=.</summary>
    public static RedirectResult RedirectToActionEncrypted(this Controller c, string? action, string? controller, object? routeValues) =>
        new(c.Url.ActionEncrypted(action, controller, routeValues));

    /// <summary>Kept for existing views: /controller/action?q=token.</summary>
    public static string EncryptedUrl(this IHtmlHelper html, string action, string controller, object routeValues)
    {
        var url = html.ViewContext.HttpContext.RequestServices.GetService(typeof(Microsoft.AspNetCore.Mvc.Routing.IUrlHelperFactory)) is Microsoft.AspNetCore.Mvc.Routing.IUrlHelperFactory f
            ? f.GetUrlHelper(html.ViewContext).Action(action, controller) ?? $"/{controller}/{action}"
            : $"/{controller}/{action}";
        return AppendEncrypted(url, Service(html.ViewContext.HttpContext), routeValues);
    }

    public static string EncryptId(this IHtmlHelper html, object id)
    {
        var encryptionService = Service(html.ViewContext.HttpContext);
        if (encryptionService == null || id == null)
            return id?.ToString() ?? string.Empty;

        return encryptionService.Encrypt(id.ToString()!);
    }
}
