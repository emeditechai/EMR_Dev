using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class RoomsController(
    IRoomService roomService,
    IIpdMasterApiClient ipdMasterApiClient,
    IAuditLogService auditLogService) : Controller
{
    public async Task<IActionResult> Index(
        int? buildingId = null, int? floorId = null, int? wardId = null, 
        string? roomCategory = null, string? roomType = null)
    {
        try
        {
            var companyId = User.GetCompanyId();
            var branchId = User.GetCurrentBranchId();
            var list = await ipdMasterApiClient.GetRoomsAsync(buildingId, floorId, wardId, roomCategory, roomType, companyId, branchId);

            ViewBag.BuildingId = buildingId;
            ViewBag.FloorId = floorId;
            ViewBag.WardId = wardId;
            ViewBag.RoomCategory = roomCategory;
            ViewBag.RoomType = roomType;

            ViewBag.BuildingOptions = await roomService.GetBuildingOptionsAsync(buildingId);
            ViewBag.FloorOptions = await roomService.GetFloorOptionsAsync(buildingId, floorId);
            ViewBag.WardOptions = await roomService.GetWardOptionsAsync(floorId, wardId);
            ViewBag.RoomCategoryOptions = roomService.GetRoomCategoryOptions(roomCategory);
            ViewBag.RoomTypeOptions = roomService.GetRoomTypeOptions(roomType);

            return View(list);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "IPD Room Master List";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create(int? buildingId = null, int? floorId = null, int? wardId = null)
    {
        var model = new RoomFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            BranchId = User.GetCurrentBranchId(),
            BuildingId = buildingId,
            FloorId = floorId,
            WardId = wardId,
            BuildingOptions = await roomService.GetBuildingOptionsAsync(buildingId),
            FloorOptions = await roomService.GetFloorOptionsAsync(buildingId, floorId),
            WardOptions = await roomService.GetWardOptionsAsync(floorId, wardId),
            RoomTypeOptions = roomService.GetRoomTypeOptions(),
            RoomCategoryOptions = roomService.GetRoomCategoryOptions()
        };
        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(RoomFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId();
        model.RoomNumber = model.RoomNumber.Trim().ToUpper();

        if (await roomService.RoomNumberExistsAsync(model.RoomNumber, companyId: companyId))
            ModelState.AddModelError(nameof(model.RoomNumber), "This Room Number already exists in the company.");

        if (!ModelState.IsValid)
        {
            model.BuildingOptions = await roomService.GetBuildingOptionsAsync(model.BuildingId);
            model.FloorOptions = await roomService.GetFloorOptionsAsync(model.BuildingId, model.FloorId);
            model.WardOptions = await roomService.GetWardOptionsAsync(model.FloorId, model.WardId);
            model.RoomTypeOptions = roomService.GetRoomTypeOptions(model.RoomType);
            model.RoomCategoryOptions = roomService.GetRoomCategoryOptions(model.RoomCategory);
            return View(model);
        }

        var newId = await roomService.CreateAsync(new RoomMaster
        {
            CompanyId = companyId,
            BranchId = model.BranchId ?? branchId,
            BuildingId = model.BuildingId!.Value,
            FloorId = model.FloorId!.Value,
            WardId = model.WardId!.Value,
            RoomNumber = model.RoomNumber,
            RoomType = model.RoomType,
            RoomCategory = model.RoomCategory,
            IsIsolation = model.IsIsolation,
            BedCapacity = model.BedCapacity,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Rooms.Create",
            $"Created room: {model.RoomNumber} ({model.RoomType})",
            branchId: model.BranchId);

        TempData["Success"] = "Room created successfully.";
        return RedirectToAction(nameof(Details), new { id = newId });
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var entity = await roomService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        return View(new RoomFormViewModel
        {
            RoomId = entity.RoomId,
            CompanyId = entity.CompanyId,
            BranchId = entity.BranchId,
            BuildingId = entity.BuildingId,
            FloorId = entity.FloorId,
            WardId = entity.WardId,
            RoomNumber = entity.RoomNumber,
            RoomType = entity.RoomType,
            RoomCategory = entity.RoomCategory,
            IsIsolation = entity.IsIsolation,
            BedCapacity = entity.BedCapacity,
            Description = entity.Description,
            IsActive = entity.IsActive,
            BuildingOptions = await roomService.GetBuildingOptionsAsync(entity.BuildingId),
            FloorOptions = await roomService.GetFloorOptionsAsync(entity.BuildingId, entity.FloorId),
            WardOptions = await roomService.GetWardOptionsAsync(entity.FloorId, entity.WardId),
            RoomTypeOptions = roomService.GetRoomTypeOptions(entity.RoomType),
            RoomCategoryOptions = roomService.GetRoomCategoryOptions(entity.RoomCategory)
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(RoomFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId();
        model.RoomNumber = model.RoomNumber.Trim().ToUpper();

        if (await roomService.RoomNumberExistsAsync(model.RoomNumber, excludeId: model.RoomId, companyId: companyId))
            ModelState.AddModelError(nameof(model.RoomNumber), "This Room Number already exists in the company.");

        if (!ModelState.IsValid)
        {
            model.BuildingOptions = await roomService.GetBuildingOptionsAsync(model.BuildingId);
            model.FloorOptions = await roomService.GetFloorOptionsAsync(model.BuildingId, model.FloorId);
            model.WardOptions = await roomService.GetWardOptionsAsync(model.FloorId, model.WardId);
            model.RoomTypeOptions = roomService.GetRoomTypeOptions(model.RoomType);
            model.RoomCategoryOptions = roomService.GetRoomCategoryOptions(model.RoomCategory);
            return View(model);
        }

        await roomService.UpdateAsync(new RoomMaster
        {
            RoomId = model.RoomId,
            BuildingId = model.BuildingId!.Value,
            FloorId = model.FloorId!.Value,
            WardId = model.WardId!.Value,
            RoomNumber = model.RoomNumber,
            RoomType = model.RoomType,
            RoomCategory = model.RoomCategory,
            IsIsolation = model.IsIsolation,
            BedCapacity = model.BedCapacity,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Rooms.Edit",
            $"Updated room: {model.RoomNumber} ({model.RoomType})",
            branchId: model.BranchId);

        TempData["Success"] = "Room updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var details = await roomService.GetDetailsByIdAsync(id);
        if (details is null) return NotFound();
        return View(details);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var deleted = await roomService.DeleteAsync(id);
        TempData[deleted ? "Success" : "Error"] = deleted
            ? "Room deleted successfully."
            : "Cannot delete this Room.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> GetFloorsByBuilding(int buildingId)
    {
        var floors = await roomService.GetFloorsByBuildingAsync(buildingId);
        return Json(floors);
    }

    [HttpGet]
    public async Task<IActionResult> GetWardsByFloor(int floorId)
    {
        var wards = await roomService.GetWardsByFloorAsync(floorId);
        return Json(wards);
    }
}
