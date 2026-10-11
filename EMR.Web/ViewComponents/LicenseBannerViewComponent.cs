using EMR.Web.Services.Licensing;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.ViewComponents;

/// <summary>
/// Licence messages at the top of the Home Dashboard only (Dashboard/Index): the vendor's broadcast alert (inside its
/// window), "licence expires in N days", the AMC end, and the offline-grace warning. Other pages show nothing.
/// </summary>
public sealed class LicenseBannerViewComponent(ILicensingService licensing) : ViewComponent
{
    public async Task<IViewComponentResult> InvokeAsync()
    {
        if (!licensing.Enabled || User.Identity?.IsAuthenticated != true || !OnHomeDashboard()) return Content(string.Empty);
        var banners = await licensing.GetBannersAsync(HttpContext);
        return banners.Count == 0 ? Content(string.Empty) : View(banners);
    }

    private bool OnHomeDashboard()
    {
        var route = ViewContext.RouteData.Values;
        return string.Equals(route["controller"] as string, "Dashboard", StringComparison.OrdinalIgnoreCase)
            && string.Equals(route["action"] as string, "Index", StringComparison.OrdinalIgnoreCase);
    }
}
