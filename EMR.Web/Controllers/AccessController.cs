using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class AccessController(ApplicationDbContext dbContext, IAuditLogService auditLogService) : Controller
{
    public async Task<IActionResult> Index()
    {
        if (!CanManage())
        {
            return RedirectToAction("Index", "Dashboard");
        }

        var users = await dbContext.Users
            .Include(x => x.UserBranches)
                .ThenInclude(x => x.Branch)
            .Include(x => x.UserRoles)
                .ThenInclude(x => x.Role)
            .OrderBy(x => x.Username)
            .ToListAsync();

        var model = users.Select(user =>
        {
            var userRoleNames = user.UserRoles
                .Where(x => x.IsActive && x.Role != null)
                .Select(x => x.Role.Name)
                .Distinct()
                .ToList();

            var rolesSummary = userRoleNames.Count > 0 ? string.Join(", ", userRoleNames) : "No roles";

            var summary = user.UserBranches
                .Where(x => x.IsActive)
                .Select(x => $"{x.Branch.BranchName}: {rolesSummary}");

            return new AccessListItemViewModel
            {
                UserId = user.Id,
                Username = user.Username,
                FullName = user.FullName ?? user.Username,
                BranchRoleSummary = string.Join(" | ", summary)
            };
        }).ToList();

        return View(model);
    }

    [HttpGet]
    public async Task<IActionResult> Assign(int userId, int? branchId)
    {
        if (!CanManage())
        {
            return RedirectToAction("Index", "Dashboard");
        }

        var model = await BuildAssignmentModel(userId, branchId);
        if (model is null)
        {
            return NotFound();
        }

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Assign(UserRoleAssignmentViewModel model)
    {
        if (!CanManage())
        {
            return RedirectToAction("Index", "Dashboard");
        }

        var user = await dbContext.Users.FirstOrDefaultAsync(x => x.Id == model.UserId);
        if (user is null)
        {
            return NotFound();
        }

        var companyId = user.CompanyId > 0 ? user.CompanyId : (User.GetCompanyId() > 0 ? User.GetCompanyId() : 1);
        var companyRoleIds = await dbContext.Roles
            .Where(x => x.CompanyId == companyId)
            .Select(x => x.Id)
            .ToListAsync();

        var mappingsToRemove = await dbContext.UserRoles
            .Where(x => x.UserId == model.UserId && companyRoleIds.Contains(x.RoleId))
            .ToListAsync();

        dbContext.UserRoles.RemoveRange(mappingsToRemove);

        var selectedRoleIds = model.RoleOptions
            .Where(x => x.IsSelected)
            .Select(x => x.RoleId)
            .Distinct()
            .ToList();
        var newMappings = selectedRoleIds.Select(roleId => new UserRole
        {
            UserId = model.UserId,
            RoleId = roleId,
            IsActive = true,
            AssignedDate = DateTime.Now,
            AssignedBy = User.GetUserId(),
            CreatedBy = User.GetUserId(),
            CreatedDate = DateTime.Now,
            ModifiedBy = User.GetUserId(),
            ModifiedDate = DateTime.Now,
        });

        dbContext.UserRoles.AddRange(newMappings);
        await dbContext.SaveChangesAsync();

        await auditLogService.LogAsync(
            "MasterData",
            "Access.Assign",
            $"Updated role mapping for user #{model.UserId} in branch #{model.BranchId}. Roles: {string.Join(",", selectedRoleIds)}",
            model.UserId,
            model.BranchId);

        TempData["Success"] = "Branch-wise roles updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    private async Task<UserRoleAssignmentViewModel?> BuildAssignmentModel(int userId, int? branchId)
    {
        var user = await dbContext.Users
            .Include(x => x.UserBranches.Where(b => b.IsActive))
                .ThenInclude(x => x.Branch)
            .Include(x => x.UserRoles)
            .FirstOrDefaultAsync(x => x.Id == userId);

        if (user is null)
        {
            return null;
        }

        var branchOptions = user.UserBranches
            .Where(x => x.Branch.IsActive)
            .Select(x => new SelectListItem(
                string.IsNullOrWhiteSpace(x.Branch.BranchCode)
                    ? x.Branch.BranchName
                    : $"{x.Branch.BranchCode} - {x.Branch.BranchName}",
                x.BranchId.ToString()))
            .ToList();

        var selectedBranchId = branchId ?? user.UserBranches.FirstOrDefault()?.BranchId ?? 0;
        var companyId = user.CompanyId > 0 ? user.CompanyId : (User.GetCompanyId() > 0 ? User.GetCompanyId() : 1);
        var companyRoles = await dbContext.Roles
            .Where(x => x.CompanyId == companyId)
            .OrderBy(x => x.Name)
            .ToListAsync();

        var assignedRoleIds = user.UserRoles
            .Where(x => x.IsActive)
            .Select(x => x.RoleId)
            .ToHashSet();

        return new UserRoleAssignmentViewModel
        {
            UserId = user.Id,
            Username = user.Username,
            FullName = user.FullName ?? user.Username,
            BranchId = selectedBranchId,
            UserBranchOptions = branchOptions,
            RoleOptions = companyRoles.Select(role => new RoleOptionViewModel
            {
                RoleId = role.Id,
                RoleName = role.Name,
                IsSelected = assignedRoleIds.Contains(role.Id)
            }).ToList(),
            SelectedRoleIds = companyRoles
                .Where(role => assignedRoleIds.Contains(role.Id))
                .Select(role => role.Id)
                .ToList()
        };
    }

    private bool CanManage() => true; // TODO: re-enable role check when authorization is implemented
}
