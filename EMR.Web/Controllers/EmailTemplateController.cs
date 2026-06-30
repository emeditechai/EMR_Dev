using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Extensions;

namespace EMR.Web.Controllers;

[Authorize(Roles = "Administrator,HO_Admin")]
public class EmailTemplateController(ApplicationDbContext dbContext) : Controller
{
    public async Task<IActionResult> Index()
    {
        var branchId = User.GetCurrentBranchId() ?? 0;
        var templates = await dbContext.EmailTemplates
            .Where(t => t.BranchId == branchId)
            .OrderBy(t => t.TemplateName)
            .ToListAsync();
            
        return View(templates);
    }

    [HttpGet]
    public IActionResult Create()
    {
        return View(new EmailTemplate());
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(EmailTemplate model)
    {
        if (!ModelState.IsValid) return View(model);

        model.BranchId = User.GetCurrentBranchId() ?? 0;
        model.CreatedBy = User.GetUserId();
        model.CreatedDate = DateTime.UtcNow;
        model.IsActive = true;

        dbContext.EmailTemplates.Add(model);
        await dbContext.SaveChangesAsync();

        TempData["SuccessMessage"] = "Email template created successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 0;
        var template = await dbContext.EmailTemplates
            .FirstOrDefaultAsync(t => t.Id == id && t.BranchId == branchId);

        if (template == null) return NotFound();

        return View(template);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, EmailTemplate model)
    {
        if (id != model.Id) return BadRequest();

        if (!ModelState.IsValid) return View(model);

        var branchId = User.GetCurrentBranchId() ?? 0;
        var existing = await dbContext.EmailTemplates
            .FirstOrDefaultAsync(t => t.Id == id && t.BranchId == branchId);

        if (existing == null) return NotFound();

        existing.TemplateName = model.TemplateName;
        existing.Subject = model.Subject;
        existing.HtmlBody = model.HtmlBody;
        existing.IsActive = model.IsActive;
        existing.ModifiedBy = User.GetUserId();
        existing.ModifiedDate = DateTime.UtcNow;

        await dbContext.SaveChangesAsync();

        TempData["SuccessMessage"] = "Email template updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 0;
        var template = await dbContext.EmailTemplates
            .FirstOrDefaultAsync(t => t.Id == id && t.BranchId == branchId);

        if (template != null)
        {
            dbContext.EmailTemplates.Remove(template);
            await dbContext.SaveChangesAsync();
            TempData["SuccessMessage"] = "Template deleted successfully.";
        }
        else
        {
            TempData["ErrorMessage"] = "Template not found.";
        }

        return RedirectToAction(nameof(Index));
    }
}
