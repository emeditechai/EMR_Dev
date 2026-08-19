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
}
