using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class NursingStationsController(
    INursingStationService nursingStationService,
    IIpdMasterApiClient ipdMasterApiClient,
    IAuditLogService auditLogService) : Controller
{
    public async Task<IActionResult> Index(int? wardId = null)
    {
        try
        {
            var companyId = User.GetCompanyId();
            var branchId = User.GetCurrentBranchId();
            var list = await ipdMasterApiClient.GetNursingStationsAsync(wardId, companyId, branchId);

            ViewBag.WardId = wardId;
            ViewBag.WardOptions = await nursingStationService.GetWardOptionsAsync(wardId);

            return View(list);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Nursing Station Master List";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create(int? wardId = null)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId();
        var model = new NursingStationFormViewModel
        {
            CompanyId = companyId,
            BranchId = branchId,
            WardId = wardId,
            WardOptions = await nursingStationService.GetWardOptionsAsync(wardId),
            NurseOptions = await nursingStationService.GetNurseOptionsAsync(companyId, branchId)
        };
        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(NursingStationFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId();
        model.StationCode = model.StationCode.Trim().ToUpper();
        model.StationName = model.StationName.Trim();

        if (await nursingStationService.CodeExistsAsync(model.StationCode, companyId: companyId))
            ModelState.AddModelError(nameof(model.StationCode), "This Nursing Station Code already exists.");

        if (!ModelState.IsValid)
        {
            model.WardOptions = await nursingStationService.GetWardOptionsAsync(model.WardId);
            model.NurseOptions = await nursingStationService.GetNurseOptionsAsync(companyId, branchId, model.ResponsibleNurse);
            return View(model);
        }

        var newId = await nursingStationService.CreateAsync(new NursingStationMaster
        {
            CompanyId = companyId,
            BranchId = model.BranchId ?? branchId,
            WardId = model.WardId!.Value,
            StationCode = model.StationCode,
            StationName = model.StationName,
            ResponsibleNurse = model.ResponsibleNurse?.Trim(),
            Description = model.Description?.Trim(),
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "NursingStations.Create",
            $"Created nursing station: {model.StationName} ({model.StationCode})",
            branchId: model.BranchId);

        TempData["Success"] = "Nursing Station created successfully.";
        return RedirectToAction(nameof(Index), new { wardId = model.WardId });
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var entity = await nursingStationService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        var companyId = entity.CompanyId;
        var branchId = entity.BranchId;

        return View(new NursingStationFormViewModel
        {
            NursingStationId = entity.NursingStationId,
            CompanyId = entity.CompanyId,
            BranchId = entity.BranchId,
            WardId = entity.WardId,
            StationCode = entity.StationCode,
            StationName = entity.StationName,
            ResponsibleNurse = entity.ResponsibleNurse,
            Description = entity.Description,
            IsActive = entity.IsActive,
            WardOptions = await nursingStationService.GetWardOptionsAsync(entity.WardId),
            NurseOptions = await nursingStationService.GetNurseOptionsAsync(companyId, branchId, entity.ResponsibleNurse)
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(NursingStationFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId();
        model.StationCode = model.StationCode.Trim().ToUpper();
        model.StationName = model.StationName.Trim();

        if (await nursingStationService.CodeExistsAsync(model.StationCode, excludeId: model.NursingStationId, companyId: companyId))
            ModelState.AddModelError(nameof(model.StationCode), "This Nursing Station Code already exists.");

        if (!ModelState.IsValid)
        {
            model.WardOptions = await nursingStationService.GetWardOptionsAsync(model.WardId);
            model.NurseOptions = await nursingStationService.GetNurseOptionsAsync(companyId, branchId, model.ResponsibleNurse);
            return View(model);
        }

        await nursingStationService.UpdateAsync(new NursingStationMaster
        {
            NursingStationId = model.NursingStationId,
            WardId = model.WardId!.Value,
            StationCode = model.StationCode,
            StationName = model.StationName,
            ResponsibleNurse = model.ResponsibleNurse?.Trim(),
            Description = model.Description?.Trim(),
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "NursingStations.Edit",
            $"Updated nursing station: {model.StationName} ({model.StationCode})",
            branchId: model.BranchId);

        TempData["Success"] = "Nursing Station updated successfully.";
        return RedirectToAction(nameof(Index), new { wardId = model.WardId });
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var details = await nursingStationService.GetDetailsByIdAsync(id);
        if (details is null) return NotFound();
        return View(details);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var deleted = await nursingStationService.DeleteAsync(id);
        TempData[deleted ? "Success" : "Error"] = deleted
            ? "Nursing Station deleted successfully."
            : "Cannot delete this Nursing Station.";
        return RedirectToAction(nameof(Index));
    }
}
