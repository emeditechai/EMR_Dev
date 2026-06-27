using EMR.Web.ApiClients;
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
public class DoctorsController(
    IDoctorService doctorService,
    IDoctorApiClient doctorApiClient,
    IDoctorSpecialityService doctorSpecialityService,
    IDepartmentService departmentService,
    IDoctorConsultingFeeService consultingFeeService,
    ApplicationDbContext dbContext,
    IAuditLogService auditLogService,
    IPasswordHasherService passwordHasherService) : Controller
{
    public async Task<IActionResult> Index([FromQuery] int? doctorId = null)
    {
        var branchId = User.GetCurrentBranchId();

        ViewBag.BranchName = branchId.HasValue
            ? (await dbContext.BranchMasters.FindAsync(branchId.Value))?.BranchName
            : null;
        ViewBag.SelectedDoctorId = doctorId;

        try
        {
            // Strictly via EMR.Api — no DB fallback
            var apiDoctors = await doctorApiClient.GetListAsync(branchId);
            
            if (doctorId.HasValue && doctorId.Value > 0)
            {
                apiDoctors = apiDoctors.Where(d => d.DoctorId == doctorId.Value).ToList();
                var selectedDoctor = apiDoctors.FirstOrDefault();
                if (selectedDoctor != null)
                {
                    ViewBag.SelectedDoctorName = $"{selectedDoctor.FullName} ({selectedDoctor.PrimarySpecialityName})";
                }
            }

            var doctors = apiDoctors.Select(d => new DoctorListItemViewModel
            {
                DoctorId              = d.DoctorId,
                FullName              = d.FullName,
                PrimarySpecialityName = d.PrimarySpecialityName ?? string.Empty,
                DepartmentNames       = d.DepartmentNames ?? string.Empty,
                PhoneNumber           = d.PhoneNumber ?? string.Empty,
                EmailId               = d.EmailId ?? string.Empty,
                IsActive              = d.IsActive,
                ConsultingFeeNames    = d.ConsultingFeeNames ?? string.Empty,
                HasOPDDept            = d.HasOPDDept
            });

            return View(doctors);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Doctor Master List";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> SearchDoctors(string q)
    {
        var branchId = User.GetCurrentBranchId();
        try
        {
            var apiDoctors = await doctorApiClient.GetListAsync(branchId, q);
            var results = apiDoctors.Select(d => new
            {
                id = d.DoctorId,
                text = $"{d.FullName} - {d.PrimarySpecialityName} | Ph: {d.PhoneNumber} | Em: {d.EmailId}"
            });
            return Json(new { results });
        }
        catch
        {
            return Json(new { results = Array.Empty<object>() });
        }
    }


    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var model = new DoctorFormViewModel
        {
            IsActive = true
        };

        await PopulateFormSelections(model, isEdit: false);
        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(DoctorFormViewModel model)
    {
        var currentBranchId = User.GetCurrentBranchId();
        if (currentBranchId is null)
        {
            TempData["Error"] = "Please select a branch first.";
            return RedirectToAction("SelectBranch", "Account");
        }

        await ApplyBranchAssignmentRules(model, currentBranchId.Value);
        ValidateForm(model);
        if (model.IsLoginRequired)
            await ValidateLoginFieldsAsync(model, existingUserId: null);

        if (!ModelState.IsValid)
        {
            await PopulateFormSelections(model, isEdit: false);
            return View(model);
        }

        int? linkedUserId = null;
        if (model.IsLoginRequired)
        {
            linkedUserId = await CreateLinkedUserAsync(model, model.FullName);
        }

        var doctor = new DoctorMaster
        {
            NamePrefix = model.NamePrefix,
            FullName = model.FullName.Trim(),
            Gender = model.Gender,
            DateOfBirth = model.DateOfBirth,
            EmailId = model.EmailId.Trim(),
            PhoneNumber = model.PhoneNumber.Trim(),
            MedicalLicenseNo = model.MedicalLicenseNo?.Trim(),
            PrimarySpecialityId = model.PrimarySpecialityId!.Value,
            SecondarySpecialityId = model.SecondarySpecialityId,
            JoiningDate = model.JoiningDate,
            IsActive = true,
            CreatedBranchId = currentBranchId.Value,
            LinkedUserId = linkedUserId
        };

        await doctorService.CreateAsync(doctor, model.SelectedBranchIds, model.SelectedDepartmentIds, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Doctors.Create", $"Created doctor: {doctor.FullName} ({doctor.EmailId})");
        TempData["Success"] = "Doctor created successfully." + (model.IsLoginRequired ? " Login account created." : string.Empty);
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var branchId = User.GetCurrentBranchId();
        if (!await doctorService.IsVisibleForBranchAsync(id, branchId))
        {
            return NotFound();
        }

        var doctor = await doctorService.GetByIdAsync(id);
        if (doctor is null) return NotFound();

        var model = new DoctorFormViewModel
        {
            DoctorId = doctor.DoctorId,
            NamePrefix = doctor.NamePrefix ?? "Dr.",
            FullName = doctor.FullName,
            Gender = doctor.Gender,
            DateOfBirth = doctor.DateOfBirth,
            EmailId = doctor.EmailId,
            PhoneNumber = doctor.PhoneNumber,
            MedicalLicenseNo = doctor.MedicalLicenseNo,
            PrimarySpecialityId = doctor.PrimarySpecialityId,
            SecondarySpecialityId = doctor.SecondarySpecialityId,
            JoiningDate = doctor.JoiningDate,
            IsActive = doctor.IsActive,
            SelectedBranchIds = await doctorService.GetBranchIdsAsync(doctor.DoctorId),
            SelectedDepartmentIds = await doctorService.GetDepartmentIdsAsync(doctor.DoctorId),
            LinkedUserId = doctor.LinkedUserId
        };

        // Populate existing linked user info
        if (doctor.LinkedUserId.HasValue)
        {
            var linkedUser = await dbContext.Users.FindAsync(doctor.LinkedUserId.Value);
            if (linkedUser is not null)
            {
                model.IsLoginRequired = true;
                model.LoginUsername = linkedUser.Username;
            }
        }

        await PopulateFormSelections(model, isEdit: true);
        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(DoctorFormViewModel model)
    {
        var currentBranchId = User.GetCurrentBranchId();
        if (currentBranchId is null)
        {
            TempData["Error"] = "Please select a branch first.";
            return RedirectToAction("SelectBranch", "Account");
        }

        if (!await doctorService.IsVisibleForBranchAsync(model.DoctorId, currentBranchId))
        {
            return NotFound();
        }

        if (model.LinkedUserId.HasValue && model.IsLoginRequired)
        {
            var existingUser = await dbContext.Users.FindAsync(model.LinkedUserId.Value);
            if (existingUser != null)
            {
                model.LoginUsername = existingUser.Username;
            }
            ModelState.Remove(nameof(model.LoginPassword));
            ModelState.Remove(nameof(model.LoginConfirmPassword));
        }

        await ApplyBranchAssignmentRules(model, currentBranchId.Value);
        ValidateForm(model);
        if (model.IsLoginRequired)
            await ValidateLoginFieldsAsync(model, existingUserId: model.LinkedUserId);

        if (!ModelState.IsValid)
        {
            await PopulateFormSelections(model, isEdit: true);
            return View(model);
        }

        var doctor = await doctorService.GetByIdAsync(model.DoctorId);
        if (doctor is null) return NotFound();

        doctor.NamePrefix = model.NamePrefix;
        doctor.FullName = model.FullName.Trim();
        doctor.Gender = model.Gender;
        doctor.DateOfBirth = model.DateOfBirth;
        doctor.EmailId = model.EmailId.Trim();
        doctor.PhoneNumber = model.PhoneNumber.Trim();
        doctor.MedicalLicenseNo = model.MedicalLicenseNo?.Trim();
        doctor.PrimarySpecialityId = model.PrimarySpecialityId!.Value;
        doctor.SecondarySpecialityId = model.SecondarySpecialityId;
        doctor.JoiningDate = model.JoiningDate;
        doctor.IsActive = model.IsActive;

        // ── Login account management ──────────────────────────────────────────
        if (model.IsLoginRequired)
        {
            if (!model.LinkedUserId.HasValue)
            {
                // No linked user yet — create one
                var newUserId = await CreateLinkedUserAsync(model, doctor.FullName);
                doctor.LinkedUserId = newUserId;
            }
            else
            {
                // Already linked — sync
                await SyncLinkedUserAsync(model, model.LinkedUserId.Value, doctor.FullName);
                doctor.LinkedUserId = model.LinkedUserId;
            }
        }
        else if (!model.IsLoginRequired && model.LinkedUserId.HasValue)
        {
            // Login disabled — deactivate the existing user account
            var existingUser = await dbContext.Users.FindAsync(model.LinkedUserId.Value);
            if (existingUser is not null)
            {
                existingUser.IsActive = false;
                existingUser.LastModifiedDate = DateTime.Now;
                await dbContext.SaveChangesAsync();
            }
            doctor.LinkedUserId = null;
        }

        await doctorService.UpdateAsync(doctor, model.SelectedBranchIds, model.SelectedDepartmentIds, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Doctors.Edit", $"Updated doctor: {doctor.FullName} ({doctor.EmailId})");
        TempData["Success"] = "Doctor updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var branchId = User.GetCurrentBranchId();
        var model = await doctorService.GetDetailsAsync(id, branchId);
        if (model is null) return NotFound();

        if (branchId.HasValue)
            model.ConsultingFees = (await consultingFeeService.GetByDoctorAsync(id, branchId.Value)).ToList();

        return View(model);
    }

    private void ValidateForm(DoctorFormViewModel model)
    {
        if (model.PrimarySpecialityId is null or <= 0)
        {
            ModelState.AddModelError(nameof(model.PrimarySpecialityId), "Primary Speciality is required.");
        }

        if (model.SecondarySpecialityId.HasValue && model.SecondarySpecialityId == model.PrimarySpecialityId)
        {
            ModelState.AddModelError(nameof(model.SecondarySpecialityId), "Secondary Speciality must be different from Primary Speciality.");
        }

        if (model.SelectedDepartmentIds.Count == 0)
        {
            ModelState.AddModelError(nameof(model.SelectedDepartmentIds), "At least one Department is required.");
        }

        if (model.SelectedBranchIds.Count == 0)
        {
            ModelState.AddModelError(nameof(model.SelectedBranchIds), "At least one Branch assignment is required.");
        }
    }

    private async Task ValidateLoginFieldsAsync(DoctorFormViewModel model, int? existingUserId)
    {
        if (string.IsNullOrWhiteSpace(model.LoginUsername))
        {
            ModelState.AddModelError(nameof(model.LoginUsername), "Username is required when login is enabled.");
        }
        else
        {
            // Check username uniqueness (allow same user on edit)
            var taken = await dbContext.Users.AnyAsync(u =>
                u.Username == model.LoginUsername.Trim() &&
                (!existingUserId.HasValue || u.Id != existingUserId.Value));
            if (taken)
                ModelState.AddModelError(nameof(model.LoginUsername), "This username is already taken.");
        }

        // Password is mandatory on Create; optional on Edit (blank = keep existing)
        bool isCreate = !existingUserId.HasValue;
        if (isCreate && string.IsNullOrWhiteSpace(model.LoginPassword))
        {
            ModelState.AddModelError(nameof(model.LoginPassword), "Password is required.");
        }

        if (!string.IsNullOrWhiteSpace(model.LoginPassword) &&
            model.LoginPassword != model.LoginConfirmPassword)
        {
            ModelState.AddModelError(nameof(model.LoginConfirmPassword), "Passwords do not match.");
        }
    }

    /// <summary>Creates a new User linked to this doctor and returns the new User.Id.</summary>
    private async Task<int> CreateLinkedUserAsync(DoctorFormViewModel model, string fullName)
    {
        var (hash, salt) = passwordHasherService.HashPassword(model.LoginPassword!);

        // Split full name roughly for FirstName / LastName
        var nameParts = fullName.Trim().Split(' ', 2);
        var firstName = nameParts[0];
        var lastName  = nameParts.Length > 1 ? nameParts[1] : string.Empty;

        var user = new User
        {
            Username         = model.LoginUsername!.Trim(),
            Email            = model.EmailId.Trim(),
            PasswordHash     = hash,
            Salt             = salt,
            FirstName        = firstName,
            LastName         = lastName,
            FullName         = fullName,
            PhoneNumber      = model.PhoneNumber.Trim(),
            Phone            = model.PhoneNumber.Trim(),
            IsActive         = true,
            PasswordLastChanged = DateTime.Now,
            CreatedDate      = DateTime.Now,
            LastModifiedDate = DateTime.Now
        };
        dbContext.Users.Add(user);
        await dbContext.SaveChangesAsync(); // get new user.Id

        // Map branches
        var branchMappings = model.SelectedBranchIds.Distinct().Select(bid => new UserBranch
        {
            UserId      = user.Id,
            BranchId    = bid,
            IsActive    = true,
            CreatedDate = DateTime.Now,
            ModifiedDate = DateTime.Now,
            CreatedBy   = User.GetUserId(),
            ModifiedBy  = User.GetUserId()
        });
        dbContext.UserBranches.AddRange(branchMappings);

        // Map "Doctor" role
        var doctorRole = await dbContext.Roles.FirstOrDefaultAsync(r =>
            r.Name.ToLower() == "doctor");
        if (doctorRole is not null)
        {
            dbContext.UserRoles.Add(new UserRole
            {
                UserId       = user.Id,
                RoleId       = doctorRole.Id,
                IsActive     = true,
                AssignedDate = DateTime.Now,
                AssignedBy   = User.GetUserId(),
                CreatedDate  = DateTime.Now,
                CreatedBy    = User.GetUserId(),
                ModifiedDate = DateTime.Now,
                ModifiedBy   = User.GetUserId()
            });
        }

        await dbContext.SaveChangesAsync();
        await auditLogService.LogAsync("MasterData", "Doctors.CreateLogin",
            $"Created login account '{user.Username}' for doctor '{fullName}'", user.Id);

        return user.Id;
    }

    /// <summary>Syncs an existing linked User's details and branch mappings with the doctor.</summary>
    private async Task SyncLinkedUserAsync(DoctorFormViewModel model, int linkedUserId, string fullName)
    {
        var user = await dbContext.Users.FindAsync(linkedUserId);
        if (user is null) return;

        var nameParts = fullName.Trim().Split(' ', 2);
        user.Username        = model.LoginUsername!.Trim();
        user.Email           = model.EmailId.Trim();
        user.FirstName       = nameParts[0];
        user.LastName        = nameParts.Length > 1 ? nameParts[1] : string.Empty;
        user.FullName        = fullName;
        user.PhoneNumber     = model.PhoneNumber.Trim();
        user.Phone           = model.PhoneNumber.Trim();
        user.IsActive        = model.IsActive; // mirror doctor's active status
        user.LastModifiedDate = DateTime.Now;

        if (!string.IsNullOrWhiteSpace(model.LoginPassword))
        {
            var (hash, salt) = passwordHasherService.HashPassword(model.LoginPassword);
            user.PasswordHash       = hash;
            user.Salt               = salt;
            user.PasswordLastChanged = DateTime.Now;
        }

        // Re-sync branch mappings
        var existingBranches = await dbContext.UserBranches.Where(x => x.UserId == linkedUserId).ToListAsync();
        dbContext.UserBranches.RemoveRange(existingBranches);
        var newBranches = model.SelectedBranchIds.Distinct().Select(bid => new UserBranch
        {
            UserId       = linkedUserId,
            BranchId     = bid,
            IsActive     = true,
            CreatedDate  = DateTime.Now,
            ModifiedDate = DateTime.Now,
            CreatedBy    = User.GetUserId(),
            ModifiedBy   = User.GetUserId()
        });
        dbContext.UserBranches.AddRange(newBranches);

        await dbContext.SaveChangesAsync();
        await auditLogService.LogAsync("MasterData", "Doctors.SyncLogin",
            $"Synced login account '{user.Username}' for doctor '{fullName}'", linkedUserId);
    }

    private async Task PopulateFormSelections(DoctorFormViewModel model, bool isEdit)
    {
        var currentBranchId = User.GetCurrentBranchId();
        if (currentBranchId is null)
        {
            return;
        }

        var currentBranch = await dbContext.BranchMasters
            .AsNoTracking()
            .FirstOrDefaultAsync(x => x.BranchId == currentBranchId.Value);

        model.CurrentBranchId = currentBranchId.Value;
        model.CurrentBranchName = currentBranch?.BranchName ?? "Current Branch";

        model.CanAssignMultipleBranches = await CanAssignMultipleBranchesAsync(currentBranchId.Value);

        var allBranches = await dbContext.BranchMasters
            .Where(x => x.IsActive)
            .OrderBy(x => x.BranchName)
            .Select(x => new { x.BranchId, x.BranchName, x.BranchCode })
            .ToListAsync();

        model.BranchOptions = allBranches
            .Select(x => new SelectListItem(
                string.IsNullOrWhiteSpace(x.BranchCode)
                    ? x.BranchName
                    : $"{x.BranchCode} - {x.BranchName}",
                x.BranchId.ToString()))
            .ToList();

        if (!model.CanAssignMultipleBranches)
        {
            model.SelectedBranchIds = [currentBranchId.Value];
        }
        else
        {
            if (model.SelectedBranchIds.Count == 0)
            {
                model.SelectedBranchIds = [currentBranchId.Value];
            }
            else if (!model.SelectedBranchIds.Contains(currentBranchId.Value))
            {
                model.SelectedBranchIds.Add(currentBranchId.Value);
            }
        }

        var specialities = await doctorSpecialityService.GetActiveAsync();
        model.SpecialityOptions = specialities
            .Select(x => new SelectListItem(x.SpecialityName, x.SpecialityId.ToString()))
            .ToList();

        var departments = await departmentService.GetActiveAsync();
        model.DepartmentOptions = departments
            .Select(x => new SelectListItem($"{x.DeptName} ({x.DeptType})", x.DeptId.ToString()))
            .ToList();

        if (!isEdit)
        {
            model.IsActive = true;
        }
    }

    private async Task ApplyBranchAssignmentRules(DoctorFormViewModel model, int currentBranchId)
    {
        model.CanAssignMultipleBranches = await CanAssignMultipleBranchesAsync(currentBranchId);

        if (!model.CanAssignMultipleBranches)
        {
            model.SelectedBranchIds = [currentBranchId];
            return;
        }

        model.SelectedBranchIds = model.SelectedBranchIds
            .Distinct()
            .ToList();

        if (!model.SelectedBranchIds.Contains(currentBranchId))
        {
            model.SelectedBranchIds.Add(currentBranchId);
        }
    }

    private async Task<bool> CanAssignMultipleBranchesAsync(int currentBranchId)
    {
        var isAdministrator = string.Equals(
            User.GetActiveRole(),
            "Administrator",
            StringComparison.OrdinalIgnoreCase);

        if (!isAdministrator && !User.IsSuperAdmin())
        {
            return false;
        }

        var branch = await dbContext.BranchMasters
            .AsNoTracking()
            .FirstOrDefaultAsync(x => x.BranchId == currentBranchId);

        return branch?.IsHOBranch == true;
    }

    // ──────────────────────────────────────────────────────────
    // Consulting Fees AJAX endpoints
    // ──────────────────────────────────────────────────────────

    /// GET /Doctors/GetConsultingServices?branchId=x
    [HttpGet]
    public async Task<IActionResult> GetConsultingServices()
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return Unauthorized();
        var list = await consultingFeeService.GetConsultingServicesAsync(branchId.Value);
        return Json(list.Select(x => new { x.ServiceId, x.ItemCode, x.ItemName, x.ItemCharges, x.Label }));
    }

    /// GET /Doctors/GetDoctorFees?doctorId=x
    [HttpGet]
    public async Task<IActionResult> GetDoctorFees(int doctorId)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return Unauthorized();
        var list = await consultingFeeService.GetByDoctorAsync(doctorId, branchId.Value);
        return Json(list);
    }

    /// POST /Doctors/AddConsultingFee
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> AddConsultingFee([FromBody] ConsultingFeeRequest req)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return Unauthorized();
        if (req.DoctorId <= 0 || req.ServiceId <= 0)
            return BadRequest(new { error = "Invalid request." });

        await consultingFeeService.AddAsync(req.DoctorId, req.ServiceId, branchId.Value, User.GetUserId());
        var fees = await consultingFeeService.GetByDoctorAsync(req.DoctorId, branchId.Value);
        return Json(new { success = true, fees });
    }

    /// POST /Doctors/RemoveConsultingFee
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> RemoveConsultingFee([FromBody] ConsultingFeeRemoveRequest req)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return Unauthorized();
        if (req.MappingId <= 0 || req.DoctorId <= 0)
            return BadRequest(new { error = "Invalid request." });

        await consultingFeeService.RemoveAsync(req.MappingId, req.DoctorId, branchId.Value);
        var fees = await consultingFeeService.GetByDoctorAsync(req.DoctorId, branchId.Value);
        return Json(new { success = true, fees });
    }
}

public record ConsultingFeeRequest(int DoctorId, int ServiceId);
public record ConsultingFeeRemoveRequest(int MappingId, int DoctorId);
