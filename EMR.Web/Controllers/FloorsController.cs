using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class FloorsController(
    IFloorService floorService, 
    IBuildingService buildingService, 
    IAuditLogService auditLogService) : Controller
{
    public async Task<IActionResult> Index(int? buildingId = null)
    {
        var list = await floorService.GetAllAsync(buildingId);
        ViewBag.BuildingId = buildingId;
        ViewBag.BuildingOptions = await buildingService.GetBuildingOptionsAsync(User.GetCompanyId(), buildingId);
        return View(list);
    }

    [HttpGet]
    public async Task<IActionResult> Create(int? buildingId = null)
    {
        var model = new FloorFormViewModel
        {
            BuildingId = buildingId,
            BuildingOptions = await buildingService.GetBuildingOptionsAsync(User.GetCompanyId(), buildingId)
        };
        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(FloorFormViewModel model)
    {
        model.FloorCode = model.FloorCode.Trim().ToUpper();

        if (await floorService.CodeExistsAsync(model.FloorCode, model.BuildingId))
            ModelState.AddModelError(nameof(model.FloorCode), "This Floor Code already exists in the selected Building.");

        if (!ModelState.IsValid)
        {
            model.BuildingOptions = await buildingService.GetBuildingOptionsAsync(User.GetCompanyId(), model.BuildingId);
            return View(model);
        }

        var newId = await floorService.CreateAsync(new FloorMaster
        {
            BuildingId = model.BuildingId,
            FloorCode = model.FloorCode,
            FloorName = model.FloorName.Trim(),
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Floors.Create", $"Created floor: {model.FloorCode} - {model.FloorName.Trim()} for Building ID {model.BuildingId}");
        TempData["Success"] = "Floor created successfully.";
        return RedirectToAction(nameof(Index), new { buildingId = model.BuildingId });
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var entity = await floorService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        return View(new FloorFormViewModel
        {
            FloorId = entity.FloorId,
            BuildingId = entity.BuildingId,
            BuildingName = entity.BuildingName,
            FloorCode = entity.FloorCode,
            FloorName = entity.FloorName,
            IsActive = entity.IsActive,
            BuildingOptions = await buildingService.GetBuildingOptionsAsync(User.GetCompanyId(), entity.BuildingId)
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(FloorFormViewModel model)
    {
        model.FloorCode = model.FloorCode.Trim().ToUpper();

        if (await floorService.CodeExistsAsync(model.FloorCode, model.BuildingId, model.FloorId))
            ModelState.AddModelError(nameof(model.FloorCode), "This Floor Code already exists in the selected Building.");

        if (!ModelState.IsValid)
        {
            model.BuildingOptions = await buildingService.GetBuildingOptionsAsync(User.GetCompanyId(), model.BuildingId);
            return View(model);
        }

        await floorService.UpdateAsync(new FloorMaster
        {
            FloorId = model.FloorId,
            BuildingId = model.BuildingId,
            FloorCode = model.FloorCode,
            FloorName = model.FloorName.Trim(),
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Floors.Edit", $"Updated floor: {model.FloorCode} - {model.FloorName.Trim()}");
        TempData["Success"] = "Floor updated successfully.";
        return RedirectToAction(nameof(Index), new { buildingId = model.BuildingId });
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var entity = await floorService.GetByIdAsync(id);
        if (entity is null) return NotFound();
        return View(entity);
    }
}
