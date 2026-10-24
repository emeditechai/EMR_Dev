using System.Security.Claims;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using EMR.Shared.Security;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

// Sign-in, branch/role choice and sign-out come before any permission can be known.
[PublicEndpoint]
public class AccountController(
    ApplicationDbContext dbContext,
    IPasswordHasherService passwordHasherService,
    IAuditLogService auditLogService,
    ILoginSecurity loginSecurity,
    IHomeDashboardService home) : Controller
{
    /// <summary>Sign-in attempts per client address per minute (clinics share one address, so this is generous).</summary>
    public const string SignInRateLimit = "signin";

    /// <summary>"Forgot password?" requests and reset submits per client address per 15 minutes.</summary>
    public const string PasswordResetRateLimit = "pwreset";

    [HttpGet]
    [Authorize]
    public IActionResult AccessDenied(string? returnUrl, string? page, string? control)
    {
        ViewData["Title"] = "Access denied";
        ViewData["ReturnUrl"] = returnUrl;
        ViewData["Page"] = page;
        ViewData["Control"] = control;
        Response.StatusCode = StatusCodes.Status403Forbidden;
        return View();
    }

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
    [Microsoft.AspNetCore.RateLimiting.EnableRateLimiting(SignInRateLimit)]
    public async Task<IActionResult> Login(LoginViewModel model)
    {
        if (!ModelState.IsValid)
        {
            return View(model);
        }

        // Sign-in by e-mail (SQLScripts/2307). An e-mail is unique for new and changed users; a few older records may
        // still share one - then the account whose password matches is the one signing in.
        var email = model.Email.Trim().ToLower();
        var candidates = await dbContext.Users
            .Include(x => x.UserBranches.Where(b => b.IsActive))
                .ThenInclude(x => x.Branch)
            .Where(x => x.Email != null && x.Email.Trim().ToLower() == email)
            .ToListAsync();
        var user = candidates.Count == 1 ? candidates[0]
                 : candidates.FirstOrDefault(x => passwordHasherService.VerifyPassword(model.Password, x.PasswordHash));

        // Too many wrong passwords lock the account for a while (Users.Lockout_Until), whatever is typed next.
        if (user is not null && await loginSecurity.LockedUntilAsync(user.Id) is { } lockedUntil)
        {
            await auditLogService.LogAsync("AuthFailure", "Login", $"Sign-in refused, account temporarily locked: {user.Username}", user.Id);
            ModelState.AddModelError(string.Empty, $"Your account is locked after too many wrong passwords. Try again after {lockedUntil:hh:mm tt}, or ask the administrator to unlock it.");
            return View(model);
        }

        if (user is null || !passwordHasherService.VerifyPassword(model.Password, user.PasswordHash))
        {
            await auditLogService.LogAsync("AuthFailure", "Login", $"Failed login attempt for e-mail: {model.Email}");
            var failure = user is null ? default : await loginSecurity.RecordFailureDetailAsync(user.Id);
            if (failure.LockedUntil is { } nowLocked)
            {
                await auditLogService.LogAsync("AuthFailure", "Login", $"Account temporarily locked after repeated wrong passwords: {user!.Username}", user.Id);
                ModelState.AddModelError(string.Empty, $"Too many wrong passwords. Your account is locked for 10 minutes - try again after {nowLocked:hh:mm tt}, or ask the administrator to unlock it.");
                return View(model);
            }
            // Hospital Settings > Login Retry Count above 0: say how many tries are left before the lock
            ModelState.AddModelError(string.Empty, failure.AttemptsLeft is { } left
                ? $"Invalid e-mail or password. {left} attempt{(left == 1 ? "" : "s")} left before the account is locked for 10 minutes."
                : "Invalid e-mail or password.");
            return View(model);
        }

        if (!user.IsActive || user.IsLockedOut)
        {
            await auditLogService.LogAsync("AuthFailure", "Login", $"Inactive/locked user attempted login: {user.Username}", user.Id);
            ModelState.AddModelError(string.Empty, "User is inactive or locked out. Contact administrator.");
            return View(model);
        }

        await loginSecurity.RecordSuccessAsync(user.Id);

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
    public Task<IActionResult> SelectBranch() => BranchSelectionView(isSwitch: false);

    /// <summary>
    /// Profile menu > Switch Branch: move the signed-in session to another of the user's branches without signing in
    /// again. The sign-in cookie is re-issued for the new branch (same "remember me"); the active role is kept when the
    /// user holds it there, otherwise the role is chosen as at sign-in.
    /// </summary>
    [HttpGet]
    [Authorize]
    public Task<IActionResult> SwitchBranch() => BranchSelectionView(isSwitch: true);

    private async Task<IActionResult> BranchSelectionView(bool isSwitch)
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

        var currentBranchId = User.GetCurrentBranchId();
        if (isSwitch && branchOptions.Count <= 1)
        {
            TempData["Warning"] = "You have access to only one branch.";
            return RedirectToAction("Index", "Dashboard");
        }

        // at sign-in the branch the user last worked in is pre-selected (none on a first sign-in)
        var lastBranchId = isSwitch ? null : await LastBranchIdAsync(userId, branchOptions.Select(x => int.Parse(x.Value)));

        var viewModel = new BranchSelectionViewModel
        {
            DisplayName = string.IsNullOrWhiteSpace(user.FullName) ? user.Username : user.FullName,
            Branches = branchOptions,
            IsSwitch = isSwitch && currentBranchId.HasValue,
            CurrentBranchName = User.FindFirstValue("BranchName"),
            BranchId = isSwitch ? currentBranchId ?? 0 : lastBranchId ?? 0,
            IsLastUsedBranch = lastBranchId.HasValue
        };

        return View("SelectBranch", viewModel);
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

        var currentBranchId = User.GetCurrentBranchId();
        if (model.IsSwitch && currentBranchId.HasValue)
        {
            if (model.BranchId == currentBranchId.Value)
                return RedirectToAction("Index", "Dashboard");   // nothing to switch

            // same session: keep "remember me" and, where the user holds it there, the active role
            var current = await HttpContext.AuthenticateAsync(CookieAuthenticationDefaults.AuthenticationScheme);
            return await CompleteBranchSelection(userId, model.BranchId, current.Properties?.IsPersistent ?? false,
                switchedFrom: User.FindFirstValue("BranchName"), preferredRole: User.GetActiveRole());
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

    private async Task<IActionResult> CompleteBranchSelection(int userId, int branchId, bool rememberMe,
        string? switchedFrom = null, string? preferredRole = null)
    {
        var isSwitch = switchedFrom is not null;
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
            return RedirectToAction(isSwitch ? nameof(SwitchBranch) : nameof(SelectBranch));
        }

        var roleNames = await dbContext.UserRoles
            .Where(x => x.UserId == userId && x.IsActive && (x.Branch_ID == null || x.Branch_ID == branchId))
            .Join(dbContext.Roles,
                userRole => userRole.RoleId,
                role => role.Id,
                (userRole, role) => role.Name)
            .Distinct()
            .ToListAsync();

        var isSuperAdmin = IsSuperAdminUser(user);

        if (!isSuperAdmin && roleNames.Count == 0)
        {
            if (isSwitch)
            {
                // a switch must never end the session: stay in the current branch
                TempData["Error"] = $"You have no active role in {allowedBranch.Branch.BranchName}. Ask an administrator to add one in User Master.";
                return RedirectToAction("Index", "Dashboard");
            }
            await HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
            TempData["Error"] = "No active role mapping found for selected branch.";
            return RedirectToAction(nameof(Login));
        }

        if (isSwitch)
        {
            // keep the role the user is working in when they hold it in the new branch
            var keepRole = isSuperAdmin ? "Administrator"
                : roleNames.Count == 1 ? roleNames[0]
                : roleNames.FirstOrDefault(r => string.Equals(r, preferredRole, StringComparison.OrdinalIgnoreCase));
            await SignInUserAsync(user, allowedBranch.Branch, isSuperAdmin, rememberMe, roleNames, keepRole);
            await RememberBranchAsync(userId, branchId, keepRole);
            await auditLogService.LogAsync("Auth", "SwitchBranch",
                $"Switched branch from {switchedFrom} to {allowedBranch.Branch.BranchName}" + (keepRole is null ? "" : $" (role: {keepRole})"),
                userId, branchId);
            if (keepRole is null)
            {
                TempData["RememberMe"] = rememberMe;
                return RedirectToAction(nameof(SelectRole));
            }
            TempData["Success"] = $"Switched to {allowedBranch.Branch.BranchName}.";
            return RedirectToAction("Index", "Dashboard");
        }

        // Sign in, then record the login. This is awaited on purpose: fired and forgotten it ran after the
        // request scope (and its DbContext) was disposed, so the last-login stamp and the branch audit row
        // were silently lost - which is what the dashboard reads.
        if (isSuperAdmin || roleNames.Count <= 1)
        {
            var activeRole = isSuperAdmin ? "Administrator" : (roleNames.Count == 1 ? roleNames[0] : null);
            await SignInUserAsync(user, allowedBranch.Branch, isSuperAdmin, rememberMe, roleNames, activeRole);
            await FinalizeLoginAsync(user, allowedBranch, userId, activeRole);
            return RedirectToAction("Index", "Dashboard");
        }

        // Multiple roles — establish session then let user pick role
        await SignInUserAsync(user, allowedBranch.Branch, isSuperAdmin, rememberMe, roleNames, null);
        await FinalizeLoginAsync(user, allowedBranch, userId);
        TempData["RememberMe"] = rememberMe;
        return RedirectToAction(nameof(SelectRole));
    }

    private async Task FinalizeLoginAsync(User user, UserBranch allowedBranch, int userId, string? activeRole = null)
    {
        await RememberBranchAsync(userId, allowedBranch.BranchId, activeRole);
        try
        {
            user.LastLoginDate = DateTime.Now;
            user.FailedLoginAttempts = 0;
            user.LastModifiedDate = DateTime.Now;
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
            .Where(x => x.UserId == userId && x.IsActive && (x.Branch_ID == null || x.Branch_ID == branchId))
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

        // the role the user last worked in at this branch is pre-selected (none on a first sign-in)
        var lastRole = await LastRoleNameAsync(userId, branchId.Value);

        var model = new RoleSelectionViewModel
        {
            LastRoleName = roleNames.Select(r => r.Name).FirstOrDefault(n => string.Equals(n, lastRole, StringComparison.OrdinalIgnoreCase)),
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

    /// <summary>
    /// Select Role: what the signed-in user can do in the current branch with one of their roles there - the modules,
    /// screens and key actions the menu will offer (same catalogue and permissions as the navbar). Only for a role the
    /// user holds in the branch. Named under /Account/SelectRole... so the session guard (Program.cs) lets it through
    /// before a role is chosen.
    /// </summary>
    [HttpGet]
    [Authorize]
    public async Task<IActionResult> SelectRoleSummaryJson(string role)
    {
        var userId = User.GetUserId();
        var branchId = User.GetCurrentBranchId();
        if (userId == 0 || branchId is null || string.IsNullOrWhiteSpace(role)) return BadRequest();

        var holds = await dbContext.UserRoles
            .Where(x => x.UserId == userId && x.IsActive && (x.Branch_ID == null || x.Branch_ID == branchId))
            .Join(dbContext.Roles, ur => ur.RoleId, r => r.Id, (ur, r) => r.Name)
            .AnyAsync(n => n == role);
        if (!holds && !User.IsSuperAdmin()) return NotFound();

        var subject = new PermissionSubject(userId, branchId.Value, User.GetCompanyId(), role);
        return Json(await home.GetRoleAccessSummaryAsync(HttpContext, subject));
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
            .Where(x => x.UserId == userId && x.IsActive && (x.Branch_ID == null || x.Branch_ID == branchId))
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
        await RememberBranchAsync(userId, branchId, selectedRole);

        await auditLogService.LogAsync("Auth", "SelectRole", $"Active role set to: {selectedRole}", userId, branchId);
        return RedirectToAction("Index", "Dashboard");
    }

    // ---- Change password (profile menu / Home) ----------------------------------------------------------------------

    [HttpGet]
    [Authorize]
    public async Task<IActionResult> ChangePassword()
    {
        var userId = User.GetUserId();
        var user = userId > 0 ? await dbContext.Users.FindAsync(userId) : null;
        if (user is null) return RedirectToAction(nameof(Login));
        return View(new ChangePasswordViewModel { PasswordLastChanged = user.PasswordLastChanged });
    }

    [HttpPost]
    [Authorize]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ChangePassword(ChangePasswordViewModel model)
    {
        var userId = User.GetUserId();
        var user = userId > 0 ? await dbContext.Users.FindAsync(userId) : null;
        if (user is null) return RedirectToAction(nameof(Login));
        model.PasswordLastChanged = user.PasswordLastChanged;

        if (!ModelState.IsValid) return View(model);

        if (!passwordHasherService.VerifyPassword(model.CurrentPassword, user.PasswordHash))
        {
            await auditLogService.LogAsync("AuthFailure", "ChangePassword", "Password change refused: the current password was wrong.", user.Id);
            ModelState.AddModelError(nameof(model.CurrentPassword), "The current password is not correct.");
            return View(model);
        }
        if (passwordHasherService.VerifyPassword(model.NewPassword, user.PasswordHash))
        {
            ModelState.AddModelError(nameof(model.NewPassword), "Choose a password different from the current one.");
            return View(model);
        }

        var (hash, salt) = passwordHasherService.HashPassword(model.NewPassword);
        user.PasswordHash = hash;
        user.Salt = salt;
        user.PasswordLastChanged = DateTime.Now;
        user.MustChangePassword = false;
        user.LastModifiedDate = DateTime.Now;
        await dbContext.SaveChangesAsync();

        await auditLogService.LogAsync("Auth", "ChangePassword", "Password changed by the user.", user.Id);
        TempData["Success"] = "Your password has been changed.";
        return RedirectToAction("Index", "Dashboard");
    }

    // ---- Forgot password (Login page; SQLScripts/2293) ------------------------------------------------------------------
    // The answer is the same whether or not the account exists, and the mail is sent after the response, so neither the
    // message nor the response time tells anyone which user names are real.

    [HttpGet]
    [AllowAnonymous]
    public IActionResult ForgotPassword()
    {
        if (User.Identity?.IsAuthenticated == true) return RedirectToAction("Index", "Dashboard");
        return View(new ForgotPasswordViewModel());
    }

    [HttpPost]
    [AllowAnonymous]
    [ValidateAntiForgeryToken]
    [Microsoft.AspNetCore.RateLimiting.EnableRateLimiting(PasswordResetRateLimit)]
    public IActionResult ForgotPassword(ForgotPasswordViewModel model, [FromServices] IServiceScopeFactory scopes, [FromServices] ILogger<AccountController> logger)
    {
        if (!ModelState.IsValid) return View(model);

        var key = model.UserNameOrEmail.Trim();
        var ip = HttpContext.Connection.RemoteIpAddress?.ToString();
        var baseUrl = $"{Request.Scheme}://{Request.Host}{Request.PathBase}";
        _ = Task.Run(async () =>
        {
            try
            {
                using var scope = scopes.CreateScope();
                await scope.ServiceProvider.GetRequiredService<IPasswordResetService>().RequestAsync(key, ip, baseUrl);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Password reset request failed");
            }
        });

        TempData["ResetRequested"] = key;
        return RedirectToAction(nameof(ForgotPasswordSent));
    }

    [HttpGet]
    [AllowAnonymous]
    public IActionResult ForgotPasswordSent()
    {
        if (TempData["ResetRequested"] is not string key) return RedirectToAction(nameof(ForgotPassword));
        ViewData["Requested"] = key;
        return View();
    }

    [HttpGet]
    [AllowAnonymous]
    public async Task<IActionResult> ResetPassword(string? token, [FromServices] IPasswordResetService resets)
    {
        // the token is in the address: keep it out of the Referer of anything this page loads
        Response.Headers["Referrer-Policy"] = "no-referrer";
        if (User.Identity?.IsAuthenticated == true)
        {
            await HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
        }
        var userName = await resets.ValidateAsync(token);
        if (userName is null) return View("ResetPasswordInvalid");
        return View(new ResetPasswordViewModel { Token = token!, UserName = userName });
    }

    [HttpPost]
    [AllowAnonymous]
    [ValidateAntiForgeryToken]
    [Microsoft.AspNetCore.RateLimiting.EnableRateLimiting(PasswordResetRateLimit)]
    public async Task<IActionResult> ResetPassword(ResetPasswordViewModel model, [FromServices] IPasswordResetService resets)
    {
        Response.Headers["Referrer-Policy"] = "no-referrer";
        var userName = await resets.ValidateAsync(model.Token);
        if (userName is null) return View("ResetPasswordInvalid");
        model.UserName = userName;
        if (!ModelState.IsValid) return View(model);

        if (!await resets.ResetAsync(model.Token, model.NewPassword, HttpContext.Connection.RemoteIpAddress?.ToString()))
            return View("ResetPasswordInvalid");

        TempData["AuthMessage"] = "Your password has been reset. Sign in with your new password.";
        return RedirectToAction(nameof(Login));
    }

    // ---- Last branch / role (UserBranchLastLogin, script 2187) --------------------------------------------------------
    // A convenience only: a failure here never blocks or changes a sign-in.

    /// <summary>Records that the user is working in the branch now, and the role when known (null keeps the last one).</summary>
    private async Task RememberBranchAsync(int userId, int branchId, string? roleName)
    {
        try
        {
            await dbContext.Database.ExecuteSqlInterpolatedAsync(
                $"EXEC dbo.usp_UserBranchLastLogin_Save @UserId = {userId}, @BranchId = {branchId}, @RoleName = {roleName}");
        }
        catch
        {
            // non-critical
        }
    }

    /// <summary>The branch, among those offered, that the user last worked in; null when there is none (first sign-in).</summary>
    private async Task<int?> LastBranchIdAsync(int userId, IEnumerable<int> offeredBranchIds)
    {
        try
        {
            var offered = offeredBranchIds.ToHashSet();
            var recent = await dbContext.Database
                .SqlQuery<int>($"SELECT BranchId AS Value FROM dbo.UserBranchLastLogin WHERE UserId = {userId} ORDER BY LastLoginDate DESC")
                .ToListAsync();
            return recent.Where(offered.Contains).Select(id => (int?)id).FirstOrDefault();
        }
        catch
        {
            return null;
        }
    }

    /// <summary>The role the user last worked in at the branch; null when there is none.</summary>
    private async Task<string?> LastRoleNameAsync(int userId, int branchId)
    {
        try
        {
            return (await dbContext.Database
                .SqlQuery<string>($"SELECT LastRoleName AS Value FROM dbo.UserBranchLastLogin WHERE UserId = {userId} AND BranchId = {branchId} AND LastRoleName IS NOT NULL")
                .ToListAsync()).FirstOrDefault();
        }
        catch
        {
            return null;
        }
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

        var companyId = user.CompanyId ?? branch?.CompanyId ?? 1;
        var company = user.Company ?? branch?.Company ?? await dbContext.CompanyMasters.FindAsync(companyId);

        var claims = new List<Claim>
        {
            new(ClaimTypes.NameIdentifier, user.Id.ToString()),
            new(ClaimTypes.Name, user.Username),
            new("DisplayName", string.IsNullOrWhiteSpace(user.FullName) ? user.Username : user.FullName),
            new("IsSuperAdmin", isSuperAdmin ? "true" : "false"),
            new("CompanyId", companyId.ToString()),
            new("CompanyName", company?.CompanyName ?? "Primary Healthcare Network"),
            new("CompanyCode", company?.CompanyCode ?? "CMP-001")
        };

        if (!string.IsNullOrWhiteSpace(user.ProfilePicturePath))
        {
            claims.Add(new Claim("ProfilePicturePath", user.ProfilePicturePath));
        }

        // what the login is and, for a franchise / doctor / corporate login, the record it belongs to
        claims.Add(new Claim("UserType", user.UserType ?? UserTypes.General));
        if (user.ReferenceUserId is > 0)
        {
            claims.Add(new Claim("ReferenceUserId", user.ReferenceUserId.Value.ToString()));
        }

        if (branch is not null)
        {
            claims.Add(new Claim("BranchId", branch.BranchId.ToString()));
            claims.Add(new Claim("BranchName", branch.BranchName));
            claims.Add(new Claim("BranchCode", branch.BranchCode));
            claims.Add(new Claim("IsHOBranch", branch.IsHOBranch.ToString().ToLower()));

            HttpContext.Session.SetString("IsHOBranch", branch.IsHOBranch.ToString().ToLower());
            HttpContext.Session.SetInt32("BranchId", branch.BranchId);
            HttpContext.Session.SetInt32("SelectedBranchId", branch.BranchId);
            HttpContext.Session.SetString("BranchName", branch.BranchName);
        }

        // how many branches the user may work in - the profile menu offers "Switch Branch" only when there is a choice
        var branchCount = await dbContext.UserBranches.CountAsync(x => x.UserId == user.Id && x.IsActive && x.Branch.IsActive);
        claims.Add(new Claim("BranchCount", branchCount.ToString()));


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
            IsPersistent = rememberMe
        };
        if (rememberMe)
        {
            authProperties.ExpiresUtc = DateTimeOffset.UtcNow.AddHours(8);
        }

        await HttpContext.SignInAsync(CookieAuthenticationDefaults.AuthenticationScheme, principal, authProperties);

        HttpContext.Response.Cookies.Append("__emr_fresh_login", "1", new CookieOptions
        {
            HttpOnly = false,
            SameSite = SameSiteMode.Strict,
            Path = "/"
        });

        await WarnOpenDayClosingsAsync(user.Id, branch?.BranchId);
    }

    /// <summary>OPD / LAB Day Closing (SQLScripts/2275): earlier days the user has not closed - a warning at login and one bell
    /// notification a day. Never stops a login.</summary>
    private async Task WarnOpenDayClosingsAsync(int userId, int? branchId)
    {
        try
        {
            var svc = HttpContext.RequestServices.GetRequiredService<EMR.Web.Services.IDayClosingService>();
            var pending = (await svc.GetPendingAsync(userId, branchId)).Where(p => p.BusinessDate < DateTime.Today).ToList();
            if (pending.Count == 0) { await svc.ClearPendingNoticesIfDoneAsync(userId); return; }
            // per branch: a day closing belongs to the branch the cash was taken at, so the branch is always named
            var text = string.Join("; ", pending.GroupBy(p => p.BranchName ?? $"Branch {p.BranchId}").Select(b =>
                $"{b.Key} - " + string.Join(", ", b.GroupBy(p => p.Module == "PETTY" ? "petty cash (close in OPD or LAB)" : p.Module)
                    .Select(g => $"{g.Key} {string.Join(", ", g.Select(p => p.BusinessDate.ToString("dd-MMM")).Distinct().Take(4))}"))));
            // Hospital Settings "Remind Day Closing Notification" (SQLScripts/2313), per branch: the pop-up lists only the days of
            // branches set to Yes (a day closing belongs to the branch the cash was taken at, and a Super Admin signs in
            // without a branch). Nothing left = no pop-up. The bell notification below is unchanged.
            var pendingBranchIds = pending.Select(p => p.BranchId).Distinct().ToArray();
            HashSet<int> reminderOff;
            using (var rc = HttpContext.RequestServices.GetRequiredService<EMR.Web.Data.IDbConnectionFactory>().CreateConnection())
                reminderOff = (await Dapper.SqlMapper.QueryAsync<int>(rc, @"
                    SELECT x.BranchId FROM (
                        SELECT hs.BranchId, hs.DayClosingLoginReminder,
                               ROW_NUMBER() OVER (PARTITION BY hs.BranchId ORDER BY hs.IsActive DESC, hs.Id DESC) AS rn
                        FROM dbo.HospitalSettings hs WHERE hs.BranchId IN @ids) x
                    WHERE x.rn = 1 AND x.DayClosingLoginReminder = 0", new { ids = pendingBranchIds })).ToHashSet();
            var remind = pending.Where(p => !reminderOff.Contains(p.BranchId)).ToList();
            if (remind.Count > 0)
            {
                var remindText = string.Join("; ", remind.GroupBy(p => p.BranchName ?? $"Branch {p.BranchId}").Select(b =>
                    $"{b.Key} - " + string.Join(", ", b.GroupBy(p => p.Module == "PETTY" ? "petty cash (close in OPD or LAB)" : p.Module)
                        .Select(g => $"{g.Key} {string.Join(", ", g.Select(p => p.BusinessDate.ToString("dd-MMM")).Distinct().Take(4))}"))));
                var otherBranch = remind.Any(p => p.BranchId != branchId);
                TempData["Warning"] = $"Cash not closed for earlier days: {remindText}." +
                    (otherBranch ? " Switch to that branch and use OPD / LAB Day Closing there." : " Use OPD / LAB Day Closing.");
            }
            // one current reminder: the older days' reminders are replaced by today's
            using (var con = HttpContext.RequestServices.GetRequiredService<EMR.Web.Data.IDbConnectionFactory>().CreateConnection())
                await Dapper.SqlMapper.ExecuteAsync(con, @"UPDATE dbo.UserNotification SET IsDismissed = 1, DismissedOn = SYSDATETIME()
                    WHERE UserId = @userId AND Category = 'DAY_CLOSING' AND EventKey LIKE 'DAY_CLOSING_PENDING:%' AND EventKey <> @today AND IsDismissed = 0",
                    new { userId, today = $"DAY_CLOSING_PENDING:{userId}:{DateTime.Today:yyyyMMdd}" });
            var notes = HttpContext.RequestServices.GetRequiredService<EMR.Web.Services.Notifications.INotificationService>();
            var opd = pending.Any(p => p.Module is "OPD" or "PETTY");
            await notes.NotifyUsersAsync([userId], "DAY_CLOSING", "WARNING", "Day closing pending",
                $"Your cash is not closed for earlier days - {text}.", opd ? "/OpdDayClosing/Index" : "/LabDayClosing/Index", "CASH", null,
                $"DAY_CLOSING_PENDING:{userId}:{DateTime.Today:yyyyMMdd}", branchId, null);
        }
        catch (Exception ex)
        {
            HttpContext.RequestServices.GetService<ILogger<AccountController>>()?.LogWarning(ex, "Day closing login check failed for user {UserId}", userId);
        }
    }

    // Super admin is a flag on the account, set only in the database (Users.IsSuperAdmin), never from a screen.
    private static bool IsSuperAdminUser(User user) => user.IsSuperAdmin;
}

