using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class BuildingsController(
    IBuildingService buildingService, 
    IAuditLogService auditLogService) : Controller
{
    public async Task<IActionResult> Index()
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId();
        var list = await buildingService.GetAllAsync(companyId, branchId);
        return View(list);
    }

    [HttpGet]
    public IActionResult Create() => View(new BuildingFormViewModel
    {
        CompanyId = User.GetCompanyId(),
        BranchId = User.GetCurrentBranchId()
    });

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(BuildingFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        model.BuildingCode = model.BuildingCode.Trim().ToUpper();

        if (model.BuildingCode.Length != 4)
        {
            ModelState.AddModelError(nameof(model.BuildingCode), "Building Code must be exactly 4 characters (e.g. BLD1, MAIN).");
        }

        if (await buildingService.CodeExistsAsync(model.BuildingCode, companyId: companyId))
        {
            ModelState.AddModelError(nameof(model.BuildingCode), "A Building with this 4-digit code already exists.");
        }

        if (!ModelState.IsValid) return View(model);

        var entity = new BuildingMaster
        {
            CompanyId = companyId,
            BranchId = model.BranchId ?? User.GetCurrentBranchId(),

            BuildingCode = model.BuildingCode,
            BuildingName = model.BuildingName.Trim(),
            Description = model.Description?.Trim(),
            NumberOfFloors = model.NumberOfFloors,
            IsActive = model.IsActive
        };

        var newId = await buildingService.CreateAsync(entity, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Buildings.Create",
            $"Created building: {entity.BuildingCode} - {entity.BuildingName}",
            branchId: entity.BranchId);

        TempData["Success"] = "Building created successfully.";
        return RedirectToAction(nameof(Details), new { id = newId });
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var entity = await buildingService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        return View(new BuildingFormViewModel
        {
            BuildingId = entity.BuildingId,
            CompanyId = entity.CompanyId,
            BranchId = entity.BranchId,
            BuildingCode = entity.BuildingCode,
            BuildingName = entity.BuildingName,
            Description = entity.Description,
            NumberOfFloors = entity.NumberOfFloors,
            IsActive = entity.IsActive
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(BuildingFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        model.BuildingCode = model.BuildingCode.Trim().ToUpper();

        if (model.BuildingCode.Length != 4)
        {
            ModelState.AddModelError(nameof(model.BuildingCode), "Building Code must be exactly 4 characters (e.g. BLD1, MAIN).");
        }

        if (await buildingService.CodeExistsAsync(model.BuildingCode, excludeId: model.BuildingId, companyId: companyId))
        {
            ModelState.AddModelError(nameof(model.BuildingCode), "A Building with this 4-digit code already exists.");
        }

        if (!ModelState.IsValid) return View(model);

        var entity = new BuildingMaster
        {
            BuildingId = model.BuildingId,
            CompanyId = companyId,
            BranchId = model.BranchId,
            BuildingCode = model.BuildingCode,
            BuildingName = model.BuildingName.Trim(),
            Description = model.Description?.Trim(),
            NumberOfFloors = model.NumberOfFloors,
            IsActive = model.IsActive
        };

        await buildingService.UpdateAsync(entity, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Buildings.Edit",
            $"Updated building: {entity.BuildingCode} - {entity.BuildingName}",
            branchId: entity.BranchId);

        TempData["Success"] = "Building updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var details = await buildingService.GetDetailsByIdAsync(id);
        if (details is null) return NotFound();

        return View(details);
    }
}
