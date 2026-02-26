using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class FloorsController(IFloorService floorService, IAuditLogService auditLogService) : Controller
{
    public async Task<IActionResult> Index()
    {
        var list = await floorService.GetAllAsync();
        return View(list);
    }

    [HttpGet]
    public IActionResult Create() => View(new FloorFormViewModel());

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(FloorFormViewModel model)
    {
        if (await floorService.CodeExistsAsync(model.FloorCode.Trim().ToUpper()))
            ModelState.AddModelError(nameof(model.FloorCode), "This Floor Code already exists.");

        if (!ModelState.IsValid) return View(model);

        await floorService.CreateAsync(new FloorMaster
        {
            FloorCode = model.FloorCode.Trim().ToUpper(),
            FloorName = model.FloorName.Trim(),
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Floors.Create", $"Created floor: {model.FloorCode.Trim().ToUpper()} - {model.FloorName.Trim()}");
        TempData["Success"] = "Floor created successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var entity = await floorService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        return View(new FloorFormViewModel
        {
            FloorId = entity.FloorId,
            FloorCode = entity.FloorCode,
            FloorName = entity.FloorName,
            IsActive = entity.IsActive
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(FloorFormViewModel model)
    {
        if (await floorService.CodeExistsAsync(model.FloorCode.Trim().ToUpper(), model.FloorId))
            ModelState.AddModelError(nameof(model.FloorCode), "This Floor Code already exists.");

        if (!ModelState.IsValid) return View(model);

        await floorService.UpdateAsync(new FloorMaster
        {
            FloorId = model.FloorId,
            FloorCode = model.FloorCode.Trim().ToUpper(),
            FloorName = model.FloorName.Trim(),
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Floors.Edit", $"Updated floor: {model.FloorCode.Trim().ToUpper()} - {model.FloorName.Trim()}");
        TempData["Success"] = "Floor updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var entity = await floorService.GetByIdAsync(id);
        if (entity is null) return NotFound();
        return View(entity);
    }
}
