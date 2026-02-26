using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Controllers;

[Authorize]
public class DoctorRoomsController(IDoctorRoomService doctorRoomService, IFloorService floorService, IAuditLogService auditLogService) : Controller
{
    public async Task<IActionResult> Index()
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return RedirectToAction("Login", "Account");

        var list = await doctorRoomService.GetAllByBranchAsync(branchId.Value);
        return View(list);
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        if (User.GetCurrentBranchId() is null) return RedirectToAction("Login", "Account");
        var model = new DoctorRoomFormViewModel();
        await PopulateFloors(model);
        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(DoctorRoomFormViewModel model)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return RedirectToAction("Login", "Account");

        if (!model.FloorId.HasValue)
            ModelState.AddModelError(nameof(model.FloorId), "Floor is required.");

        var allFloors = await floorService.GetAllAsync();
        var floorExists = model.FloorId.HasValue && allFloors.Any(x => x.FloorId == model.FloorId.Value);
        if (model.FloorId.HasValue && !floorExists)
            ModelState.AddModelError(nameof(model.FloorId), "Selected floor is invalid.");

        var roomName = model.RoomName?.Trim() ?? string.Empty;
        if (model.FloorId.HasValue && await doctorRoomService.NameExistsAsync(roomName, branchId.Value, model.FloorId.Value))
            ModelState.AddModelError(nameof(model.RoomName), "This Room Name already exists for selected floor in current branch.");

        if (!ModelState.IsValid)
        {
            await PopulateFloors(model);
            return View(model);
        }

        await doctorRoomService.CreateAsync(new DoctorRoomMaster
        {
            RoomName = roomName,
            FloorId = model.FloorId!.Value,
            BranchId = branchId.Value,
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "DoctorRooms.Create", $"Created doctor room: {roomName}");
        TempData["Success"] = "Doctor Room created successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return RedirectToAction("Login", "Account");

        var entity = await doctorRoomService.GetByIdAsync(id, branchId.Value);
        if (entity is null) return NotFound();

        return View(new DoctorRoomFormViewModel
        {
            RoomId = entity.RoomId,
            RoomName = entity.RoomName,
            FloorId = entity.FloorId,
            IsActive = entity.IsActive
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(DoctorRoomFormViewModel model)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return RedirectToAction("Login", "Account");

        if (!model.FloorId.HasValue)
            ModelState.AddModelError(nameof(model.FloorId), "Floor is required.");

        var allFloors = await floorService.GetAllAsync();
        var floorExists = model.FloorId.HasValue && allFloors.Any(x => x.FloorId == model.FloorId.Value);
        if (model.FloorId.HasValue && !floorExists)
            ModelState.AddModelError(nameof(model.FloorId), "Selected floor is invalid.");

        var roomName = model.RoomName?.Trim() ?? string.Empty;
        if (model.FloorId.HasValue && await doctorRoomService.NameExistsAsync(roomName, branchId.Value, model.FloorId.Value, model.RoomId))
            ModelState.AddModelError(nameof(model.RoomName), "This Room Name already exists for selected floor in current branch.");

        if (!ModelState.IsValid)
        {
            await PopulateFloors(model);
            return View(model);
        }

        await doctorRoomService.UpdateAsync(new DoctorRoomMaster
        {
            RoomId = model.RoomId,
            RoomName = roomName,
            FloorId = model.FloorId!.Value,
            BranchId = branchId.Value,
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "DoctorRooms.Edit", $"Updated doctor room: {roomName}");
        TempData["Success"] = "Doctor Room updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return RedirectToAction("Login", "Account");

        var entity = await doctorRoomService.GetByIdAsync(id, branchId.Value);
        if (entity is null) return NotFound();
        return View(entity);
    }

    private async Task PopulateFloors(DoctorRoomFormViewModel model)
    {
        var floors = (await floorService.GetAllAsync())
            .Where(x => x.IsActive || (model.FloorId.HasValue && x.FloorId == model.FloorId.Value))
            .OrderBy(x => x.FloorName)
            .ToList();

        model.FloorOptions = floors
            .Select(x => new SelectListItem(x.FloorName, x.FloorId.ToString(), model.FloorId == x.FloorId))
            .ToList();
    }
}
