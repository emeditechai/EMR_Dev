using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class BedRoomTariffsController(
    IBedRoomTariffService tariffService,
    IAuditLogService auditLogService) : Controller
{
    public async Task<IActionResult> Index(
        int? wardId = null, int? roomId = null, 
        int? bedCategoryId = null, int? tariffCategoryId = null)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId();
        var list = await tariffService.GetAllAsync(wardId, roomId, bedCategoryId, tariffCategoryId, companyId, branchId);

        ViewBag.WardId = wardId;
        ViewBag.RoomId = roomId;
        ViewBag.BedCategoryId = bedCategoryId;
        ViewBag.TariffCategoryId = tariffCategoryId;

        ViewBag.WardOptions = await tariffService.GetWardOptionsAsync(wardId);
        ViewBag.RoomOptions = await tariffService.GetRoomOptionsAsync(wardId, roomId);
        ViewBag.BedCategoryOptions = await tariffService.GetBedCategoryOptionsAsync(bedCategoryId);
        ViewBag.TariffCategoryOptions = await tariffService.GetTariffCategoryOptionsAsync(tariffCategoryId);

        return View(list);
    }

    [HttpGet]
    public async Task<IActionResult> Create(int? wardId = null, int? roomId = null, int? bedCategoryId = null, int? tariffCategoryId = null)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        var model = new BedRoomTariffFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            BranchId = branchId,
            WardId = wardId,
            RoomId = roomId,
            BedCategoryId = bedCategoryId,
            TariffCategoryId = tariffCategoryId,
            EffectiveFrom = DateTime.Today,
            WardOptions = await tariffService.GetWardOptionsAsync(wardId),
            RoomOptions = await tariffService.GetRoomOptionsAsync(wardId, roomId),
            BedCategoryOptions = await tariffService.GetBedCategoryOptionsAsync(bedCategoryId),
            TariffCategoryOptions = await tariffService.GetTariffCategoryOptionsAsync(tariffCategoryId)
        };
        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(BedRoomTariffFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? model.BranchId;
        model.BranchId = branchId;

        // Check for overlapping effective date ranges
        if (model.WardId.HasValue && model.RoomId.HasValue && model.BedCategoryId.HasValue && model.TariffCategoryId.HasValue)
        {
            var isOverlapping = await tariffService.HasOverlappingDatesAsync(
                branchId, model.WardId.Value, model.RoomId.Value, model.BedCategoryId.Value, model.TariffCategoryId.Value,
                model.EffectiveFrom, model.EffectiveTo);

            if (isOverlapping)
            {
                ModelState.AddModelError(string.Empty, "An active tariff already exists for this Ward, Room, Bed Category, and Tariff Category during the specified effective date range (overlapping dates are not permitted).");
            }
        }

        if (!ModelState.IsValid)
        {
            model.WardOptions = await tariffService.GetWardOptionsAsync(model.WardId);
            model.RoomOptions = await tariffService.GetRoomOptionsAsync(model.WardId, model.RoomId);
            model.BedCategoryOptions = await tariffService.GetBedCategoryOptionsAsync(model.BedCategoryId);
            model.TariffCategoryOptions = await tariffService.GetTariffCategoryOptionsAsync(model.TariffCategoryId);
            return View(model);
        }

        var newId = await tariffService.CreateAsync(new BedRoomTariffMaster
        {
            CompanyId = companyId,
            BranchId = branchId,
            WardId = model.WardId!.Value,
            RoomId = model.RoomId!.Value,
            BedCategoryId = model.BedCategoryId!.Value,
            TariffCategoryId = model.TariffCategoryId!.Value,
            EffectiveFrom = model.EffectiveFrom,
            EffectiveTo = model.EffectiveTo,
            RoomCharge = model.RoomCharge,
            BedCharge = model.BedCharge,
            NursingCharge = model.NursingCharge,
            AttendantCharge = model.AttendantCharge,
            IsolationCharge = model.IsolationCharge,
            GstPercentage = model.GstPercentage,
            IsActive = model.IsActive
        }, User.GetUserId(), model.ChangeReason);

        await auditLogService.LogAsync("MasterData", "BedRoomTariffs.Create",
            $"Created Bed/Room tariff rate: RateId={newId}, Effective={model.EffectiveFrom:yyyy-MM-dd}",
            branchId: branchId);

        TempData["Success"] = "Bed/Room Tariff Rate created successfully.";
        return RedirectToAction(nameof(Details), new { id = newId });
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var entity = await tariffService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        return View(new BedRoomTariffFormViewModel
        {
            BedRateId = entity.BedRateId,
            CompanyId = entity.CompanyId,
            BranchId = entity.BranchId,
            WardId = entity.WardId,
            RoomId = entity.RoomId,
            BedCategoryId = entity.BedCategoryId,
            TariffCategoryId = entity.TariffCategoryId,
            EffectiveFrom = entity.EffectiveFrom,
            EffectiveTo = entity.EffectiveTo,
            RoomCharge = entity.RoomCharge,
            BedCharge = entity.BedCharge,
            NursingCharge = entity.NursingCharge,
            AttendantCharge = entity.AttendantCharge,
            IsolationCharge = entity.IsolationCharge,
            GstPercentage = entity.GstPercentage,
            IsActive = entity.IsActive,
            WardOptions = await tariffService.GetWardOptionsAsync(entity.WardId),
            RoomOptions = await tariffService.GetRoomOptionsAsync(entity.WardId, entity.RoomId),
            BedCategoryOptions = await tariffService.GetBedCategoryOptionsAsync(entity.BedCategoryId),
            TariffCategoryOptions = await tariffService.GetTariffCategoryOptionsAsync(entity.TariffCategoryId)
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(BedRoomTariffFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? model.BranchId;
        model.BranchId = branchId;

        // Check for overlapping effective date ranges excluding self
        if (model.WardId.HasValue && model.RoomId.HasValue && model.BedCategoryId.HasValue && model.TariffCategoryId.HasValue)
        {
            var isOverlapping = await tariffService.HasOverlappingDatesAsync(
                branchId, model.WardId.Value, model.RoomId.Value, model.BedCategoryId.Value, model.TariffCategoryId.Value,
                model.EffectiveFrom, model.EffectiveTo, excludeId: model.BedRateId);

            if (isOverlapping)
            {
                ModelState.AddModelError(string.Empty, "An active tariff already exists for this Ward, Room, Bed Category, and Tariff Category during the specified effective date range (overlapping dates are not permitted).");
            }
        }

        if (!ModelState.IsValid)
        {
            model.WardOptions = await tariffService.GetWardOptionsAsync(model.WardId);
            model.RoomOptions = await tariffService.GetRoomOptionsAsync(model.WardId, model.RoomId);
            model.BedCategoryOptions = await tariffService.GetBedCategoryOptionsAsync(model.BedCategoryId);
            model.TariffCategoryOptions = await tariffService.GetTariffCategoryOptionsAsync(model.TariffCategoryId);
            return View(model);
        }

        await tariffService.UpdateAsync(new BedRoomTariffMaster
        {
            BedRateId = model.BedRateId,
            CompanyId = companyId,
            BranchId = branchId,
            WardId = model.WardId!.Value,
            RoomId = model.RoomId!.Value,
            BedCategoryId = model.BedCategoryId!.Value,
            TariffCategoryId = model.TariffCategoryId!.Value,
            EffectiveFrom = model.EffectiveFrom,
            EffectiveTo = model.EffectiveTo,
            RoomCharge = model.RoomCharge,
            BedCharge = model.BedCharge,
            NursingCharge = model.NursingCharge,
            AttendantCharge = model.AttendantCharge,
            IsolationCharge = model.IsolationCharge,
            GstPercentage = model.GstPercentage,
            IsActive = model.IsActive
        }, User.GetUserId(), model.ChangeReason);

        await auditLogService.LogAsync("MasterData", "BedRoomTariffs.Edit",
            $"Updated Bed/Room tariff rate: RateId={model.BedRateId}, Reason: {model.ChangeReason}",
            branchId: branchId);

        TempData["Success"] = "Bed/Room Tariff Rate updated and change logged to history.";
        return RedirectToAction(nameof(Details), new { id = model.BedRateId });
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var details = await tariffService.GetDetailsByIdAsync(id);
        if (details is null) return NotFound();
        return View(details);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var deleted = await tariffService.DeleteAsync(id, User.GetUserId());
        TempData[deleted ? "Success" : "Error"] = deleted
            ? "Bed/Room Tariff deleted successfully."
            : "Cannot delete this Bed/Room Tariff.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> GetRoomsByWard(int wardId)
    {
        var rooms = await tariffService.GetRoomOptionsAsync(wardId);
        return Json(rooms);
    }
}
