using System.Security.Claims;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

public class AccountController(
    ApplicationDbContext dbContext,
    IPasswordHasherService passwordHasherService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    [AllowAnonymous]
    public IActionResult Login()
    {
        if (User.Identity?.IsAuthenticated == true)
        {
            return RedirectToAction("Index", "Dashboard");
        }

        return View(new LoginViewModel());
    }

    [HttpPost]
    [AllowAnonymous]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Login(LoginViewModel model)
    {
        if (!ModelState.IsValid)
        {
            return View(model);
        }

        var user = await dbContext.Users
            .Include(x => x.UserBranches.Where(b => b.IsActive))
                .ThenInclude(x => x.Branch)
            .FirstOrDefaultAsync(x => x.Username == model.Username);

        if (user is null || !passwordHasherService.VerifyPassword(model.Password, user.PasswordHash))
        {
            await auditLogService.LogAsync("AuthFailure", "Login", $"Failed login attempt for username: {model.Username}");
            ModelState.AddModelError(string.Empty, "Invalid username or password.");
            return View(model);
        }

        if (!user.IsActive || user.IsLockedOut)
        {
            await auditLogService.LogAsync("AuthFailure", "Login", $"Inactive/locked user attempted login: {user.Username}", user.Id);
            ModelState.AddModelError(string.Empty, "User is inactive or locked out. Contact administrator.");
            return View(model);
        }

        var activeBranches = user.UserBranches
            .Where(x => x.Branch.IsActive)
            .Select(x => x.Branch)
            .DistinctBy(x => x.BranchId)
            .ToList();

        if (activeBranches.Count == 0)
        {
            await auditLogService.LogAsync("AuthFailure", "Login", $"No branch mapping for user: {user.Username}", user.Id);
            ModelState.AddModelError(string.Empty, "No active branch mapping found for this user.");
            return View(model);
        }

        var isSuperAdmin = IsSuperAdminUser(user);

        if (!isSuperAdmin)
        {
            var hasAnyActiveRole = await dbContext.UserRoles
                .Join(dbContext.Roles,
                    ur => ur.RoleId,
                    r => r.Id,
                    (ur, r) => new { ur.UserId, ur.IsActive, r.Name })
                .AnyAsync(x => x.UserId == user.Id && x.IsActive && !string.IsNullOrWhiteSpace(x.Name));

            if (!hasAnyActiveRole)
            {
                await auditLogService.LogAsync("AuthFailure", "Login", $"No active roles for user: {user.Username}", user.Id);
                ModelState.AddModelError(string.Empty, "No active role mapping found for this user.");
                return View(model);
            }
        }

        await SignInUserAsync(user, null, isSuperAdmin, model.RememberMe);

        if (activeBranches.Count == 1)
        {
            return await CompleteBranchSelection(user.Id, activeBranches[0].BranchId, model.RememberMe);
        }

        await auditLogService.LogAsync("AuthSuccess", "Login", "Credentials verified; awaiting branch selection.", user.Id);

        return RedirectToAction(nameof(SelectBranch));
    }

    [HttpGet]
    [Authorize]
    public async Task<IActionResult> SelectBranch()
    {
        var userIdClaim = User.FindFirstValue(ClaimTypes.NameIdentifier);
        if (!int.TryParse(userIdClaim, out var userId))
        {
            return RedirectToAction(nameof(Login));
        }

        var user = await dbContext.Users
            .Include(x => x.UserBranches.Where(b => b.IsActive))
                .ThenInclude(x => x.Branch)
            .FirstOrDefaultAsync(x => x.Id == userId);

        if (user is null)
        {
            return RedirectToAction(nameof(Login));
        }

        var branchOptions = user.UserBranches
            .Where(x => x.Branch.IsActive)
            .Select(x => new SelectListItem(
                $"{x.Branch.BranchCode} - {x.Branch.BranchName}",
                x.BranchId.ToString()))
            .ToList();

        var viewModel = new BranchSelectionViewModel
        {
            DisplayName = string.IsNullOrWhiteSpace(user.FullName) ? user.Username : user.FullName,
            Branches = branchOptions
        };

        return View(viewModel);
    }

    [HttpPost]
    [Authorize]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SelectBranch(BranchSelectionViewModel model)
    {
        var userIdClaim = User.FindFirstValue(ClaimTypes.NameIdentifier);
        if (!int.TryParse(userIdClaim, out var userId))
        {
            return RedirectToAction(nameof(Login));
        }

        var user = await dbContext.Users.FindAsync(userId);
        if (user is null)
        {
            return RedirectToAction(nameof(Login));
        }

        return await CompleteBranchSelection(userId, model.BranchId, false);
    }

    [HttpPost]
    [Authorize]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Logout()
    {
        await auditLogService.LogAsync("Auth", "Logout", "User logged out.");
        await HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
        return RedirectToAction(nameof(Login));
    }

    [HttpGet]
    [Authorize]
    public async Task<IActionResult> SessionTimeoutLogout()
    {
        await HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
        TempData["Warning"] = "Session expired due to inactivity. Please login again.";
        return RedirectToAction(nameof(Login));
    }

    private async Task<IActionResult> CompleteBranchSelection(int userId, int branchId, bool rememberMe)
    {
        var user = await dbContext.Users.FirstOrDefaultAsync(x => x.Id == userId);
        if (user is null)
        {
            return RedirectToAction(nameof(Login));
        }

        // Fetch branch validation then roles sequentially (EF DbContext is not thread-safe)
        var allowedBranch = await dbContext.UserBranches
            .Include(x => x.Branch)
            .FirstOrDefaultAsync(x => x.UserId == userId && x.BranchId == branchId && x.IsActive && x.Branch.IsActive);

        if (allowedBranch is null)
        {
            _ = auditLogService.LogAsync("AuthFailure", "SelectBranch", $"Invalid branch selection: {branchId}", userId, branchId);
            TempData["Error"] = "Invalid branch selection.";
            return RedirectToAction(nameof(SelectBranch));
        }

        var roleNames = await dbContext.UserRoles
            .Where(x => x.UserId == userId && x.IsActive)
            .Join(dbContext.Roles,
                userRole => userRole.RoleId,
                role => role.Id,
                (userRole, role) => role.Name)
            .Distinct()
            .ToListAsync();

        var isSuperAdmin = IsSuperAdminUser(user);

        if (!isSuperAdmin && roleNames.Count == 0)
        {
            await HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
            TempData["Error"] = "No active role mapping found for selected branch.";
            return RedirectToAction(nameof(Login));
        }

        // Sign in immediately, then fire-and-forget the DB write + audit log
        // so the user is not blocked waiting for non-critical DB operations
        if (isSuperAdmin || roleNames.Count <= 1)
        {
            var activeRole = isSuperAdmin ? "Administrator" : (roleNames.Count == 1 ? roleNames[0] : null);
            await SignInUserAsync(user, allowedBranch.Branch, isSuperAdmin, rememberMe, roleNames, activeRole);
            _ = FinalizeLoginAsync(user, allowedBranch, userId);
            return RedirectToAction("Index", "Dashboard");
        }

        // Multiple roles — establish session then let user pick role
        await SignInUserAsync(user, allowedBranch.Branch, isSuperAdmin, rememberMe, roleNames, null);
        _ = FinalizeLoginAsync(user, allowedBranch, userId);
        TempData["RememberMe"] = rememberMe;
        return RedirectToAction(nameof(SelectRole));
    }

    private async Task FinalizeLoginAsync(User user, UserBranch allowedBranch, int userId)
    {
        try
        {
            user.LastLoginDate = DateTime.UtcNow;
            user.FailedLoginAttempts = 0;
            user.LastModifiedDate = DateTime.UtcNow;
            await dbContext.SaveChangesAsync();
            await auditLogService.LogAsync(
                "AuthSuccess",
                "SelectBranch",
                $"User session initialized for branch: {allowedBranch.Branch.BranchName}",
                userId,
                allowedBranch.BranchId);
        }
        catch
        {
            // Non-critical — swallow so it never crashes the session
        }
    }

    [HttpGet]
    [Authorize]
    public async Task<IActionResult> SelectRole()
    {
        var userId = User.GetUserId();
        var branchId = User.GetCurrentBranchId();

        if (userId == 0 || branchId is null)
        {
            return RedirectToAction(nameof(Login));
        }

        var roleNames = await dbContext.UserRoles
            .Where(x => x.UserId == userId && x.IsActive)
            .Join(dbContext.Roles,
                ur => ur.RoleId,
                r => r.Id,
                (ur, r) => new { r.Id, r.Name })
            .Distinct()
            .OrderBy(x => x.Name)
            .ToListAsync();

        if (!User.IsSuperAdmin() && roleNames.Count == 0)
        {
            await HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
            TempData["Error"] = "Role mapping not found for selected branch.";
            return RedirectToAction(nameof(Login));
        }

        if (roleNames.Count == 1)
        {
            // Only one role — auto-apply and skip the picker
            return await ApplyRoleSelection(userId, branchId.Value, roleNames[0].Name);
        }

        var displayName = User.FindFirstValue("DisplayName") ?? User.Identity?.Name ?? string.Empty;
        var branchName = User.FindFirstValue("BranchName") ?? string.Empty;

        var model = new RoleSelectionViewModel
        {
            DisplayName = displayName,
            BranchName = branchName,
            ProfilePicturePath = User.FindFirstValue("ProfilePicturePath"),
            RememberMe = TempData["RememberMe"] is bool rm && rm,
            Roles = roleNames.Select(r => new RoleCardItem
            {
                Id = r.Id,
                Name = r.Name,
                Icon = MapRoleIcon(r.Name)
            }).ToList()
        };

        return View(model);
    }

    [HttpPost]
    [Authorize]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SelectRole(string selectedRole, bool rememberMe)
    {
        var userId = User.GetUserId();
        var branchId = User.GetCurrentBranchId();

        if (userId == 0 || branchId is null || string.IsNullOrWhiteSpace(selectedRole))
        {
            return RedirectToAction(nameof(Login));
        }

        return await ApplyRoleSelection(userId, branchId.Value, selectedRole, rememberMe);
    }

    [HttpGet]
    [Authorize]
    public Task<IActionResult> SwitchRole()
    {
        TempData.Remove("RememberMe");
        return Task.FromResult<IActionResult>(RedirectToAction(nameof(SelectRole)));
    }

    private async Task<IActionResult> ApplyRoleSelection(int userId, int branchId, string selectedRole, bool rememberMe = false)
    {
        var user = await dbContext.Users.FirstOrDefaultAsync(x => x.Id == userId);
        if (user is null) return RedirectToAction(nameof(Login));

        var allowedBranch = await dbContext.UserBranches
            .Include(x => x.Branch)
            .FirstOrDefaultAsync(x => x.UserId == userId && x.BranchId == branchId && x.IsActive);

        if (allowedBranch is null) return RedirectToAction(nameof(Login));

        var allRoleNames = await dbContext.UserRoles
            .Where(x => x.UserId == userId && x.IsActive)
            .Join(dbContext.Roles, ur => ur.RoleId, r => r.Id, (ur, r) => r.Name)
            .Distinct()
            .ToListAsync();

        var isSuperAdmin = IsSuperAdminUser(user);

        if (!isSuperAdmin && allRoleNames.Count == 0)
        {
            await HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
            TempData["Error"] = "Role mapping not found for selected branch.";
            return RedirectToAction(nameof(Login));
        }

        if (!isSuperAdmin && !allRoleNames.Contains(selectedRole, StringComparer.OrdinalIgnoreCase))
        {
            await HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
            TempData["Error"] = "Invalid role selection. Please login again.";
            return RedirectToAction(nameof(Login));
        }

        await SignInUserAsync(user, allowedBranch.Branch, isSuperAdmin, rememberMe, allRoleNames, selectedRole);

        await auditLogService.LogAsync("Auth", "SelectRole", $"Active role set to: {selectedRole}", userId, branchId);
        return RedirectToAction("Index", "Dashboard");
    }

    private static string MapRoleIcon(string roleName) => roleName.ToLowerInvariant() switch
    {
        var r when r.Contains("admin") => "bi-shield-lock-fill",
        var r when r.Contains("doctor") || r.Contains("physician") => "bi-heart-pulse-fill",
        var r when r.Contains("nurse") => "bi-bandaid-fill",
        var r when r.Contains("reception") => "bi-headset",
        var r when r.Contains("pharma") => "bi-capsule",
        var r when r.Contains("lab") => "bi-eyedropper",
        var r when r.Contains("account") || r.Contains("cashier") => "bi-cash-coin",
        _ => "bi-person-badge-fill"
    };

    private async Task SignInUserAsync(User user, BranchMaster? branch, bool isSuperAdmin, bool rememberMe, List<string>? roleNames = null, string? activeRole = null)
    {
        await HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);

        var claims = new List<Claim>
        {
            new(ClaimTypes.NameIdentifier, user.Id.ToString()),
            new(ClaimTypes.Name, user.Username),
            new("DisplayName", string.IsNullOrWhiteSpace(user.FullName) ? user.Username : user.FullName),
            new("IsSuperAdmin", isSuperAdmin ? "true" : "false")
        };

        if (!string.IsNullOrWhiteSpace(user.ProfilePicturePath))
        {
            claims.Add(new Claim("ProfilePicturePath", user.ProfilePicturePath));
        }

        if (branch is not null)
        {
            claims.Add(new Claim("BranchId", branch.BranchId.ToString()));
            claims.Add(new Claim("BranchName", branch.BranchName));
            claims.Add(new Claim("BranchCode", branch.BranchCode));
        }

        if (!string.IsNullOrWhiteSpace(activeRole))
        {
            claims.Add(new Claim("ActiveRole", activeRole));
        }

        foreach (var role in roleNames ?? new List<string>())
        {
            claims.Add(new Claim(ClaimTypes.Role, role));
        }

        if (isSuperAdmin)
        {
            claims.Add(new Claim(ClaimTypes.Role, "SuperAdmin"));
            claims.Add(new Claim(ClaimTypes.Role, "Administrator"));
        }

        var identity = new ClaimsIdentity(claims, CookieAuthenticationDefaults.AuthenticationScheme);
        var principal = new ClaimsPrincipal(identity);

        var authProperties = new AuthenticationProperties
        {
            IsPersistent = rememberMe,
            ExpiresUtc = DateTimeOffset.UtcNow.AddHours(8)
        };

        await HttpContext.SignInAsync(CookieAuthenticationDefaults.AuthenticationScheme, principal, authProperties);
    }

    private static bool IsSuperAdminUser(User user)
    {
        return string.Equals(user.Username, "admin", StringComparison.OrdinalIgnoreCase) ||
               string.Equals(user.Role, "Super Admin", StringComparison.OrdinalIgnoreCase) ||
               string.Equals(user.Role, "SuperAdmin", StringComparison.OrdinalIgnoreCase);
    }
}

