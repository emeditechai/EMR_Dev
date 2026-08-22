using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class HousekeepingController(
    IHousekeepingApiClient hkApiClient,
    IShiftMasterApiClient shiftApiClient,
    ApplicationDbContext dbContext,
    IAuditLogService auditLogService) : Controller
{
    private static readonly List<string> LocationTypes =
    [
        "Ward",
        "Room",
        "Toilet",
        "ICU",
        "OT",
        "OPD",
        "Public Area"
    ];

    private static readonly List<string> RiskLevels =
    [
        "High Risk",
        "Moderate Risk",
        "Low Risk"
    ];

    private static readonly List<string> Frequencies =
    [
        "Every 2 Hours",
        "Every 4 Hours",
        "Twice Daily",
        "Once Daily",
        "Thrice Daily",
        "On Patient Discharge",
        "On Incident Spill",
        "Weekly",
        "Monthly"
    ];

    [HttpGet]
    public async Task<IActionResult> Index(
        string? tab = "locations",
        string? locationType = null,
        string? cleaningType = null,
        int? shiftId = null,
        int? locationId = null,
        bool? status = null,
        string? search = null)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        try
        {
            // Load all 3 modules concurrently
            var locationsTask = hkApiClient.GetLocationsAsync(branchId, locationType, status, search, companyId);
            var cleaningsTask = hkApiClient.GetCleaningsAsync(branchId, cleaningType, status, search, companyId);
            var staffTask = hkApiClient.GetStaffListAsync(branchId, shiftId, locationId, status, search, companyId);
            var templatesTask = hkApiClient.GetChecklistTemplatesAsync(branchId);
            var shiftsTask = shiftApiClient.GetListAsync(branchId, true, null, companyId);

            await Task.WhenAll(locationsTask, cleaningsTask, staffTask, templatesTask, shiftsTask);

            var locations = (await locationsTask).ToList();
            var cleanings = (await cleaningsTask).ToList();
            var staff = (await staffTask).ToList();
            var templates = (await templatesTask).ToList();
            var shifts = (await shiftsTask).ToList();

            // Load Users for Staff & Supervisor dropdowns
            var users = await dbContext.Users
                .Where(u => u.IsActive)
                .OrderBy(u => u.FullName ?? u.Username)
                .Select(u => new SelectListItem
                {
                    Value = u.Id.ToString(),
                    Text = !string.IsNullOrWhiteSpace(u.FullName) ? $"{u.FullName} ({u.Username})" : u.Username
                })
                .ToListAsync();

            // Load Buildings and Floors for metadata
            var buildings = await dbContext.BuildingMasters
                .Where(b => b.BranchId == branchId && b.IsActive)
                .OrderBy(b => b.BuildingName)
                .Select(b => new SelectListItem { Value = b.BuildingId.ToString(), Text = b.BuildingName })
                .ToListAsync();

            var floors = await dbContext.FloorMasters
                .Where(f => f.IsActive)
                .OrderBy(f => f.FloorName)
                .Select(f => new SelectListItem { Value = f.FloorId.ToString(), Text = f.FloorName })
                .ToListAsync();

            var model = new HKIntegratedWorkspaceViewModel
            {
                ActiveTab = string.IsNullOrWhiteSpace(tab) ? "locations" : tab.ToLowerInvariant(),
                SelectedBranchId = branchId,
                Locations = locations,
                Cleanings = cleanings,
                StaffList = staff,
                ChecklistTemplates = templates,

                LocationTypeOptions = LocationTypes.Select(t => new SelectListItem { Value = t, Text = t, Selected = t == locationType }).ToList(),
                RiskLevelOptions = RiskLevels.Select(r => new SelectListItem { Value = r, Text = r }).ToList(),
                FrequencyOptions = Frequencies.Select(f => new SelectListItem { Value = f, Text = f }).ToList(),

                ShiftOptions = shifts.Select(s => new SelectListItem
                {
                    Value = s.ShiftMaster_ID.ToString(),
                    Text = $"{s.ShiftName} ({s.FormattedTimeRange})",
                    Selected = s.ShiftMaster_ID == shiftId
                }).ToList(),

                UserOptions = users,
                SupervisorOptions = users,

                LocationOptions = locations.Select(l => new SelectListItem
                {
                    Value = l.Location_ID.ToString(),
                    Text = $"{l.LocationName} [{l.LocationType} - {l.LocationCode}]",
                    Selected = l.Location_ID == locationId
                }).ToList(),

                ChecklistTemplateOptions = templates.Select(t => new SelectListItem
                {
                    Value = t.Template_ID.ToString(),
                    Text = $"{t.TemplateName} ({t.TemplateCode})"
                }).ToList(),

                BuildingOptions = buildings,
                FloorOptions = floors,

                LocationTypeFilter = locationType,
                CleaningTypeFilter = cleaningType,
                ShiftFilter = shiftId,
                LocationFilter = locationId,
                StatusFilter = status,
                SearchTerm = search
            };

            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Housekeeping Masters";
            return View("ApiDown");
        }
    }

    // ── Location Master AJAX Endpoints ───────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> GetPhysicalMasterItems(string locationType)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        var items = await hkApiClient.GetPhysicalMasterItemsAsync(locationType, branchId);
        return Json(items);
    }

    [HttpGet]
    public async Task<IActionResult> GetLocation(int id)
    {
        var item = await hkApiClient.GetLocationByIdAsync(id);
        if (item is null) return NotFound();
        return Json(item);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveLocation(HKLocationFormModel model)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        model.CompanyId = User.GetCompanyId();
        model.Branch_ID = branchId;

        if (!ModelState.IsValid)
            return BadRequest(new { success = false, message = "Please provide all required fields." });

        try
        {
            if (model.Location_ID > 0)
            {
                await hkApiClient.UpdateLocationAsync(model.Location_ID, model, User.GetUserId());
                await auditLogService.LogAsync("MasterData", "HKLocation.Edit",
                    $"Updated HK Location: {model.LocationName} ({model.LocationCode}) [{model.LocationType}]", branchId: branchId);
                TempData["Success"] = $"Location '{model.LocationName}' updated successfully.";
            }
            else
            {
                var newId = await hkApiClient.CreateLocationAsync(model, User.GetUserId());
                await auditLogService.LogAsync("MasterData", "HKLocation.Create",
                    $"Created HK Location: {model.LocationName} ({model.LocationCode}) [{model.LocationType}] [ID: {newId}]", branchId: branchId);
                TempData["Success"] = $"Location '{model.LocationName}' created successfully.";
            }

            return RedirectToAction(nameof(Index), new { tab = "locations" });
        }
        catch (Exception ex)
        {
            TempData["Error"] = ex.Message;
            return RedirectToAction(nameof(Index), new { tab = "locations" });
        }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleLocationStatus(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        try
        {
            await hkApiClient.ToggleLocationStatusAsync(id, User.GetUserId());
            await auditLogService.LogAsync("MasterData", "HKLocation.ToggleStatus", $"Toggled status for Location [ID: {id}]", branchId: branchId);
            TempData["Success"] = "Location status updated successfully.";
        }
        catch (Exception ex)
        {
            TempData["Error"] = ex.Message;
        }

        return RedirectToAction(nameof(Index), new { tab = "locations" });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> DeleteLocation(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        try
        {
            await hkApiClient.DeleteLocationAsync(id, User.GetUserId());
            await auditLogService.LogAsync("MasterData", "HKLocation.Delete", $"Deleted HK Location [ID: {id}]", branchId: branchId);
            TempData["Success"] = "Housekeeping Location deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["Error"] = ex.Message;
        }

        return RedirectToAction(nameof(Index), new { tab = "locations" });
    }

    // ── Cleaning Master AJAX Endpoints ───────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> GetCleaning(int id)
    {
        var item = await hkApiClient.GetCleaningByIdAsync(id);
        if (item is null) return NotFound();
        return Json(item);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveCleaning(HKCleaningFormModel model)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        model.CompanyId = User.GetCompanyId();
        model.Branch_ID = branchId;

        if (!ModelState.IsValid)
            return BadRequest(new { success = false, message = "Please provide all required fields." });

        try
        {
            if (model.Cleaning_ID > 0)
            {
                await hkApiClient.UpdateCleaningAsync(model.Cleaning_ID, model, User.GetUserId());
                await auditLogService.LogAsync("MasterData", "HKCleaning.Edit",
                    $"Updated HK Cleaning Protocol: {model.CleaningType} - {model.Frequency}", branchId: branchId);
                TempData["Success"] = $"Cleaning protocol '{model.CleaningType}' updated successfully.";
            }
            else
            {
                var newId = await hkApiClient.CreateCleaningAsync(model, User.GetUserId());
                await auditLogService.LogAsync("MasterData", "HKCleaning.Create",
                    $"Created HK Cleaning Protocol: {model.CleaningType} - {model.Frequency} [ID: {newId}]", branchId: branchId);
                TempData["Success"] = $"Cleaning protocol '{model.CleaningType}' created successfully.";
            }

            return RedirectToAction(nameof(Index), new { tab = "cleanings" });
        }
        catch (Exception ex)
        {
            TempData["Error"] = ex.Message;
            return RedirectToAction(nameof(Index), new { tab = "cleanings" });
        }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleCleaningStatus(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        try
        {
            await hkApiClient.ToggleCleaningStatusAsync(id, User.GetUserId());
            await auditLogService.LogAsync("MasterData", "HKCleaning.ToggleStatus", $"Toggled status for Cleaning Protocol [ID: {id}]", branchId: branchId);
            TempData["Success"] = "Cleaning protocol status updated successfully.";
        }
        catch (Exception ex)
        {
            TempData["Error"] = ex.Message;
        }

        return RedirectToAction(nameof(Index), new { tab = "cleanings" });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> DeleteCleaning(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        try
        {
            await hkApiClient.DeleteCleaningAsync(id, User.GetUserId());
            await auditLogService.LogAsync("MasterData", "HKCleaning.Delete", $"Deleted HK Cleaning Protocol [ID: {id}]", branchId: branchId);
            TempData["Success"] = "Cleaning protocol deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["Error"] = ex.Message;
        }

        return RedirectToAction(nameof(Index), new { tab = "cleanings" });
    }

    // ── HK Staff Master AJAX Endpoints ───────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> GetStaff(int id)
    {
        var item = await hkApiClient.GetStaffByIdAsync(id);
        if (item is null) return NotFound();
        return Json(item);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveStaff(HKStaffFormModel model)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        model.CompanyId = User.GetCompanyId();
        model.Branch_ID = branchId;

        if (!ModelState.IsValid)
            return BadRequest(new { success = false, message = "Please provide all required fields." });

        try
        {
            if (model.HKStaff_ID > 0)
            {
                await hkApiClient.UpdateStaffAsync(model.HKStaff_ID, model, User.GetUserId());
                await auditLogService.LogAsync("MasterData", "HKStaff.Edit",
                    $"Updated HK Staff Allocation: Staff #{model.Staff_ID} in Shift #{model.ShiftMaster_ID}", branchId: branchId);
                TempData["Success"] = "Housekeeping Staff allocation updated successfully.";
            }
            else
            {
                var newId = await hkApiClient.CreateStaffAsync(model, User.GetUserId());
                await auditLogService.LogAsync("MasterData", "HKStaff.Create",
                    $"Created HK Staff Allocation: Staff #{model.Staff_ID} in Shift #{model.ShiftMaster_ID} [ID: {newId}]", branchId: branchId);
                TempData["Success"] = "Housekeeping Staff allocation created successfully.";
            }

            return RedirectToAction(nameof(Index), new { tab = "staff" });
        }
        catch (Exception ex)
        {
            TempData["Error"] = ex.Message;
            return RedirectToAction(nameof(Index), new { tab = "staff" });
        }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStaffStatus(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        try
        {
            await hkApiClient.ToggleStaffStatusAsync(id, User.GetUserId());
            await auditLogService.LogAsync("MasterData", "HKStaff.ToggleStatus", $"Toggled status for HK Staff Allocation [ID: {id}]", branchId: branchId);
            TempData["Success"] = "Staff allocation status updated successfully.";
        }
        catch (Exception ex)
        {
            TempData["Error"] = ex.Message;
        }

        return RedirectToAction(nameof(Index), new { tab = "staff" });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> DeleteStaff(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        try
        {
            await hkApiClient.DeleteStaffAsync(id, User.GetUserId());
            await auditLogService.LogAsync("MasterData", "HKStaff.Delete", $"Deleted HK Staff Allocation [ID: {id}]", branchId: branchId);
            TempData["Success"] = "Housekeeping Staff allocation deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["Error"] = ex.Message;
        }

        return RedirectToAction(nameof(Index), new { tab = "staff" });
    }
}
