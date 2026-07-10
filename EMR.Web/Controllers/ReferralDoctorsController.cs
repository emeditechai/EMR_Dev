using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class ReferralDoctorsController(ApplicationDbContext dbContext, IAuditLogService auditLogService) : Controller
{
    private static readonly List<string> Salutations = ["Dr", "Prof", "Mr", "Ms", "Other"];

    public async Task<IActionResult> Index()
    {
        var list = await dbContext.ReferralDoctorMasters
            .OrderByDescending(x => x.CreatedDate)
            .ToListAsync();
        return View(list);
    }

    [HttpGet]
    public IActionResult Create()
    {
        ViewBag.Salutations = Salutations;
        return View(new ReferralDoctorMaster());
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(ReferralDoctorMaster model)
    {
        if (!ModelState.IsValid)
        {
            ViewBag.Salutations = Salutations;
            return View(model);
        }

        // Additional validation for phone numeric check is handled via regex in view or here
        if (!string.IsNullOrWhiteSpace(model.PhoneNumber) && !model.PhoneNumber.All(char.IsDigit))
        {
            ModelState.AddModelError("PhoneNumber", "Phone Number must be numeric.");
            ViewBag.Salutations = Salutations;
            return View(model);
        }

        model.DoctorName = model.DoctorName.Trim();
        model.EmailId = model.EmailId?.Trim();
        model.PhoneNumber = model.PhoneNumber?.Trim();
        model.RegistrationNumber = model.RegistrationNumber?.Trim();
        
        model.CreatedBy = User.GetUserId();
        model.CreatedDate = DateTime.Now;
        model.IsActive = true;

        dbContext.ReferralDoctorMasters.Add(model);
        await dbContext.SaveChangesAsync();

        await auditLogService.LogAsync("MasterData", "ReferralDoctor.Create", $"Created referral doctor: {model.DoctorName}");
        TempData["Success"] = "Referral Doctor created successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var entity = await dbContext.ReferralDoctorMasters.FindAsync(id);
        if (entity is null) return NotFound();

        ViewBag.Salutations = Salutations;
        return View(entity);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(ReferralDoctorMaster model)
    {
        if (!ModelState.IsValid)
        {
            ViewBag.Salutations = Salutations;
            return View(model);
        }

        if (!string.IsNullOrWhiteSpace(model.PhoneNumber) && !model.PhoneNumber.All(char.IsDigit))
        {
            ModelState.AddModelError("PhoneNumber", "Phone Number must be numeric.");
            ViewBag.Salutations = Salutations;
            return View(model);
        }

        var entity = await dbContext.ReferralDoctorMasters.FindAsync(model.ReferralDoctorId);
        if (entity is null) return NotFound();

        entity.Salutation = model.Salutation;
        entity.DoctorName = model.DoctorName.Trim();
        entity.PhoneNumber = model.PhoneNumber?.Trim();
        entity.EmailId = model.EmailId?.Trim();
        entity.RegistrationNumber = model.RegistrationNumber?.Trim();
        entity.IsActive = model.IsActive;

        entity.ModifiedBy = User.GetUserId();
        entity.ModifiedDate = DateTime.Now;

        await dbContext.SaveChangesAsync();

        await auditLogService.LogAsync("MasterData", "ReferralDoctor.Edit", $"Updated referral doctor: {model.DoctorName}");
        TempData["Success"] = "Referral Doctor updated successfully.";
        return RedirectToAction(nameof(Index));
    }
}
