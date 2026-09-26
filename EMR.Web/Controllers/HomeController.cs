using EMR.Web.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

public class HomeController(IQueryStringEncryptionService encryptionService) : Controller
{
    [HttpPost]
    public IActionResult EncryptQs([FromBody] Dictionary<string, string> parameters)
    {
        if (parameters == null || parameters.Count == 0)
            return BadRequest();
        var token = encryptionService.EncryptParameters(parameters!);
        return Json(new { q = token });
    }

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
