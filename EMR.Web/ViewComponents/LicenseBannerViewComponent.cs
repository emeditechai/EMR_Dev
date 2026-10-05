using EMR.Web.Services.Licensing;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.ViewComponents;

/// <summary>
/// Licence messages at the top of every page: the vendor's broadcast alert (inside its window), "licence expires in
/// N days", the AMC end, and the offline-grace warning. Nothing while licensing is switched off.
/// </summary>
public sealed class LicenseBannerViewComponent(ILicensingService licensing) : ViewComponent
{
    public async Task<IViewComponentResult> InvokeAsync()
    {
        if (!licensing.Enabled || User.Identity?.IsAuthenticated != true) return Content(string.Empty);
        var banners = await licensing.GetBannersAsync(HttpContext);
        return banners.Count == 0 ? Content(string.Empty) : View(banners);
    }
}
