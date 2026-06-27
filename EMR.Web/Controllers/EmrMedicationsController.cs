using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class EmrMedicationsController(ApplicationDbContext db, IAuditLogService auditLog) : Controller
{
    // ── LIST ──────────────────────────────────────────────
    public async Task<IActionResult> Index(string? search)
    {
        var query = db.EmrMedicationMasters.AsNoTracking();

        if (!string.IsNullOrWhiteSpace(search))
            query = query.Where(x => x.MedicationName.Contains(search) || (x.GenericName != null && x.GenericName.Contains(search)) || (x.Category != null && x.Category.Contains(search)));

        var list = await query.OrderBy(x => x.Category).ThenBy(x => x.MedicationName).ToListAsync();
        ViewBag.Search = search;
        return View(list);
    }

    // ── JSON AUTO-SUGGEST ENDPOINT ────────────────────────
    [HttpGet]
    public async Task<IActionResult> Search(string? q)
    {
        var items = await db.EmrMedicationMasters
            .AsNoTracking()
            .Where(x => x.IsActive && (string.IsNullOrEmpty(q) || x.MedicationName.Contains(q) || (x.GenericName != null && x.GenericName.Contains(q))))
            .OrderBy(x => x.MedicationName)
            .Take(20)
            .Select(x => new
            {
                id = x.MedicationId,
                text = x.MedicationName,
                genericName = x.GenericName ?? "",
                category = x.Category ?? "",
                strength = x.Strength ?? "",
                unit = x.Unit ?? "",
                route = x.RouteOfAdministration ?? ""
            })
            .ToListAsync();

        return Json(items);
    }

    // ── CREATE ────────────────────────────────────────────
    [HttpGet]
    public IActionResult Create() => View(new EmrMedicationMaster());

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(EmrMedicationMaster model)
    {
        if (!ModelState.IsValid) return View(model);

        if (await db.EmrMedicationMasters.AnyAsync(x => x.MedicationName == model.MedicationName.Trim()))
        {
            ModelState.AddModelError(nameof(model.MedicationName), "A medication with this name already exists.");
            return View(model);
        }

        var userId = GetUserId();
        model.MedicationName = model.MedicationName.Trim();
        model.CreatedBy = userId;
        model.CreatedDate = DateTime.Now;
        model.IsActive = true;

        db.EmrMedicationMasters.Add(model);
        await db.SaveChangesAsync();

        await auditLog.LogAsync("Create", "EmrMedications", $"Created medication: {model.MedicationName}");
        TempData["Success"] = $"Medication '{model.MedicationName}' created successfully.";
        return RedirectToAction(nameof(Index));
    }

    // ── EDIT ──────────────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var item = await db.EmrMedicationMasters.FindAsync(id);
        if (item is null) return NotFound();
        return View(item);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(EmrMedicationMaster model)
    {
        if (!ModelState.IsValid) return View(model);

        var item = await db.EmrMedicationMasters.FindAsync(model.MedicationId);
        if (item is null) return NotFound();

        if (await db.EmrMedicationMasters.AnyAsync(x => x.MedicationName == model.MedicationName.Trim() && x.MedicationId != model.MedicationId))
        {
            ModelState.AddModelError(nameof(model.MedicationName), "A medication with this name already exists.");
            return View(model);
        }

        item.MedicationName = model.MedicationName.Trim();
        item.GenericName = model.GenericName?.Trim();
        item.Category = model.Category?.Trim();
        item.Strength = model.Strength?.Trim();
        item.Unit = model.Unit?.Trim();
        item.RouteOfAdministration = model.RouteOfAdministration?.Trim();
        item.IsActive = model.IsActive;
        item.ModifiedBy = GetUserId();
        item.ModifiedDate = DateTime.Now;

        await db.SaveChangesAsync();
        await auditLog.LogAsync("Edit", "EmrMedications", $"Updated medication: {item.MedicationName}");
        TempData["Success"] = $"Medication '{item.MedicationName}' updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    // ── TOGGLE ACTIVE ─────────────────────────────────────
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleActive(int id)
    {
        var item = await db.EmrMedicationMasters.FindAsync(id);
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
