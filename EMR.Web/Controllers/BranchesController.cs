using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using EMR.Web.Services.Geography;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
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
    public async Task<IActionResult> Index(int? companyId = null)
    {
        if (!CanManage())
        {
            return RedirectToAction("Index", "Dashboard");
        }

        var query = dbContext.BranchMasters
            .Include(x => x.Company)
            .AsQueryable();

        var userCompanyId = User.GetCompanyId();
        if (!User.IsSuperAdmin())
        {
            query = query.Where(x => x.CompanyId == userCompanyId);
        }
        else if (companyId.HasValue && companyId.Value > 0)
        {
            query = query.Where(x => x.CompanyId == companyId.Value);
        }

        var branches = await query
            .OrderBy(x => x.Company.CompanyName)
            .ThenBy(x => x.BranchName)
            .ToListAsync();

        ViewBag.Companies = await dbContext.CompanyMasters
            .Where(x => x.IsActive)
            .OrderBy(x => x.CompanyName)
            .Select(x => new SelectListItem(x.CompanyName, x.CompanyId.ToString(), companyId.HasValue && x.CompanyId == companyId.Value))
            .ToListAsync();

        ViewBag.SelectedCompanyId = companyId;

        return View(branches);
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var branch = await dbContext.BranchMasters
            .Include(x => x.Company)
            .Include(x => x.UserBranches.Where(ub => ub.IsActive))
                .ThenInclude(x => x.User)
            .FirstOrDefaultAsync(x => x.BranchId == id);

        if (branch is null) return NotFound();

        var companyRoles = await dbContext.Roles
            .Where(r => r.CompanyId == branch.CompanyId)
            .OrderBy(r => r.Name)
            .Select(r => r.Name)
            .ToListAsync();

        var model = new BranchDetailsViewModel
        {
            BranchId = branch.BranchId,
            CompanyId = branch.CompanyId,
            CompanyName = branch.Company?.CompanyName ?? "Primary Healthcare Network",
            BranchName = branch.BranchName,
            BranchCode = branch.BranchCode,
            Country = branch.Country,
            State = branch.State,
            City = branch.City,
            Address = branch.Address,
            Pincode = branch.Pincode,
            IsHOBranch = branch.IsHOBranch,
            IsLab = branch.IsLab,
            IsActive = branch.IsActive,
            CreatedDate = branch.CreatedDate,
            ModifiedDate = branch.ModifiedDate,
            MappedUsersCount = branch.UserBranches.Count,
            MappedUsers = branch.UserBranches
                .Where(ub => ub.User is not null)
                .Select(ub => ub.User.FullName ?? ub.User.Username)
                .OrderBy(n => n)
                .ToList(),
            Roles = companyRoles
        };

        return View(model);
    }

    [HttpGet]
    public async Task<IActionResult> Create(int? companyId = null)
    {
        if (!CanManage())
        {
            return RedirectToAction("Index", "Dashboard");
        }

        var model = new BranchFormViewModel
        {
            CompanyId = companyId ?? User.GetCompanyId(),
            CompanyOptions = await GetActiveCompanyOptionsAsync()
        };

        return View(model);
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

        var companyId = model.CompanyId > 0 ? model.CompanyId : User.GetCompanyId();
        await ValidateSingleHeadOfficeAsync(model, companyId, excludeBranchId: null);

        if (!ModelState.IsValid)
        {
            model.CompanyOptions = await GetActiveCompanyOptionsAsync();
            return View(model);
        }

        var branch = new BranchMaster
        {
            CompanyId = companyId,
            BranchName = model.BranchName.Trim(),
            BranchCode = model.BranchCode.Trim(),
            Country = model.Country,
            State = model.State,
            City = model.City,
            Address = model.Address,
            Pincode = model.Pincode,
            IsHOBranch = model.IsHOBranch,
            IsLab = model.IsLab,
            IsActive = model.IsActive,
            CreatedDate = DateTime.Now,
            CreatedBy = User.GetUserId(),
        };

        // The branch and its Hospital Settings are saved together: either both exist or neither does.
        string settingsSource;
        await using (var tx = await dbContext.Database.BeginTransactionAsync())
        {
            try
            {
                dbContext.BranchMasters.Add(branch);
                await dbContext.SaveChangesAsync();

                settingsSource = await CreateHospitalSettingsForBranchAsync(branch);
                await dbContext.SaveChangesAsync();

                await tx.CommitAsync();
            }
            catch (DbUpdateException ex) when (IsHeadOfficeUniqueViolation(ex))
            {
                // another save got there first - the database index keeps one HO per company
                await tx.RollbackAsync();
                dbContext.ChangeTracker.Clear();
                ModelState.AddModelError(nameof(model.IsHOBranch), "This company already has a Head Office branch. Only one Head Office is allowed per company.");
                model.CompanyOptions = await GetActiveCompanyOptionsAsync();
                return View(model);
            }
        }

        await auditLogService.LogAsync("MasterData", "Branches.Create",
            $"Created branch: {branch.BranchName} under CompanyId: {branch.CompanyId}. Hospital Settings {settingsSource}.",
            branchId: branch.BranchId);
        TempData["Success"] = settingsSource.StartsWith("copied")
            ? $"Branch created successfully. Hospital Settings were copied from the Head Office - review them for {branch.BranchName}."
            : "Branch created successfully.";

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
            CompanyId = branch.CompanyId,
            CompanyOptions = await GetActiveCompanyOptionsAsync(),
            BranchName = branch.BranchName,
            BranchCode = branch.BranchCode,
            Country = branch.Country,
            State = branch.State,
            City = branch.City,
            Address = branch.Address,
            Pincode = branch.Pincode,
            IsHOBranch = branch.IsHOBranch,
            IsLab = branch.IsLab,
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

        var targetCompanyId = model.CompanyId > 0 ? model.CompanyId : branch.CompanyId;
        await ValidateSingleHeadOfficeAsync(model, targetCompanyId, excludeBranchId: branch.BranchId);

        if (!ModelState.IsValid)
        {
            model.CompanyOptions = await GetActiveCompanyOptionsAsync();
            return View(model);
        }

        branch.CompanyId = model.CompanyId > 0 ? model.CompanyId : branch.CompanyId;
        branch.BranchName = model.BranchName.Trim();
        branch.BranchCode = model.BranchCode.Trim();
        branch.Country = model.Country;
        branch.State = model.State;
        branch.City = model.City;
        branch.Address = model.Address;
        branch.Pincode = model.Pincode;
        branch.IsHOBranch = model.IsHOBranch;
        branch.IsLab = model.IsLab;
        branch.IsActive = model.IsActive;
        branch.ModifiedBy = User.GetUserId();
        branch.ModifiedDate = DateTime.Now;

        try
        {
            await dbContext.SaveChangesAsync();
        }
        catch (DbUpdateException ex) when (IsHeadOfficeUniqueViolation(ex))
        {
            ModelState.AddModelError(nameof(model.IsHOBranch), "This company already has a Head Office branch. Only one Head Office is allowed per company.");
            model.CompanyOptions = await GetActiveCompanyOptionsAsync();
            return View(model);
        }
        await auditLogService.LogAsync("MasterData", "Branches.Edit", $"Updated branch: {branch.BranchName}", branchId: branch.BranchId);
        TempData["Success"] = "Branch updated successfully.";

        return RedirectToAction(nameof(Index));
    }

    /// <summary>Only one Head Office branch per company (the database index enforces the same rule).</summary>
    private async Task ValidateSingleHeadOfficeAsync(BranchFormViewModel model, int companyId, int? excludeBranchId)
    {
        if (!model.IsHOBranch) return;

        var existing = await dbContext.BranchMasters
            .Where(x => x.CompanyId == companyId && x.IsHOBranch && (excludeBranchId == null || x.BranchId != excludeBranchId))
            .Select(x => new { x.BranchName, x.BranchCode })
            .FirstOrDefaultAsync();

        if (existing != null)
            ModelState.AddModelError(nameof(model.IsHOBranch),
                $"This company already has a Head Office branch ({existing.BranchName} - {existing.BranchCode}). Only one Head Office is allowed per company.");
    }

    private static bool IsHeadOfficeUniqueViolation(DbUpdateException ex)
        => ex.InnerException?.Message.Contains("UQ_Branchmaster_OneHeadOfficePerCompany", StringComparison.OrdinalIgnoreCase) == true;

    /// <summary>
    /// A new branch starts with the company's Head Office Hospital Settings, copied in full (letterhead, contacts,
    /// NABH, OPD / LAB parameters...). Only the identity and audit fields are its own. With no Head Office settings
    /// to copy (e.g. the company's first branch) it falls back to a default record, as before.
    /// Returns a short note of what was done, for the audit trail.
    /// </summary>
    private async Task<string> CreateHospitalSettingsForBranchAsync(BranchMaster branch)
    {
        var source = await dbContext.HospitalSettings
            .AsNoTracking()
            .Where(s => s.Branch != null && s.Branch.CompanyId == branch.CompanyId && s.Branch.IsHOBranch
                        && s.BranchId != branch.BranchId)
            .OrderByDescending(s => s.IsActive)
            .ThenBy(s => s.Id)
            .FirstOrDefaultAsync();

        var now = DateTime.Now;
        var userId = User.GetUserId();

        if (source is null)
        {
            dbContext.HospitalSettings.Add(new HospitalSettings
            {
                CompanyId = branch.CompanyId,
                BranchId = branch.BranchId,
                HospitalName = branch.BranchName,
                IsActive = true,
                CreatedDate = now,
                CreatedBy = userId
            });
            return "created with defaults (no Head Office settings to copy)";
        }

        // copy every setting, then make the record this branch's own
        var copy = new HospitalSettings();
        dbContext.Entry(copy).CurrentValues.SetValues(source);
        copy.Id = 0;
        copy.CompanyId = branch.CompanyId;
        copy.BranchId = branch.BranchId;
        copy.Branch = null;
        copy.CreatedDate = now;
        copy.CreatedBy = userId;
        copy.LastModifiedDate = null;
        copy.LastModifiedBy = null;

        dbContext.HospitalSettings.Add(copy);
        return $"copied from the Head Office settings (Id {source.Id}, branch {source.BranchId})";
    }

    private async Task<List<SelectListItem>> GetActiveCompanyOptionsAsync()
    {
        return await dbContext.CompanyMasters
            .Where(x => x.IsActive)
            .OrderBy(x => x.CompanyName)
            .Select(x => new SelectListItem(x.CompanyName, x.CompanyId.ToString()))
            .ToListAsync();
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
