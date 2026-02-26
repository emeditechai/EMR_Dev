using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class OPDController : Controller
{
    public IActionResult Index()
    {
        return View();
    }
}
