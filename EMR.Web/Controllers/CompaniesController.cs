using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using EMR.Web.Services.Geography;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class CompaniesController(
    ApplicationDbContext dbContext,
    IAuditLogService auditLogService,
    IWebHostEnvironment webHostEnvironment,
    ICountryService countryService,
    IStateService stateService,
    ICityService cityService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(string? search = null)
    {
        var query = dbContext.CompanyMasters
            .Include(x => x.Branches)
            .Include(x => x.Users)
            .AsQueryable();

        if (!string.IsNullOrWhiteSpace(search))
        {
            query = query.Where(x => x.CompanyName.Contains(search) 
                                  || x.CompanyCode.Contains(search) 
                                  || (x.City != null && x.City.Contains(search)));
        }

        var companies = await query
            .OrderByDescending(x => x.IsActive)
            .ThenBy(x => x.CompanyName)
            .Select(x => new CompanyListItemViewModel
            {
                CompanyId = x.CompanyId,
                CompanyCode = x.CompanyCode,
                CompanyName = x.CompanyName,
                LegalName = x.LegalName,
                Email = x.Email,
                Phone = x.Phone,
                City = x.City,
                State = x.State,
                LogoPath = x.LogoPath,
                IsActive = x.IsActive,
                TotalBranches = x.Branches.Count,
                TotalUsers = x.Users.Count,
                CreatedDate = x.CreatedDate
            })
            .ToListAsync();

        ViewBag.Search = search;
        return View(companies);
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var company = await dbContext.CompanyMasters
            .Include(x => x.Branches)
                .ThenInclude(b => b.UserBranches.Where(ub => ub.IsActive))
            .Include(x => x.Users)
            .FirstOrDefaultAsync(x => x.CompanyId == id);

        if (company is null) return NotFound();

        var model = new CompanyDetailsViewModel
        {
            CompanyId = company.CompanyId,
            CompanyCode = company.CompanyCode,
            CompanyName = company.CompanyName,
            LegalName = company.LegalName,
            RegistrationNumber = company.RegistrationNumber,
            GSTIN = company.GSTIN,
            PAN = company.PAN,
            Email = company.Email,
            Phone = company.Phone,
            Website = company.Website,
            LogoPath = company.LogoPath,
            FullAddress = string.Join(", ", new[] { company.Address, company.City, company.State, company.Country, company.Pincode }.Where(s => !string.IsNullOrWhiteSpace(s))),
            IsActive = company.IsActive,
            CreatedDate = company.CreatedDate,
            ModifiedDate = company.ModifiedDate,
            Branches = company.Branches.Select(b => new BranchSummaryItem
            {
                BranchId = b.BranchId,
                BranchCode = b.BranchCode,
                BranchName = b.BranchName,
                City = b.City,
                State = b.State,
                IsHOBranch = b.IsHOBranch,
                IsActive = b.IsActive,
                ActiveUsersCount = b.UserBranches.Count
            }).OrderBy(b => b.BranchName).ToList(),
            Users = company.Users.Select(u => new UserSummaryItem
            {
                UserId = u.Id,
                Username = u.Username,
                FullName = u.FullName ?? $"{u.FirstName} {u.LastName}".Trim(),
                Role = u.Role,
                IsActive = u.IsActive
            }).OrderBy(u => u.Username).ToList()
        };

        return View(model);
    }

    [HttpGet]
    public IActionResult Create()
    {
        return View(new CompanyFormViewModel());
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(CompanyFormViewModel model)
    {
        if (await dbContext.CompanyMasters.AnyAsync(x => x.CompanyCode == model.CompanyCode))
        {
            ModelState.AddModelError(nameof(model.CompanyCode), "Company Code already exists.");
        }

        if (!ModelState.IsValid)
        {
            return View(model);
        }

        string? logoPath = null;
        if (model.LogoFile is { Length: > 0 })
        {
            logoPath = await SaveLogoFileAsync(model.LogoFile);
        }

        var company = new CompanyMaster
        {
            CompanyCode = model.CompanyCode.Trim().ToUpperInvariant(),
            CompanyName = model.CompanyName.Trim(),
            LegalName = model.LegalName?.Trim(),
            RegistrationNumber = model.RegistrationNumber?.Trim(),
            GSTIN = model.GSTIN?.Trim(),
            PAN = model.PAN?.Trim(),
            Email = model.Email?.Trim(),
            Phone = model.Phone?.Trim(),
            Website = model.Website?.Trim(),
            Address = model.Address?.Trim(),
            Country = model.Country?.Trim(),
            State = model.State?.Trim(),
            City = model.City?.Trim(),
            Pincode = model.Pincode?.Trim(),
            LogoPath = logoPath,
            IsActive = model.IsActive,
            CreatedBy = User.GetUserId(),
            CreatedDate = DateTime.Now
        };

        dbContext.CompanyMasters.Add(company);
        await dbContext.SaveChangesAsync();

        await auditLogService.LogAsync("Company", "Create", $"Created company: {company.CompanyName} ({company.CompanyCode})", branchId: User.GetCurrentBranchId());
        TempData["Success"] = $"Company '{company.CompanyName}' created successfully. You can now add branches under this company.";

        return RedirectToAction(nameof(Details), new { id = company.CompanyId });
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var company = await dbContext.CompanyMasters.FindAsync(id);
        if (company is null) return NotFound();

        var model = new CompanyFormViewModel
        {
            CompanyId = company.CompanyId,
            CompanyCode = company.CompanyCode,
            CompanyName = company.CompanyName,
            LegalName = company.LegalName,
            RegistrationNumber = company.RegistrationNumber,
            GSTIN = company.GSTIN,
            PAN = company.PAN,
            Email = company.Email,
            Phone = company.Phone,
            Website = company.Website,
            Address = company.Address,
            Country = company.Country,
            State = company.State,
            City = company.City,
            Pincode = company.Pincode,
            IsActive = company.IsActive,
            ExistingLogoPath = company.LogoPath
        };

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(CompanyFormViewModel model)
    {
        if (await dbContext.CompanyMasters.AnyAsync(x => x.CompanyCode == model.CompanyCode && x.CompanyId != model.CompanyId))
        {
            ModelState.AddModelError(nameof(model.CompanyCode), "Company Code already exists.");
        }

        if (!ModelState.IsValid)
        {
            return View(model);
        }

        var company = await dbContext.CompanyMasters.FindAsync(model.CompanyId);
        if (company is null) return NotFound();

        if (model.LogoFile is { Length: > 0 })
        {
            company.LogoPath = await SaveLogoFileAsync(model.LogoFile);
        }

        company.CompanyCode = model.CompanyCode.Trim().ToUpperInvariant();
        company.CompanyName = model.CompanyName.Trim();
        company.LegalName = model.LegalName?.Trim();
        company.RegistrationNumber = model.RegistrationNumber?.Trim();
        company.GSTIN = model.GSTIN?.Trim();
        company.PAN = model.PAN?.Trim();
        company.Email = model.Email?.Trim();
        company.Phone = model.Phone?.Trim();
        company.Website = model.Website?.Trim();
        company.Address = model.Address?.Trim();
        company.Country = model.Country?.Trim();
        company.State = model.State?.Trim();
        company.City = model.City?.Trim();
        company.Pincode = model.Pincode?.Trim();
        company.IsActive = model.IsActive;
        company.ModifiedBy = User.GetUserId();
        company.ModifiedDate = DateTime.Now;

        await dbContext.SaveChangesAsync();

        await auditLogService.LogAsync("Company", "Edit", $"Updated company: {company.CompanyName}", branchId: User.GetCurrentBranchId());
        TempData["Success"] = "Company details updated successfully.";

        return RedirectToAction(nameof(Details), new { id = company.CompanyId });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id)
    {
        var company = await dbContext.CompanyMasters.FindAsync(id);
        if (company is null) return NotFound();

        company.IsActive = !company.IsActive;
        company.ModifiedBy = User.GetUserId();
        company.ModifiedDate = DateTime.Now;
        await dbContext.SaveChangesAsync();

        await auditLogService.LogAsync("Company", "ToggleStatus", $"Toggled status of company: {company.CompanyName} to {(company.IsActive ? "Active" : "Inactive")}", branchId: User.GetCurrentBranchId());
        TempData["Success"] = $"Company status updated to {(company.IsActive ? "Active" : "Inactive")}.";

        return RedirectToAction(nameof(Index));
    }

    // ── New Company wizard (SQLScripts/2306): company + Head Office branch + Hospital Settings + navigation + Administrator ──
    // A new screen next to the existing Create / Edit (unchanged). Only Super Admin onboards a company.

    private bool IsSuperAdmin => User.HasClaim("IsSuperAdmin", "true");

    [HttpGet]
    public async Task<IActionResult> Onboard([FromServices] EMR.Web.ApiClients.ICompanyOnboardingApiClient onboarding)
    {
        if (!IsSuperAdmin) return RedirectToAction(nameof(Create));
        var model = new CompanyOnboardViewModel { Templates = await onboarding.TemplatesAsync() };
        model.TemplateCompanyId = model.Templates.FirstOrDefault(t => t.CompanyId == User.GetCompanyId())?.CompanyId
                                  ?? model.Templates.FirstOrDefault()?.CompanyId ?? 0;
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequestSizeLimit(10 * 1024 * 1024)]
    public async Task<IActionResult> Onboard(CompanyOnboardViewModel model,
        [FromServices] EMR.Web.ApiClients.ICompanyOnboardingApiClient onboarding, [FromServices] IPasswordHasherService passwordHasher)
    {
        if (!IsSuperAdmin) return RedirectToAction(nameof(Create));
        model.CompanyCode = (model.CompanyCode ?? "").Trim().ToUpperInvariant();
        model.BranchCode = (model.BranchCode ?? "").Trim().ToUpperInvariant();
        // the administrator signs in with the e-mail (SQLScripts/2307): the user name is the e-mail
        model.AdminEmail = model.AdminEmail?.Trim().ToLowerInvariant();
        model.AdminUsername = model.AdminEmail ?? "";
        ModelState.Remove(nameof(model.AdminUsername));

        // codes and username: free in the whole application
        if (ModelState.IsValid || !string.IsNullOrEmpty(model.CompanyCode))
        {
            var free = await onboarding.CheckAsync(model.CompanyCode, model.BranchCode, model.AdminUsername, model.AdminEmail);
            if (!free.CompanyCodeFree) ModelState.AddModelError(nameof(model.CompanyCode), "This company code is already used.");
            if (!free.BranchCodeFree) ModelState.AddModelError(nameof(model.BranchCode), "This branch code is already used - branch codes are unique in the whole application.");
            if (!free.UsernameFree || !free.EmailFree) ModelState.AddModelError(nameof(model.AdminEmail), "This e-mail is already used by another sign-in.");
        }
        if (model.LogoFile is { Length: > 0 } logo)
        {
            var ext = Path.GetExtension(logo.FileName).ToLowerInvariant();
            if (ext is not (".png" or ".jpg" or ".jpeg" or ".webp")) ModelState.AddModelError(nameof(model.LogoFile), "Logo must be a PNG, JPG or WEBP image.");
            else if (logo.Length > 2 * 1024 * 1024) ModelState.AddModelError(nameof(model.LogoFile), "Logo can be up to 2 MB.");
        }

        if (!ModelState.IsValid)
        {
            model.Templates = await onboarding.TemplatesAsync();
            model.Step = FirstStepWithError();
            return View(model);
        }

        var (hash, salt) = passwordHasher.HashPassword(model.AdminPassword!);
        var logoPath = model.LogoFile is { Length: > 0 } ? await SaveLogoFileAsync(model.LogoFile) : null;
        string? T(string? v) => string.IsNullOrWhiteSpace(v) ? null : v.Trim();
        var (result, error) = await onboarding.OnboardAsync(new EMR.Web.ApiClients.CompanyOnboardRequest
        {
            CompanyCode = model.CompanyCode, CompanyName = model.CompanyName.Trim(), LegalName = T(model.LegalName), RegistrationNumber = T(model.RegistrationNumber),
            GSTIN = T(model.GSTIN)?.ToUpperInvariant(), PAN = T(model.PAN)?.ToUpperInvariant(), Email = T(model.Email), Phone = T(model.Phone), Website = T(model.Website),
            Address = T(model.Address), Country = T(model.Country), State = T(model.State), City = T(model.City), Pincode = T(model.Pincode), LogoPath = logoPath,
            BranchCode = model.BranchCode, BranchName = model.BranchName.Trim(),
            BranchAddress = model.SameAddressAsCompany ? T(model.Address) : T(model.BranchAddress),
            BranchCountry = T(model.Country),
            BranchState = model.SameAddressAsCompany ? T(model.State) : T(model.BranchState),
            BranchCity = model.SameAddressAsCompany ? T(model.City) : T(model.BranchCity),
            BranchPincode = model.SameAddressAsCompany ? T(model.Pincode) : T(model.BranchPincode),
            BranchIsLab = model.BranchIsLab,
            HospitalName = model.HospitalName.Trim(), HospitalPhone = T(model.HospitalPhone), HospitalEmail = T(model.HospitalEmail),
            OpdRegistrationValidityDays = model.OpdRegistrationValidityDays,
            AdminUsername = model.AdminUsername, AdminFirstName = model.AdminFirstName.Trim(), AdminLastName = model.AdminLastName.Trim(),
            AdminEmail = T(model.AdminEmail), AdminPhone = T(model.AdminPhone), AdminEmployeeCode = T(model.AdminEmployeeCode)?.ToUpperInvariant(),
            AdminPasswordHash = hash, AdminSalt = salt, AdminMustChangePassword = model.AdminMustChangePassword,
            TemplateCompanyId = model.TemplateCompanyId, CopyAdminPermissions = model.CopyAdminPermissions, CopyOtherRoles = model.CopyOtherRoles,
            CreatedBy = User.GetUserId()
        });

        if (result is null)
        {
            if (logoPath is not null) DeleteLogoFile(logoPath);   // nothing was created - no orphan file either
            ModelState.AddModelError(string.Empty, error ?? "The company could not be created. Nothing was saved.");
            model.Templates = await onboarding.TemplatesAsync();
            model.Step = 5;
            return View(model);
        }

        await auditLogService.LogAsync("Company", "Onboard",
            $"Onboarded company {model.CompanyName} ({model.CompanyCode}): Head Office {model.BranchCode}, Hospital Settings, {result.Pages} pages / {result.Menus} menus copied, " +
            $"{result.Roles} role(s), {result.Permissions} Administrator permission(s) copied, administrator '{model.AdminUsername}'.", branchId: User.GetCurrentBranchId());
        TempData["Onboarded"] = System.Text.Json.JsonSerializer.Serialize(result);
        return RedirectToAction(nameof(Onboarded), new { id = result.CompanyId });
    }

    /// <summary>Wizard: are the company code, branch code and username free?</summary>
    [HttpGet]
    public async Task<IActionResult> OnboardCheck(string? companyCode, string? branchCode, string? username, string? email,
        [FromServices] EMR.Web.ApiClients.ICompanyOnboardingApiClient onboarding)
    {
        if (!IsSuperAdmin) return Forbid();
        return Json(await onboarding.CheckAsync(companyCode?.Trim(), branchCode?.Trim(), username?.Trim(), email?.Trim()));
    }

    /// <summary>Wizard: Country / State / City from the masters (dependent lists; the chosen names are stored as text).</summary>
    [HttpGet]
    public async Task<IActionResult> OnboardGeo(string level, int? parentId)
    {
        if (!IsSuperAdmin) return Forbid();
        IEnumerable<object> items = level switch
        {
            "country" => (await countryService.GetAllAsync()).Where(c => c.IsActive).OrderBy(c => c.CountryName).Select(c => new { id = c.CountryId, name = c.CountryName }),
            "state" when parentId > 0 => (await stateService.GetByCountryAsync(parentId.Value)).Where(x => x.IsActive).OrderBy(x => x.StateName).Select(x => new { id = x.StateId, name = x.StateName }),
            "city" when parentId > 0 => (await cityService.GetByStateAsync(parentId.Value)).Where(x => x.IsActive).OrderBy(x => x.CityName).Select(x => new { id = x.CityId, name = x.CityName }),
            _ => []
        };
        return Json(items);
    }

    /// <summary>Wizard result: what was created, and what to do next.</summary>
    [HttpGet]
    public async Task<IActionResult> Onboarded(int id)
    {
        if (!IsSuperAdmin) return RedirectToAction(nameof(Index));
        var company = await dbContext.CompanyMasters.AsNoTracking().FirstOrDefaultAsync(c => c.CompanyId == id);
        if (company is null) return RedirectToAction(nameof(Index));
        ViewBag.Result = TempData["Onboarded"] is string json ? System.Text.Json.JsonSerializer.Deserialize<EMR.Web.ApiClients.CompanyOnboardResult>(json) : null;
        ViewBag.Branch = await dbContext.BranchMasters.AsNoTracking().Where(b => b.CompanyId == id && b.IsHOBranch)
            .Select(b => new { b.BranchId, b.BranchCode, b.BranchName }).FirstOrDefaultAsync();
        ViewBag.Admin = await dbContext.Users.AsNoTracking().Where(u => u.CompanyId == id).OrderBy(u => u.Id)
            .Select(u => new { u.Id, u.Username, u.FullName, u.Email }).FirstOrDefaultAsync();
        return View(company);
    }

    private int FirstStepWithError()
    {
        var steps = new (int Step, string[] Fields)[]
        {
            (1, [nameof(CompanyOnboardViewModel.CompanyCode), nameof(CompanyOnboardViewModel.CompanyName), nameof(CompanyOnboardViewModel.LegalName),
                 nameof(CompanyOnboardViewModel.RegistrationNumber), nameof(CompanyOnboardViewModel.GSTIN), nameof(CompanyOnboardViewModel.PAN),
                 nameof(CompanyOnboardViewModel.Email), nameof(CompanyOnboardViewModel.Phone), nameof(CompanyOnboardViewModel.Website),
                 nameof(CompanyOnboardViewModel.Address), nameof(CompanyOnboardViewModel.Pincode), nameof(CompanyOnboardViewModel.LogoFile)]),
            (2, [nameof(CompanyOnboardViewModel.BranchCode), nameof(CompanyOnboardViewModel.BranchName), nameof(CompanyOnboardViewModel.BranchAddress),
                 nameof(CompanyOnboardViewModel.BranchPincode)]),
            (3, [nameof(CompanyOnboardViewModel.HospitalName), nameof(CompanyOnboardViewModel.HospitalPhone), nameof(CompanyOnboardViewModel.HospitalEmail),
                 nameof(CompanyOnboardViewModel.OpdRegistrationValidityDays)]),
            (4, [nameof(CompanyOnboardViewModel.AdminUsername), nameof(CompanyOnboardViewModel.AdminEmail), nameof(CompanyOnboardViewModel.AdminFirstName), nameof(CompanyOnboardViewModel.AdminLastName),
                 nameof(CompanyOnboardViewModel.AdminEmail), nameof(CompanyOnboardViewModel.AdminPhone), nameof(CompanyOnboardViewModel.AdminEmployeeCode),
                 nameof(CompanyOnboardViewModel.AdminPassword), nameof(CompanyOnboardViewModel.AdminConfirmPassword)])
        };
        foreach (var (step, fields) in steps)
            if (fields.Any(f => ModelState.TryGetValue(f, out var e) && e.Errors.Count > 0)) return step;
        return 5;
    }

    private void DeleteLogoFile(string webPath)
    {
        try
        {
            var full = Path.Combine(webHostEnvironment.WebRootPath, webPath.TrimStart('/').Replace('/', Path.DirectorySeparatorChar));
            if (full.StartsWith(Path.Combine(webHostEnvironment.WebRootPath, "uploads", "company_logos")) && System.IO.File.Exists(full)) System.IO.File.Delete(full);
        }
        catch (IOException) { }
    }

    private async Task<string> SaveLogoFileAsync(IFormFile file)
    {
        var uploadsFolder = Path.Combine(webHostEnvironment.WebRootPath, "uploads", "company_logos");
        Directory.CreateDirectory(uploadsFolder);

        var uniqueFileName = $"{Guid.NewGuid():N}_{Path.GetFileName(file.FileName)}";
        var filePath = Path.Combine(uploadsFolder, uniqueFileName);

        using var fileStream = new FileStream(filePath, FileMode.Create);
        await file.CopyToAsync(fileStream);

        return $"/uploads/company_logos/{uniqueFileName}";
    }

    // ── Company > Copy master data (super admin, SQLScripts/2328, 2336): this company pulls masters from another ──

    /// <summary>The masters that can be copied, with the parents each one brings along.</summary>
    public static readonly (string Key, string Name, string Group, string Icon, string[] Needs)[] CopyEntities =
    [
        ("CATEGORY",      "Test Categories",            "Lab setup",    "bi-tags",               []),
        ("SUBCATEGORY",   "Test Sub-Categories",        "Lab setup",    "bi-diagram-2",          ["CATEGORY"]),
        ("SAMPLETYPE",    "Sample Types",               "Lab setup",    "bi-droplet",            []),
        ("METHOD",        "Test Methods",               "Lab setup",    "bi-gear-wide-connected", []),
        ("INVESTIGATION", "Investigations",             "Tests",        "bi-clipboard2-pulse",   ["CATEGORY", "SUBCATEGORY", "SAMPLETYPE", "METHOD"]),
        ("PROFILE",       "Investigation Profiles",     "Tests",        "bi-collection",         ["INVESTIGATION", "CATEGORY", "SUBCATEGORY", "SAMPLETYPE", "METHOD"]),
        ("REFRANGE",      "Reference Ranges",           "Tests",        "bi-arrows-expand",      ["INVESTIGATION", "CATEGORY", "SUBCATEGORY", "SAMPLETYPE", "METHOD"]),
        ("DESCRIPTIVE",   "Descriptive Test Templates", "Tests",        "bi-file-earmark-text",  ["INVESTIGATION", "CATEGORY", "SUBCATEGORY", "SAMPLETYPE", "METHOD"]),
        ("ORGANISM",      "Organisms",                  "Microbiology", "bi-bug",                []),
        ("ANTIBIOTIC",    "Antibiotics",                "Microbiology", "bi-capsule",            []),
        ("PANEL",         "Antibiotic Panels",          "Microbiology", "bi-grid-3x3-gap",       ["ANTIBIOTIC", "SAMPLETYPE"]),
        // script 2336: outside LAB - a shift / SMTP setting goes to this company's Head Office; SMTP / Video come from the
        // source company's Head Office
        ("SHIFT",         "Shifts",                     "Operations",   "bi-clock-history",      []),
        ("EMRTEMPLATE",   "EMR Templates",              "Clinical",     "bi-file-earmark-medical", []),
        ("SMTP",          "SMTP Email Settings",        "Communication", "bi-envelope-at",       []),
        ("VIDEO",         "Video Consultation Settings", "Communication", "bi-camera-video",     []),
    ];

    [HttpGet]
    public async Task<IActionResult> CopyMasters(int id)
    {
        if (!User.IsSuperAdmin()) return NotFound();
        var company = await dbContext.CompanyMasters.FirstOrDefaultAsync(x => x.CompanyId == id);
        if (company is null) return NotFound();

        ViewBag.Sources = await dbContext.CompanyMasters
            .Where(x => x.CompanyId != id && x.IsActive)
            .OrderBy(x => x.CompanyName)
            .Select(x => new { x.CompanyId, x.CompanyName, x.CompanyCode })
            .ToListAsync();
        return View(company);
    }

    /// <summary>Preview (rolled back) or copy: the result per master.</summary>
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> CopyMastersRun(int id, int sourceCompanyId, string[] entities, bool preview,
        [FromServices] EMR.Web.ApiClients.ICompanyCopyApiClient copyClient)
    {
        if (!User.IsSuperAdmin()) return NotFound();
        var keys = (entities ?? []).Where(e => CopyEntities.Any(c => c.Key == e)).Distinct().ToList();
        if (keys.Count == 0) return Json(new { success = false, message = "Choose at least one master to copy." });
        if (sourceCompanyId <= 0) return Json(new { success = false, message = "Choose the source company." });

        var (rows, error) = await copyClient.CopyLabMastersAsync(sourceCompanyId, id, keys, preview, User.GetUserId());
        if (error is not null) return Json(new { success = false, message = error });

        if (!preview)
        {
            var source = await dbContext.CompanyMasters.Where(x => x.CompanyId == sourceCompanyId).Select(x => x.CompanyName).FirstOrDefaultAsync();
            var target = await dbContext.CompanyMasters.Where(x => x.CompanyId == id).Select(x => x.CompanyName).FirstOrDefaultAsync();
            await auditLogService.LogAsync("Company", "CopyMasters",
                $"Copied masters from {source} into {target}: " + string.Join(", ", rows.Select(r => $"{r.Entity} {r.Copied} new / {r.Existing} existing")),
                branchId: User.GetCurrentBranchId());
        }
        return Json(new { success = true, preview, rows });
    }

    // ── Company > Remove data / Delete company (super admin, SQLScripts/2337) ──
    // TRANSACTIONS: patients, bills, payments, samples / results, accounting, logs, number counters (setup stays)
    // ALL: everything of the company (masters, settings, users, branches) - the company record stays
    // DELETE: ALL and the company record. Company 1 holds the data shared by every company and is never removed.
    public static readonly (string Key, string Name, string Note)[] PurgeLevels =
    [
        ("TRANSACTIONS", "Transactions only", "Patients, OPD / LAB bills, payments, samples and results, accounting entries, logs and number counters. Branches, users, masters and settings stay - the company starts clean."),
        ("ALL",          "Everything",        "Also masters, settings, users and branches. Only the company record stays."),
        ("DELETE",       "Delete the company", "Everything above and the company record itself."),
    ];

    [HttpGet]
    public async Task<IActionResult> RemoveData(int id, string? level)
    {
        if (!User.IsSuperAdmin()) return NotFound();
        var company = await dbContext.CompanyMasters.FirstOrDefaultAsync(x => x.CompanyId == id);
        if (company is null) return NotFound();
        ViewBag.Level = PurgeLevels.Any(l => l.Key == level) ? level : "TRANSACTIONS";
        ViewBag.Blocked = id == 1
            ? "This is the primary company: it holds the data shared by every company (roles, menus, specialities ...) and cannot be cleared or deleted."
            : null;
        ViewBag.OwnCompany = User.GetCompanyId() == id;
        return View(company);
    }

    /// <summary>Remove one branch and all its data (SQLScripts/2338): the same page, confirmed with the branch code.</summary>
    [HttpGet]
    public async Task<IActionResult> RemoveBranch(int id)
    {
        if (!User.IsSuperAdmin()) return NotFound();
        var branch = await dbContext.BranchMasters.AsNoTracking().FirstOrDefaultAsync(b => b.BranchId == id);
        if (branch is null) return NotFound();
        var company = await dbContext.CompanyMasters.FirstOrDefaultAsync(x => x.CompanyId == branch.CompanyId);
        if (company is null) return NotFound();
        ViewBag.Branch = branch;
        ViewBag.Level = "BRANCH";
        ViewBag.OwnCompany = false;
        ViewBag.Blocked = branch.IsHOBranch
            ? "This is the Head Office branch: it holds the company's settings and cannot be removed on its own. Delete the company instead."
            : User.GetCurrentBranchId() == id
                ? "You are signed in to this branch. Switch to another branch, then remove it."
                : null;
        return View("RemoveData", company);
    }

    /// <summary>Preview (rolled back) or remove: rows per table. A removal needs the company (or branch) code typed as confirmation.</summary>
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> RemoveDataRun(int id, string level, bool preview, string? confirmCode, int? branchId,
        [FromServices] EMR.Web.ApiClients.ICompanyPurgeApiClient purgeClient)
    {
        if (!User.IsSuperAdmin()) return NotFound();
        var isBranch = level == "BRANCH";
        if (!isBranch && !PurgeLevels.Any(l => l.Key == level)) return Json(new { success = false, message = "Choose what to remove." });
        var company = await dbContext.CompanyMasters.AsNoTracking().FirstOrDefaultAsync(x => x.CompanyId == id);
        if (company is null) return Json(new { success = false, message = "Company not found." });

        var branch = isBranch ? await dbContext.BranchMasters.AsNoTracking().FirstOrDefaultAsync(b => b.BranchId == branchId && b.CompanyId == id) : null;
        if (isBranch && branch is null) return Json(new { success = false, message = "Branch not found." });
        if (isBranch && branch!.IsHOBranch)   // the Head Office is never removed on its own (also refused by the procedure)
            return Json(new { success = false, message = "The Head Office branch cannot be removed. Delete the company instead." });
        if (isBranch && User.GetCurrentBranchId() == branch!.BranchId)
            return Json(new { success = false, message = "You are signed in to this branch. Switch to another branch, then remove it." });
        var expected = isBranch ? branch!.BranchCode : company.CompanyCode;
        if (!preview && !string.Equals((confirmCode ?? "").Trim(), expected, StringComparison.OrdinalIgnoreCase))
            return Json(new { success = false, message = $"Type the {(isBranch ? "branch" : "company")} code {expected} to confirm." });

        var (rows, error) = await purgeClient.PurgeAsync(id, level, preview, User.GetUserId(), branch?.BranchId);
        if (error is not null) return Json(new { success = false, message = error });

        if (!preview)
        {
            var what = isBranch
                ? $"Remove branch: {branch!.BranchName} ({branch.BranchCode}, #{branch.BranchId}) of {company.CompanyName}"
                : $"{PurgeLevels.First(l => l.Key == level).Name}: {company.CompanyName} ({company.CompanyCode}, #{company.CompanyId})";
            await auditLogService.LogAsync("Company", isBranch ? "RemoveBranch" : level == "DELETE" ? "DeleteCompany" : "RemoveCompanyData",
                $"{what} - {rows.Sum(r => r.Rows)} row(s): " + string.Join(", ", rows.Select(r => $"{r.TableName} {r.Rows}")),
                branchId: User.GetCurrentBranchId());
        }
        return Json(new
        {
            success = true, preview, rows,
            total = rows.Sum(r => r.Rows),
            redirect = preview ? null
                : level == "DELETE" ? Url.Action(nameof(Index))
                : isBranch ? Url.Action(nameof(Details), new { id }) : null
        });
    }
}
