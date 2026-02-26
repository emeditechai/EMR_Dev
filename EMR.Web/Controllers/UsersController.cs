using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class UsersController(
    ApplicationDbContext dbContext,
    IPasswordHasherService passwordHasherService,
    IAuditLogService auditLogService,
    IWebHostEnvironment webHostEnvironment) : Controller
{
    public async Task<IActionResult> Index()
    {
        if (!CanManage())
        {
            return RedirectToAction("Index", "Dashboard");
        }

        var branchId = User.GetCurrentBranchId();

        var query = dbContext.Users
            .Include(x => x.UserBranches)
                .ThenInclude(x => x.Branch)
            .OrderBy(x => x.Username)
            .AsQueryable();

        // Filter to current branch if a branch is active in session
        if (branchId.HasValue)
        {
            query = query.Where(x => x.UserBranches.Any(ub => ub.BranchId == branchId.Value && ub.IsActive));
        }

        var users = await query
            .Select(x => new UserListItemViewModel
            {
                Id = x.Id,
                Username = x.Username,
                EmployeeCode = branchId.HasValue
                    ? (x.UserBranches.Where(ub => ub.IsActive && ub.BranchId == branchId.Value).Select(ub => ub.EmployeeCode).FirstOrDefault() ?? string.Empty)
                    : (x.UserBranches.Where(ub => ub.IsActive).Select(ub => ub.EmployeeCode).FirstOrDefault() ?? string.Empty),
                FullName = x.FullName ?? string.Concat(x.FirstName, " ", x.LastName),
                Email = x.Email ?? string.Empty,
                IsActive = x.IsActive,
                Branches = string.Join(", ", x.UserBranches.Where(b => b.IsActive).Select(b => b.Branch.BranchName))
            })
            .ToListAsync();

        ViewBag.BranchName = branchId.HasValue
            ? (await dbContext.BranchMasters.FindAsync(branchId.Value))?.BranchName
            : null;

        return View(users);
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var user = await dbContext.Users
            .Include(x => x.UserBranches.Where(b => b.IsActive))
                .ThenInclude(x => x.Branch)
            .Include(x => x.UserRoles.Where(r => r.IsActive))
                .ThenInclude(x => x.Role)
            .FirstOrDefaultAsync(x => x.Id == id);

        if (user is null) return NotFound();

        var allUserRoles = user.UserRoles
            .Where(ur => ur.Role is not null)
            .Select(ur => ur.Role.Name)
            .Distinct()
            .OrderBy(n => n)
            .ToList();

        var branchRoleMappings = user.UserBranches
            .Where(ub => ub.Branch is not null)
            .Select(ub => new BranchRoleDetailItem
            {
                BranchName = ub.Branch.BranchName,
                EmployeeCode = ub.EmployeeCode,
                Roles = allUserRoles
            }).ToList();

        var model = new UserDetailsViewModel
        {
            Id = user.Id,
            Username = user.Username,
            EmployeeCode = user.UserBranches.Where(ub => ub.IsActive).Select(ub => ub.EmployeeCode).FirstOrDefault() ?? string.Empty,
            Email = user.Email,
            FirstName = user.FirstName ?? string.Empty,
            LastName = user.LastName ?? string.Empty,
            PhoneNumber = user.PhoneNumber,
            IsActive = user.IsActive,
            IsLockedOut = user.IsLockedOut,
            LastLoginDate = user.LastLoginDate,
            CreatedDate = user.CreatedDate,
            LastModifiedDate = user.LastModifiedDate,
            ProfilePicturePath = user.ProfilePicturePath,
            Branches = user.UserBranches.Select(b => b.Branch.BranchName).ToList(),
            BranchRoleMappings = branchRoleMappings
        };

        return View(model);
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        if (!CanManage())
        {
            return RedirectToAction("Index", "Dashboard");
        }

        var model = new UserFormViewModel();
        await PopulateSelections(model);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(UserFormViewModel model)
    {
        if (!CanManage())
        {
            return RedirectToAction("Index", "Dashboard");
        }

        if (string.IsNullOrWhiteSpace(model.Password))
        {
            ModelState.AddModelError(nameof(model.Password), "Password is required.");
        }

        if (await dbContext.Users.AnyAsync(x => x.Username == model.Username))
        {
            ModelState.AddModelError(nameof(model.Username), "Username already exists.");
        }

        if (!model.SelectedBranchIds.Any())
        {
            ModelState.AddModelError(nameof(model.SelectedBranchIds), "Select at least one branch.");
        }

        await ValidateEmployeeCodeUniquenessAsync(model);
        ValidateProfilePicture(model);

        if (!ModelState.IsValid)
        {
            await PopulateSelections(model);
            return View(model);
        }

        var normalizedEmployeeCode = string.IsNullOrWhiteSpace(model.EmployeeCode)
            ? null
            : model.EmployeeCode.Trim().ToUpperInvariant();
        var profilePicturePath = await SaveProfilePictureAsync(model.ProfilePictureFile, null);

        var (hash, salt) = passwordHasherService.HashPassword(model.Password!);
        var user = new User
        {
            Username = model.Username.Trim(),
            Email = model.Email?.Trim(),
            PasswordHash = hash,
            Salt = salt,
            FirstName = model.FirstName.Trim(),
            LastName = model.LastName.Trim(),
            FullName = string.Concat(model.FirstName.Trim(), " ", model.LastName.Trim()),
            PhoneNumber = model.PhoneNumber,
            Phone = model.PhoneNumber,
            ProfilePicturePath = profilePicturePath,
            IsActive = model.IsActive,
            PasswordLastChanged = DateTime.UtcNow,
            CreatedDate = DateTime.UtcNow,
            LastModifiedDate = DateTime.UtcNow,
        };

        dbContext.Users.Add(user);
        await dbContext.SaveChangesAsync();

        await SaveMappings(model, user.Id, normalizedEmployeeCode);
        await auditLogService.LogAsync("MasterData", "Users.Create", $"Created user: {user.Username}", user.Id);
        TempData["Success"] = "User created successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        if (!CanManage())
        {
            return RedirectToAction("Index", "Dashboard");
        }

        var user = await dbContext.Users
            .Include(x => x.UserBranches)
            .Include(x => x.UserRoles)
            .FirstOrDefaultAsync(x => x.Id == id);

        if (user is null)
        {
            return NotFound();
        }

        var model = new UserFormViewModel
        {
            Id = user.Id,
            Username = user.Username,
            Email = user.Email,
            FirstName = user.FirstName ?? string.Empty,
            LastName = user.LastName ?? string.Empty,
            PhoneNumber = user.PhoneNumber,
            EmployeeCode = user.UserBranches.Where(x => x.IsActive).Select(x => x.EmployeeCode).FirstOrDefault() ?? string.Empty,
            ExistingProfilePicturePath = user.ProfilePicturePath,
            IsActive = user.IsActive,
            SelectedBranchIds = user.UserBranches.Where(x => x.IsActive).Select(x => x.BranchId).ToList(),
            SelectedRoleIds = user.UserRoles.Where(x => x.IsActive).Select(x => x.RoleId).ToList()
        };

        await PopulateSelections(model);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(UserFormViewModel model)
    {
        if (!CanManage())
        {
            return RedirectToAction("Index", "Dashboard");
        }

        var user = await dbContext.Users.FirstOrDefaultAsync(x => x.Id == model.Id);
        if (user is null)
        {
            return NotFound();
        }

        if (await dbContext.Users.AnyAsync(x => x.Id != model.Id && x.Username == model.Username))
        {
            ModelState.AddModelError(nameof(model.Username), "Username already exists.");
        }

        if (!model.SelectedBranchIds.Any())
        {
            ModelState.AddModelError(nameof(model.SelectedBranchIds), "Select at least one branch.");
        }

        await ValidateEmployeeCodeUniquenessAsync(model);
        ValidateProfilePicture(model);

        if (!ModelState.IsValid)
        {
            await PopulateSelections(model);
            return View(model);
        }

        var normalizedEmployeeCode = string.IsNullOrWhiteSpace(model.EmployeeCode)
            ? null
            : model.EmployeeCode.Trim().ToUpperInvariant();

        user.Username = model.Username.Trim();
        user.Email = model.Email?.Trim();
        user.FirstName = model.FirstName.Trim();
        user.LastName = model.LastName.Trim();
        user.FullName = string.Concat(model.FirstName.Trim(), " ", model.LastName.Trim());
        user.PhoneNumber = model.PhoneNumber;
        user.Phone = model.PhoneNumber;
        user.IsActive = model.IsActive;
        user.LastModifiedDate = DateTime.UtcNow;

        user.ProfilePicturePath = await SaveProfilePictureAsync(model.ProfilePictureFile, user.ProfilePicturePath);

        if (!string.IsNullOrWhiteSpace(model.Password))
        {
            var (hash, salt) = passwordHasherService.HashPassword(model.Password);
            user.PasswordHash = hash;
            user.Salt = salt;
            user.PasswordLastChanged = DateTime.UtcNow;
        }

        await SaveMappings(model, user.Id, normalizedEmployeeCode);
        await dbContext.SaveChangesAsync();
        await auditLogService.LogAsync("MasterData", "Users.Edit", $"Updated user: {user.Username}", user.Id);
        TempData["Success"] = "User updated successfully.";

        return RedirectToAction(nameof(Index));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id)
    {
        if (!CanManage())
        {
            return RedirectToAction("Index", "Dashboard");
        }

        var user = await dbContext.Users.FirstOrDefaultAsync(x => x.Id == id);
        if (user is null)
        {
            return NotFound();
        }

        user.IsActive = !user.IsActive;
        user.LastModifiedDate = DateTime.UtcNow;
        await dbContext.SaveChangesAsync();
        await auditLogService.LogAsync("MasterData", "Users.ToggleStatus", $"Toggled user status: {user.Username} => {(user.IsActive ? "Active" : "Inactive")}", user.Id);
        TempData["Success"] = "User status updated.";

        return RedirectToAction(nameof(Index));
    }

    private async Task PopulateSelections(UserFormViewModel model)
    {
        var branches = await dbContext.BranchMasters
            .Where(x => x.IsActive)
            .OrderBy(x => x.BranchName)
            .Select(x => new { x.BranchId, x.BranchName })
            .ToListAsync();

        model.BranchOptions = branches
            .Select(x => new SelectListItem(x.BranchName, x.BranchId.ToString()))
            .ToList();

        var allRoles = await dbContext.Roles
            .OrderBy(x => x.Name)
            .Select(x => new { x.Id, x.Name })
            .ToListAsync();

        var roleItems = allRoles.Select(r => new RoleItem { Id = r.Id, Name = r.Name }).ToList();

        model.BranchRoleGroups = branches.Select(b => new BranchRoleGroup
        {
            BranchId = b.BranchId,
            BranchName = b.BranchName,
            Roles = roleItems
        }).ToList();
    }

    private async Task SaveMappings(UserFormViewModel model, int userId, string? normalizedEmployeeCode)
    {
        var existingBranches = await dbContext.UserBranches.Where(x => x.UserId == userId).ToListAsync();
        dbContext.UserBranches.RemoveRange(existingBranches);

        var branchMappings = model.SelectedBranchIds
            .Distinct()
            .Select(branchId => new UserBranch
            {
                UserId = userId,
                BranchId = branchId,
                EmployeeCode = normalizedEmployeeCode,
                IsActive = true,
                CreatedDate = DateTime.UtcNow,
                ModifiedDate = DateTime.UtcNow,
                CreatedBy = User.GetUserId(),
                ModifiedBy = User.GetUserId()
            });
        dbContext.UserBranches.AddRange(branchMappings);

        var existingRoles = await dbContext.UserRoles.Where(x => x.UserId == userId).ToListAsync();
        dbContext.UserRoles.RemoveRange(existingRoles);

        var roleMappings = model.SelectedRoleIds
            .Distinct()
            .Select(roleId => new UserRole
            {
                UserId = userId,
                RoleId = roleId,
                IsActive = true,
                AssignedDate = DateTime.UtcNow,
                AssignedBy = User.GetUserId(),
                CreatedDate = DateTime.UtcNow,
                CreatedBy = User.GetUserId(),
                ModifiedDate = DateTime.UtcNow,
                ModifiedBy = User.GetUserId()
            });
        dbContext.UserRoles.AddRange(roleMappings);
    }

    private async Task ValidateEmployeeCodeUniquenessAsync(UserFormViewModel model)
    {
        if (string.IsNullOrWhiteSpace(model.EmployeeCode) || !model.SelectedBranchIds.Any())
        {
            return;
        }

        var normalizedEmployeeCode = model.EmployeeCode.Trim().ToUpperInvariant();
        var selectedBranchIds = model.SelectedBranchIds.Distinct().ToList();

        var conflict = await dbContext.UserBranches
            .Include(x => x.Branch)
            .Include(x => x.User)
            .Where(x => x.IsActive
                        && x.UserId != model.Id
                        && x.EmployeeCode != null
                        && x.EmployeeCode.ToUpper() == normalizedEmployeeCode
                        && selectedBranchIds.Contains(x.BranchId))
            .Select(x => new { x.Branch.BranchName, Username = x.User.Username })
            .FirstOrDefaultAsync();

        if (conflict is not null)
        {
            ModelState.AddModelError(nameof(model.EmployeeCode),
                $"Employee Code already exists in branch '{conflict.BranchName}' (User: {conflict.Username}).");
        }
    }

    private void ValidateProfilePicture(UserFormViewModel model)
    {
        if (model.ProfilePictureFile is null || model.ProfilePictureFile.Length == 0)
        {
            return;
        }

        var ext = Path.GetExtension(model.ProfilePictureFile.FileName).ToLowerInvariant();
        var allowed = new[] { ".jpg", ".jpeg", ".png", ".webp" };

        if (!allowed.Contains(ext))
        {
            ModelState.AddModelError(nameof(model.ProfilePictureFile), "Only JPG, JPEG, PNG, WEBP files are allowed.");
        }

        const long maxBytes = 2 * 1024 * 1024;
        if (model.ProfilePictureFile.Length > maxBytes)
        {
            ModelState.AddModelError(nameof(model.ProfilePictureFile), "Profile picture size must be up to 2 MB.");
        }
    }

    private async Task<string?> SaveProfilePictureAsync(IFormFile? file, string? existingPath)
    {
        if (file is null || file.Length == 0)
        {
            return existingPath;
        }

        var ext = Path.GetExtension(file.FileName).ToLowerInvariant();
        var fileName = $"user_{Guid.NewGuid():N}{ext}";
        var relativePath = $"/uploads/profiles/{fileName}";
        var uploadRoot = Path.Combine(webHostEnvironment.WebRootPath, "uploads", "profiles");

        Directory.CreateDirectory(uploadRoot);
        var physicalPath = Path.Combine(uploadRoot, fileName);

        await using (var stream = new FileStream(physicalPath, FileMode.Create))
        {
            await file.CopyToAsync(stream);
        }

        DeleteProfilePictureIfExists(existingPath);
        return relativePath;
    }

    private void DeleteProfilePictureIfExists(string? relativePath)
    {
        if (string.IsNullOrWhiteSpace(relativePath))
        {
            return;
        }

        var cleanPath = relativePath.TrimStart('/').Replace('/', Path.DirectorySeparatorChar);
        var fullPath = Path.Combine(webHostEnvironment.WebRootPath, cleanPath);
        if (System.IO.File.Exists(fullPath))
        {
            System.IO.File.Delete(fullPath);
        }
    }

    private bool CanManage() => true; // TODO: re-enable role check when authorization is implemented
}
