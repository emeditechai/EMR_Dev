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

    public IActionResult PatientRegistration()
    {
        ViewData["Title"] = "Patient Registration";
        return View();
    }

    public IActionResult ServiceBooking()
    {
        ViewData["Title"] = "Service Booking";
        return View();
    }
}
