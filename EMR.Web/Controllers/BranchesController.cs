using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class BranchesController(ApplicationDbContext dbContext, IAuditLogService auditLogService) : Controller
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
}
