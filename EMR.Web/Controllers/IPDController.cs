using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class IPDController : Controller
{
    public IActionResult Index()
    {
        return View();
    }
}
