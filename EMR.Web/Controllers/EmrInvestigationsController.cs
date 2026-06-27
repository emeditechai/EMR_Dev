using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class EmrInvestigationsController(ApplicationDbContext db, IAuditLogService auditLog) : Controller
{
    // ── LIST ──────────────────────────────────────────────
    public async Task<IActionResult> Index(string? search)
    {
        var query = db.EmrInvestigationMasters.AsNoTracking();

        if (!string.IsNullOrWhiteSpace(search))
            query = query.Where(x => x.InvestigationName.Contains(search) || (x.Category != null && x.Category.Contains(search)));

        var list = await query.OrderBy(x => x.Category).ThenBy(x => x.InvestigationName).ToListAsync();
        ViewBag.Search = search;
        return View(list);
    }

    // ── JSON AUTO-SUGGEST ENDPOINT ────────────────────────
    [HttpGet]
    public async Task<IActionResult> Search(string? q)
    {
        var items = await db.EmrInvestigationMasters
            .AsNoTracking()
            .Where(x => x.IsActive && (string.IsNullOrEmpty(q) || x.InvestigationName.Contains(q) || (x.Category != null && x.Category.Contains(q))))
            .OrderBy(x => x.InvestigationName)
            .Take(20)
            .Select(x => new
            {
                id = x.InvestigationId,
                text = x.InvestigationName,
                category = x.Category ?? "",
                unit = x.Unit ?? ""
            })
            .ToListAsync();

        return Json(items);
    }

    // ── CREATE ────────────────────────────────────────────
    [HttpGet]
    public IActionResult Create() => View(new EmrInvestigationMaster());

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(EmrInvestigationMaster model)
    {
        if (!ModelState.IsValid) return View(model);

        // Duplicate check
        if (await db.EmrInvestigationMasters.AnyAsync(x => x.InvestigationName == model.InvestigationName.Trim()))
        {
            ModelState.AddModelError(nameof(model.InvestigationName), "An investigation with this name already exists.");
            return View(model);
        }

        var userId = GetUserId();
        model.InvestigationName = model.InvestigationName.Trim();
        model.CreatedBy = userId;
        model.CreatedDate = DateTime.Now;
        model.IsActive = true;

        db.EmrInvestigationMasters.Add(model);
        await db.SaveChangesAsync();

        await auditLog.LogAsync("Create", "EmrInvestigations", $"Created investigation: {model.InvestigationName}");
        TempData["Success"] = $"Investigation '{model.InvestigationName}' created successfully.";
        return RedirectToAction(nameof(Index));
    }

    // ── EDIT ──────────────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var item = await db.EmrInvestigationMasters.FindAsync(id);
        if (item is null) return NotFound();
        return View(item);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(EmrInvestigationMaster model)
    {
        if (!ModelState.IsValid) return View(model);

        var item = await db.EmrInvestigationMasters.FindAsync(model.InvestigationId);
        if (item is null) return NotFound();

        // Duplicate name check (exclude self)
        if (await db.EmrInvestigationMasters.AnyAsync(x => x.InvestigationName == model.InvestigationName.Trim() && x.InvestigationId != model.InvestigationId))
        {
            ModelState.AddModelError(nameof(model.InvestigationName), "An investigation with this name already exists.");
            return View(model);
        }

        item.InvestigationName = model.InvestigationName.Trim();
        item.Category = model.Category?.Trim();
        item.Unit = model.Unit?.Trim();
        item.NormalRange = model.NormalRange?.Trim();
        item.Description = model.Description?.Trim();
        item.IsActive = model.IsActive;
        item.ModifiedBy = GetUserId();
        item.ModifiedDate = DateTime.Now;

        await db.SaveChangesAsync();
        await auditLog.LogAsync("Edit", "EmrInvestigations", $"Updated investigation: {item.InvestigationName}");
        TempData["Success"] = $"Investigation '{item.InvestigationName}' updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    // ── TOGGLE ACTIVE ─────────────────────────────────────
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleActive(int id)
    {
        var item = await db.EmrInvestigationMasters.FindAsync(id);
        if (item is null) return Json(new { success = false });

        item.IsActive = !item.IsActive;
        item.ModifiedDate = DateTime.Now;
        item.ModifiedBy = GetUserId();
        await db.SaveChangesAsync();

        return Json(new { success = true, isActive = item.IsActive });
    }

    private int GetUserId()
    {
        var claim = User.FindFirst(System.Security.Claims.ClaimTypes.NameIdentifier);
        return claim != null ? int.Parse(claim.Value) : 0;
    }
}
