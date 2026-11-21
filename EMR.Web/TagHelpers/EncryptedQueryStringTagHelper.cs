using EMR.Web.Services;
using Microsoft.AspNetCore.Razor.TagHelpers;

namespace EMR.Web.TagHelpers;

/// <summary>
/// Puts a link's / form's parameters in one encrypted token (?q=...) instead of a plain query string
/// (QUERY_STRING_ENCRYPTION_ARCHITECTURE.md). QueryStringDecryptionMiddleware decrypts it, so actions bind as usual.
///   asp-encrypted-id="@x"                 - the record id (as in the lab masters)
///   asp-encrypted-route-name="@value"     - any parameter: use it everywhere asp-route-name would be used
///   asp-encrypted-all-route-data="@dict"  - a dictionary of parameters (instead of asp-all-route-data)
///   asp-encrypted-qs="a=1&amp;b=2"        - a raw query string
/// Runs after the built-in anchor / form tag helpers (Order -1000), so href / action is already generated.
/// </summary>
[HtmlTargetElement("a", Attributes = "asp-encrypted-qs")]
[HtmlTargetElement("form", Attributes = "asp-encrypted-qs")]
[HtmlTargetElement("a", Attributes = "asp-encrypted-id")]
[HtmlTargetElement("form", Attributes = "asp-encrypted-id")]
[HtmlTargetElement("a", Attributes = RoutePrefix + "*")]
[HtmlTargetElement("form", Attributes = RoutePrefix + "*")]
[HtmlTargetElement("a", Attributes = AllRouteData)]
[HtmlTargetElement("form", Attributes = AllRouteData)]
public class EncryptedQueryStringTagHelper(IQueryStringEncryptionService encryptionService) : TagHelper
{
    private const string RoutePrefix = "asp-encrypted-route-";
    private const string AllRouteData = "asp-encrypted-all-route-data";

    [HtmlAttributeName("asp-encrypted-qs")]
    public string? RawQueryString { get; set; }

    [HtmlAttributeName("asp-encrypted-id")]
    public object? RouteId { get; set; }

    [HtmlAttributeName(AllRouteData, DictionaryAttributePrefix = RoutePrefix)]
    public IDictionary<string, string?> RouteValues { get; set; } = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);

    public override void Process(TagHelperContext context, TagHelperOutput output)
    {
        var isAnchor = context.TagName.Equals("a", StringComparison.OrdinalIgnoreCase);
        var urlAttribute = isAnchor ? "href" : "action";
        var targetUrl = output.Attributes[urlAttribute]?.Value?.ToString();

        if (string.IsNullOrEmpty(targetUrl))
            return;

        var parameters = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);

        foreach (var kv in RouteValues)
            if (kv.Value != null) parameters[kv.Key] = kv.Value;

        if (RouteId != null)
            parameters["id"] = RouteId.ToString();

        if (!string.IsNullOrEmpty(RawQueryString))
        {
            var parsed = System.Web.HttpUtility.ParseQueryString(RawQueryString);
            foreach (string? key in parsed.AllKeys)
                if (!string.IsNullOrEmpty(key)) parameters[key] = parsed[key];
        }

        if (parameters.Count > 0)
        {
            // a #fragment stays at the end of the address
            var hash = targetUrl.IndexOf('#');
            var fragment = hash >= 0 ? targetUrl[hash..] : string.Empty;
            var path = hash >= 0 ? targetUrl[..hash] : targetUrl;
            var separator = path.Contains('?') ? "&" : "?";
            output.Attributes.SetAttribute(urlAttribute, $"{path}{separator}q={encryptionService.EncryptParameters(parameters)}{fragment}");
        }
    }
}
