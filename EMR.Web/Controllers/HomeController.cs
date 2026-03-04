using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

public class HomeController : Controller
{
    public IActionResult Index()
    {
        if (User.Identity?.IsAuthenticated == true)
        {
            return RedirectToAction("Index", "Dashboard");
        }

        return RedirectToAction("Login", "Account");
    }

    /// <summary>Shown when EMR.Api is unreachable.</summary>
    [Route("api-unavailable")]
    public IActionResult ApiUnavailable(string? returnUrl)
    {
        ViewData["ReturnUrl"] = returnUrl ?? Request.Headers["Referer"].ToString();
        return View();
    }
}
