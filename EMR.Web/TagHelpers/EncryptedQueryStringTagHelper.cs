using EMR.Web.Services;
using Microsoft.AspNetCore.Razor.TagHelpers;

namespace EMR.Web.TagHelpers;

[HtmlTargetElement("a", Attributes = "asp-encrypted-qs")]
[HtmlTargetElement("form", Attributes = "asp-encrypted-qs")]
[HtmlTargetElement("a", Attributes = "asp-encrypted-id")]
[HtmlTargetElement("form", Attributes = "asp-encrypted-id")]
public class EncryptedQueryStringTagHelper(IQueryStringEncryptionService encryptionService) : TagHelper
{
    [HtmlAttributeName("asp-encrypted-qs")]
    public string? RawQueryString { get; set; }

    [HtmlAttributeName("asp-encrypted-id")]
    public object? RouteId { get; set; }

    public override void Process(TagHelperContext context, TagHelperOutput output)
    {
        string? targetUrl = null;

        if (context.TagName.Equals("a", StringComparison.OrdinalIgnoreCase))
        {
            targetUrl = output.Attributes["href"]?.Value?.ToString();
        }
        else if (context.TagName.Equals("form", StringComparison.OrdinalIgnoreCase))
        {
            targetUrl = output.Attributes["action"]?.Value?.ToString();
        }

        if (string.IsNullOrEmpty(targetUrl))
            return;

        var parameters = new Dictionary<string, string?>();

        if (RouteId != null)
        {
            parameters["id"] = RouteId.ToString();
        }

        if (!string.IsNullOrEmpty(RawQueryString))
        {
            var parsed = System.Web.HttpUtility.ParseQueryString(RawQueryString);
            foreach (string? key in parsed.AllKeys)
            {
                if (!string.IsNullOrEmpty(key))
                {
                    parameters[key] = parsed[key];
                }
            }
        }

        if (parameters.Count > 0)
        {
            string encryptedToken = encryptionService.EncryptParameters(parameters);
            string separator = targetUrl.Contains('?') ? "&" : "?";
            string newUrl = $"{targetUrl}{separator}q={encryptedToken}";

            if (context.TagName.Equals("a", StringComparison.OrdinalIgnoreCase))
            {
                output.Attributes.SetAttribute("href", newUrl);
            }
            else if (context.TagName.Equals("form", StringComparison.OrdinalIgnoreCase))
            {
                output.Attributes.SetAttribute("action", newUrl);
            }
        }

        output.Attributes.RemoveAll("asp-encrypted-qs");
        output.Attributes.RemoveAll("asp-encrypted-id");
    }
}
