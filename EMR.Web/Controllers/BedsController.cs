using Microsoft.AspNetCore.Mvc.Rendering;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class BedsController(
    IRoomService roomService,
    IBedService bedService,
    IIpdMasterApiClient ipdMasterApiClient,
    IAuditLogService auditLogService) : Controller
{
    public async Task<IActionResult> Index(
        int? buildingId = null, int? wardId = null, int? roomId = null, 
        int? bedCategoryId = null, string? bedStatus = null)
    {
        try
        {
            var companyId = User.GetCompanyId();
            var branchId = User.GetCurrentBranchId();
            var list = await ipdMasterApiClient.GetBedsAsync(buildingId, wardId, roomId, bedCategoryId, bedStatus, companyId, branchId);

            ViewBag.BuildingId = buildingId;
            ViewBag.WardId = wardId;
            ViewBag.RoomId = roomId;
            ViewBag.BedCategoryId = bedCategoryId;
            ViewBag.BedStatus = bedStatus;

            ViewBag.BuildingOptions = await bedService.GetBuildingOptionsAsync(buildingId);
            ViewBag.WardOptions = await bedService.GetWardOptionsAsync(buildingId, wardId);
            ViewBag.RoomOptions = await bedService.GetRoomOptionsAsync(wardId, roomId);
            ViewBag.BedCategoryOptions = await bedService.GetBedCategoryOptionsAsync(bedCategoryId);
            ViewBag.BedStatusOptions = bedService.GetBedStatusOptions(bedStatus);

            return View(list);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Bed Master List";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create(int? buildingId = null, int? wardId = null, int? roomId = null)
    {
        var model = new BedFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            BranchId = User.GetCurrentBranchId(),
            BuildingId = buildingId,
            WardId = wardId,
            RoomId = roomId,
            BuildingOptions = await bedService.GetBuildingOptionsAsync(buildingId),
            RoomOptions = await bedService.GetRoomOptionsAsync(wardId, roomId),
            BedCategoryOptions = await bedService.GetBedCategoryOptionsAsync(),
            BedStatusOptions = bedService.GetBedStatusOptions()
        };
        await FillFloorWardAsync(model);
        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(BedFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId();
        model.BedNumber = model.BedNumber.Trim().ToUpper();
        await CheckWardFloorAsync(model);

        if (await bedService.BedNumberExistsAsync(model.BedNumber, companyId: companyId))
            ModelState.AddModelError(nameof(model.BedNumber), "This Bed Number already exists in the company.");

        if (!ModelState.IsValid)
        {
            model.BuildingOptions = await bedService.GetBuildingOptionsAsync(model.BuildingId);
            await FillFloorWardAsync(model);
            model.RoomOptions = await bedService.GetRoomOptionsAsync(model.WardId, model.RoomId);
            model.BedCategoryOptions = await bedService.GetBedCategoryOptionsAsync(model.BedCategoryId);
            model.BedStatusOptions = bedService.GetBedStatusOptions(model.BedStatus);
            return View(model);
        }

        var newId = await bedService.CreateAsync(new BedMaster
        {
            CompanyId = companyId,
            BranchId = model.BranchId ?? branchId,
            BuildingId = model.BuildingId!.Value,
            WardId = model.WardId!.Value,
            RoomId = model.RoomId!.Value,
            BedNumber = model.BedNumber,
            BedCategoryId = model.BedCategoryId!.Value,
            BedStatus = model.BedStatus,
            IsIsolation = model.IsIsolation,
            IsICU = model.IsICU,
            IsVentilatorCapable = model.IsVentilatorCapable,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Beds.Create",
            $"Created bed: {model.BedNumber} (Status: {model.BedStatus})",
            branchId: model.BranchId);

        TempData["Success"] = "Bed created successfully.";
        return RedirectToAction(nameof(Details), new { id = newId });
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var entity = await bedService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        var editModel = new BedFormViewModel
        {
            BedId = entity.BedId,
            CompanyId = entity.CompanyId,
            BranchId = entity.BranchId,
            BuildingId = entity.BuildingId,
            WardId = entity.WardId,
            RoomId = entity.RoomId,
            BedNumber = entity.BedNumber,
            BedCategoryId = entity.BedCategoryId,
            BedStatus = entity.BedStatus,
            IsIsolation = entity.IsIsolation,
            IsICU = entity.IsICU,
            IsVentilatorCapable = entity.IsVentilatorCapable,
            Description = entity.Description,
            IsActive = entity.IsActive,
            BuildingOptions = await bedService.GetBuildingOptionsAsync(entity.BuildingId),
            RoomOptions = await bedService.GetRoomOptionsAsync(entity.WardId, entity.RoomId),
            BedCategoryOptions = await bedService.GetBedCategoryOptionsAsync(entity.BedCategoryId),
            BedStatusOptions = bedService.GetBedStatusOptions(entity.BedStatus)
        };
        await FillFloorWardAsync(editModel);
        return View(editModel);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(BedFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId();
        model.BedNumber = model.BedNumber.Trim().ToUpper();
        await CheckWardFloorAsync(model);

        if (await bedService.BedNumberExistsAsync(model.BedNumber, excludeId: model.BedId, companyId: companyId))
            ModelState.AddModelError(nameof(model.BedNumber), "This Bed Number already exists in the company.");

        if (!ModelState.IsValid)
        {
            model.BuildingOptions = await bedService.GetBuildingOptionsAsync(model.BuildingId);
            await FillFloorWardAsync(model);
            model.RoomOptions = await bedService.GetRoomOptionsAsync(model.WardId, model.RoomId);
            model.BedCategoryOptions = await bedService.GetBedCategoryOptionsAsync(model.BedCategoryId);
            model.BedStatusOptions = bedService.GetBedStatusOptions(model.BedStatus);
            return View(model);
        }

        await bedService.UpdateAsync(new BedMaster
        {
            BedId = model.BedId,
            BuildingId = model.BuildingId!.Value,
            WardId = model.WardId!.Value,
            RoomId = model.RoomId!.Value,
            BedNumber = model.BedNumber,
            BedCategoryId = model.BedCategoryId!.Value,
            BedStatus = model.BedStatus,
            IsIsolation = model.IsIsolation,
            IsICU = model.IsICU,
            IsVentilatorCapable = model.IsVentilatorCapable,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Beds.Edit",
            $"Updated bed: {model.BedNumber} (Status: {model.BedStatus})",
            branchId: model.BranchId);

        TempData["Success"] = "Bed updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var details = await bedService.GetDetailsByIdAsync(id);
        if (details is null) return NotFound();
        return View(details);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var deleted = await bedService.DeleteAsync(id);
        TempData[deleted ? "Success" : "Error"] = deleted
            ? "Bed deleted successfully."
            : "Cannot delete this Bed.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> GetWardsByBuilding(int buildingId)
    {
        var wards = await bedService.GetWardsByBuildingAsync(buildingId);
        return Json(wards);
    }

    [HttpGet]
    public async Task<IActionResult> GetRoomsByWard(int wardId)
    {
        var rooms = await bedService.GetRoomsByWardAsync(wardId);
        return Json(rooms);
    }

    /// <summary>Building -> Floor -> Ward -> Room. The bed stores its ward; the floor is the ward's floor (Master > Ward),
    /// found when an existing bed is opened. Floors and wards come from the Room master's lookups.</summary>
    private async Task FillFloorWardAsync(BedFormViewModel model)
    {
        if (model.FloorId is null && model.WardId is > 0)
        {
            try
            {
                var ward = (await ipdMasterApiClient.GetWardsAsync(companyId: User.GetCompanyId(), branchId: User.GetCurrentBranchId()))
                    .FirstOrDefault(w => w.WardId == model.WardId);
                model.FloorId = ward?.FloorId;
            }
            catch (HttpRequestException) { /* the floor stays empty; the user picks it */ }
        }
        model.FloorOptions = model.BuildingId is > 0
            ? (await roomService.GetFloorsByBuildingAsync(model.BuildingId.Value))
                .Select(f => new SelectListItem($"{f.FloorName} ({f.FloorCode})", f.FloorId.ToString(), f.FloorId == model.FloorId)).ToList()
            : new List<SelectListItem>();
        model.WardOptions = model.FloorId is > 0
            ? (await roomService.GetWardsByFloorAsync(model.FloorId.Value))
                .Select(w => new SelectListItem($"{w.WardName} ({w.WardCode}) - {w.WardType}", w.WardId.ToString(), w.WardId == model.WardId)).ToList()
            : new List<SelectListItem>();
    }

    /// <summary>The ward must be on the chosen floor.</summary>
    private async Task CheckWardFloorAsync(BedFormViewModel model)
    {
        if (model.FloorId is > 0 && model.WardId is > 0
            && !(await roomService.GetWardsByFloorAsync(model.FloorId.Value)).Any(w => w.WardId == model.WardId))
            ModelState.AddModelError(nameof(model.WardId), "The ward is not on the chosen floor.");
    }

    [HttpGet]
    public async Task<IActionResult> GetFloorsByBuilding(int buildingId) => Json(await roomService.GetFloorsByBuildingAsync(buildingId));

    [HttpGet]
    public async Task<IActionResult> GetWardsByFloor(int floorId) => Json(await roomService.GetWardsByFloorAsync(floorId));
}
