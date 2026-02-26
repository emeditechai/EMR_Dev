using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using EMR.Web.Services.Geography;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class BranchesController(
    ApplicationDbContext dbContext,
    IAuditLogService auditLogService,
    ICountryService countryService,
    IStateService stateService,
    IDistrictService districtService,
    ICityService cityService) : Controller
{
    public async Task<IActionResult> Index()
    {
        if (!CanManage())
        {
            return RedirectToAction("Index", "Dashboard");
        }

        var branches = await dbContext.BranchMasters
            .OrderBy(x => x.BranchName)
            .ToListAsync();

        return View(branches);
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var branch = await dbContext.BranchMasters
            .Include(x => x.UserBranches.Where(ub => ub.IsActive))
                .ThenInclude(x => x.User)
            .Include(x => x.Roles.OrderBy(r => r.Name))
            .FirstOrDefaultAsync(x => x.BranchId == id);

        if (branch is null) return NotFound();

        var model = new BranchDetailsViewModel
        {
            BranchId = branch.BranchId,
            BranchName = branch.BranchName,
            BranchCode = branch.BranchCode,
            Country = branch.Country,
            State = branch.State,
            City = branch.City,
            Address = branch.Address,
            Pincode = branch.Pincode,
            IsHOBranch = branch.IsHOBranch,
            IsActive = branch.IsActive,
            CreatedDate = branch.CreatedDate,
            ModifiedDate = branch.ModifiedDate,
            MappedUsersCount = branch.UserBranches.Count,
            MappedUsers = branch.UserBranches
                .Where(ub => ub.User is not null)
                .Select(ub => ub.User.FullName ?? ub.User.Username)
                .OrderBy(n => n)
                .ToList(),
            Roles = branch.Roles.Select(r => r.Name).ToList()
        };

        return View(model);
    }

    [HttpGet]
    public IActionResult Create()
    {
        if (!CanManage())
        {
            return RedirectToAction("Index", "Dashboard");
        }

        return View(new BranchFormViewModel());
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(BranchFormViewModel model)
    {
        if (!CanManage())
        {
            return RedirectToAction("Index", "Dashboard");
        }

        if (await dbContext.BranchMasters.AnyAsync(x => x.BranchCode == model.BranchCode))
        {
            ModelState.AddModelError(nameof(model.BranchCode), "Branch code already exists.");
        }

        if (!ModelState.IsValid)
        {
            return View(model);
        }

        var branch = new BranchMaster
        {
            BranchName = model.BranchName.Trim(),
            BranchCode = model.BranchCode.Trim(),
            Country = model.Country,
            State = model.State,
            City = model.City,
            Address = model.Address,
            Pincode = model.Pincode,
            IsHOBranch = model.IsHOBranch,
            IsActive = model.IsActive,
            CreatedDate = DateTime.UtcNow,
            CreatedBy = User.GetUserId(),
        };

        dbContext.BranchMasters.Add(branch);
        await dbContext.SaveChangesAsync();

        // Auto-create a default HospitalSettings record for the new branch
        var defaultSettings = new HospitalSettings
        {
            BranchId = branch.BranchId,
            HospitalName = branch.BranchName,
            IsActive = true,
            CreatedDate = DateTime.UtcNow,
            CreatedBy = User.GetUserId()
        };
        dbContext.HospitalSettings.Add(defaultSettings);
        await dbContext.SaveChangesAsync();

        await auditLogService.LogAsync("MasterData", "Branches.Create", $"Created branch: {branch.BranchName}", branchId: branch.BranchId);
        TempData["Success"] = "Branch created successfully.";

        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        if (!CanManage())
        {
            return RedirectToAction("Index", "Dashboard");
        }

        var branch = await dbContext.BranchMasters.FirstOrDefaultAsync(x => x.BranchId == id);
        if (branch is null)
        {
            return NotFound();
        }

        var model = new BranchFormViewModel
        {
            BranchId = branch.BranchId,
            BranchName = branch.BranchName,
            BranchCode = branch.BranchCode,
            Country = branch.Country,
            State = branch.State,
            City = branch.City,
            Address = branch.Address,
            Pincode = branch.Pincode,
            IsHOBranch = branch.IsHOBranch,
            IsActive = branch.IsActive,
        };

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(BranchFormViewModel model)
    {
        if (!CanManage())
        {
            return RedirectToAction("Index", "Dashboard");
        }

        var branch = await dbContext.BranchMasters.FirstOrDefaultAsync(x => x.BranchId == model.BranchId);
        if (branch is null)
        {
            return NotFound();
        }

        if (await dbContext.BranchMasters.AnyAsync(x => x.BranchId != model.BranchId && x.BranchCode == model.BranchCode))
        {
            ModelState.AddModelError(nameof(model.BranchCode), "Branch code already exists.");
        }

        if (!ModelState.IsValid)
        {
            return View(model);
        }

        branch.BranchName = model.BranchName.Trim();
        branch.BranchCode = model.BranchCode.Trim();
        branch.Country = model.Country;
        branch.State = model.State;
        branch.City = model.City;
        branch.Address = model.Address;
        branch.Pincode = model.Pincode;
        branch.IsHOBranch = model.IsHOBranch;
        branch.IsActive = model.IsActive;
        branch.ModifiedBy = User.GetUserId();
        branch.ModifiedDate = DateTime.UtcNow;

        await dbContext.SaveChangesAsync();
        await auditLogService.LogAsync("MasterData", "Branches.Edit", $"Updated branch: {branch.BranchName}", branchId: branch.BranchId);
        TempData["Success"] = "Branch updated successfully.";

        return RedirectToAction(nameof(Index));
    }

    private bool CanManage() => true; // TODO: re-enable role check when authorization is implemented

    // ── Geography AJAX search ──────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> SearchCountries(string term)
    {
        if (string.IsNullOrWhiteSpace(term)) return Json(Array.Empty<string>());
        var all = await countryService.GetActiveAsync();
        var results = all
            .Where(c => c.CountryName.Contains(term, StringComparison.OrdinalIgnoreCase))
            .OrderBy(c => c.CountryName)
            .Take(10)
            .Select(c => new { c.CountryId, c.CountryName })
            .ToList();
        return Json(results);
    }

    [HttpGet]
    public async Task<IActionResult> SearchStates(string term, string? country = null)
    {
        IEnumerable<StateMaster> states;
        if (!string.IsNullOrWhiteSpace(country))
        {
            var allCountries = await countryService.GetActiveAsync();
            var matched = allCountries.FirstOrDefault(c =>
                c.CountryName.Equals(country, StringComparison.OrdinalIgnoreCase));
            states = matched is not null
                ? await stateService.GetByCountryAsync(matched.CountryId)
                : await stateService.GetAllAsync();
        }
        else
        {
            states = await stateService.GetAllAsync();
        }

        if (string.IsNullOrWhiteSpace(term)) return Json(Array.Empty<string>());
        var results = states
            .Where(s => s.StateName.Contains(term, StringComparison.OrdinalIgnoreCase))
            .OrderBy(s => s.StateName)
            .Take(10)
            .Select(s => new { s.StateId, s.StateName })
            .ToList();
        return Json(results);
    }

    [HttpGet]
    public async Task<IActionResult> SearchCities(string term, string? state = null)
    {
        IEnumerable<CityMaster> cities;
        if (!string.IsNullOrWhiteSpace(state))
        {
            var allStates = await stateService.GetAllAsync();
            var matchedState = allStates.FirstOrDefault(s =>
                s.StateName.Equals(state, StringComparison.OrdinalIgnoreCase));
            if (matchedState is not null)
            {
                var districts = await districtService.GetByStateAsync(matchedState.StateId);
                var allCities = new List<CityMaster>();
                foreach (var d in districts)
                    allCities.AddRange(await cityService.GetByDistrictAsync(d.DistrictId));
                cities = allCities;
            }
            else
            {
                cities = await cityService.GetAllAsync();
            }
        }
        else
        {
            cities = await cityService.GetAllAsync();
        }

        if (string.IsNullOrWhiteSpace(term)) return Json(Array.Empty<string>());
        var results = cities
            .Where(c => c.CityName.Contains(term, StringComparison.OrdinalIgnoreCase))
            .OrderBy(c => c.CityName)
            .Take(10)
            .Select(c => new { c.CityId, c.CityName })
            .ToList();
        return Json(results);
    }
}
