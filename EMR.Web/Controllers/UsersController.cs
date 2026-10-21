using Dapper;
using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using EMR.Web.Services.Geography;
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
    IWebHostEnvironment webHostEnvironment,
    ICountryService countryService,
    IStateService stateService,
    ICityService cityService,
    IAreaService areaService,
    ILabTestCategoryApiClient labTestCategoryApiClient,
    IUserListApiClient userListApiClient) : Controller
{
    /// <summary>
    /// Which users this login may see and manage. Signed in to the head office (Branchmaster.IsHOBranch): every user of
    /// the company, all branches (null = no branch limit). Any other branch: the users of the branches assigned to the
    /// signed-in user.
    /// </summary>
    private async Task<List<int>?> VisibleBranchIdsAsync()
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId.HasValue && await dbContext.BranchMasters.AnyAsync(b => b.BranchId == branchId.Value && b.IsHOBranch))
            return null;
        var me = User.GetUserId();
        var ids = await dbContext.UserBranches.Where(ub => ub.UserId == me && ub.IsActive).Select(ub => ub.BranchId).ToListAsync();
        if (branchId.HasValue && !ids.Contains(branchId.Value)) ids.Add(branchId.Value);
        return ids;
    }

    /// <summary>False when the user belongs only to branches this login may not see (see <see cref="VisibleBranchIdsAsync"/>).</summary>
    private async Task<bool> MaySeeUserAsync(int userId)
    {
        if (await VisibleBranchIdsAsync() is not { } ids) return true;
        return await dbContext.UserBranches.AnyAsync(ub => ub.UserId == userId && ub.IsActive && ids.Contains(ub.BranchId));
    }

    /// <summary>User Master list, paged and filtered on the server (SQLScripts/2314). Scope as before: the login's company
    /// (every company for Super Admin) and, away from the head office, only users of the visible branches.</summary>
    public async Task<IActionResult> Index(string? search, string? userType, string? status, string? role, int page = 1, int pageSize = 25)
    {
        if (!CanManage())
        {
            return RedirectToAction("Index", "Dashboard");
        }

        var branchId = User.GetCurrentBranchId();
        if (page < 1) page = 1;
        if (pageSize is not (10 or 25 or 50 or 100)) pageSize = 25;
        userType = userType?.Trim() is "U" or "D" or "F" or "C" ? userType.Trim() : null;
        status = status?.Trim().ToLowerInvariant() is "active" or "inactive" ? status.Trim().ToLowerInvariant() : null;
        role = role?.Trim().ToLowerInvariant() is "nurse" or "phlebotomist" or "pathologist" or "labtech" or "logistics" ? role.Trim().ToLowerInvariant() : null;
        search = string.IsNullOrWhiteSpace(search) ? null : search.Trim();

        UserListPageDto result;
        try
        {
            result = await userListApiClient.GetPagedAsync(User.IsSuperAdmin() ? null : User.GetCompanyId(),
                await VisibleBranchIdsAsync(), branchId, search, userType, status, role, page, pageSize);
            // a page past the end (e.g. after narrowing the filter): show the last page instead of an empty one
            var lastPage = Math.Max(1, (int)Math.Ceiling(result.FilteredCount / (double)pageSize));
            if (page > lastPage)
            {
                page = lastPage;
                result = await userListApiClient.GetPagedAsync(User.IsSuperAdmin() ? null : User.GetCompanyId(),
                    await VisibleBranchIdsAsync(), branchId, search, userType, status, role, page, pageSize);
            }
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "User Master";
            return View("ApiDown");
        }

        var model = new UserListPageViewModel
        {
            Items = result.Items.Select(x => new UserListItemViewModel
            {
                Id = x.Id,
                Username = x.Username,
                EmployeeCode = x.EmployeeCode,
                FullName = x.FullName,
                Email = x.Email,
                IsActive = x.IsActive,
                IsNursingStaff = x.IsNursingStaff,
                IsPhlebotomist = x.IsPhlebotomist,
                IsPathologist = x.IsPathologist,
                IsLabTechnician = x.IsLabTechnician,
                IsLogisticsBoy = x.IsLogisticsBoy,
                Branches = x.Branches,
                DepartmentNames = x.DepartmentNames,
                ProfilePicturePath = x.ProfilePicturePath,
                HasSignature = x.HasSignature,
                UserType = x.UserType,
                ReferenceUserId = x.ReferenceUserId,
                ReferenceName = x.ReferenceName
            }).ToList(),
            TotalUsers = result.Kpis.TotalUsers,
            ActiveUsers = result.Kpis.ActiveUsers,
            InactiveUsers = result.Kpis.InactiveUsers,
            Pathologists = result.Kpis.Pathologists,
            PathologistsSigned = result.Kpis.PathologistsSigned,
            LabTechnicians = result.Kpis.LabTechnicians,
            FilteredCount = result.FilteredCount,
            Page = page,
            PageSize = pageSize,
            Search = search,
            UserType = userType,
            Status = status,
            Role = role
        };

        ViewBag.BranchName = branchId.HasValue
            ? (await dbContext.BranchMasters.FindAsync(branchId.Value))?.BranchName
            : null;

        return View(model);
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        if (!await MaySeeUserAsync(id)) return NotFound();
        var user = await dbContext.Users
            .Include(x => x.UserBranches.Where(b => b.IsActive))
                .ThenInclude(x => x.Branch)
            .Include(x => x.UserRoles.Where(r => r.IsActive))
                .ThenInclude(x => x.Role)
            .Include(x => x.Country)
            .Include(x => x.State)
            .Include(x => x.City)
            .Include(x => x.ShiftSlot)
            .Include(x => x.AssignedZone)
            .Include(x => x.LabTechnicianShiftSlot)
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
                // A role with no branch applies in every branch; otherwise only in its own.
                Roles = user.UserRoles
                    .Where(ur => ur.Role is not null && (ur.Branch_ID == null || ur.Branch_ID == ub.BranchId))
                    .Select(ur => ur.Role.Name)
                    .Distinct()
                    .OrderBy(n => n)
                    .ToList()
            }).ToList();

        var deptDict = await dbContext.DepartmentMasters
            .ToDictionaryAsync(d => d.DeptId, d => d.DeptName);

        var departmentNames = new List<string>();
        if (!string.IsNullOrWhiteSpace(user.DepartmentIds))
        {
            departmentNames = user.DepartmentIds.Split(',', StringSplitOptions.RemoveEmptyEntries)
                .Select(s => int.TryParse(s.Trim(), out var did) ? did : 0)
                .Where(did => did > 0 && deptDict.ContainsKey(did))
                .Select(did => deptDict[did])
                .ToList();
        }

        var shiftSlotName = user.ShiftSlot != null
            ? $"{user.ShiftSlot.ShiftName} ({user.ShiftSlot.StartTime:hh\\:mm} - {user.ShiftSlot.EndTime:hh\\:mm})"
            : null;

        var labShiftSlotName = user.LabTechnicianShiftSlot != null
            ? $"{user.LabTechnicianShiftSlot.ShiftName} ({user.LabTechnicianShiftSlot.StartTime:hh\\:mm} - {user.LabTechnicianShiftSlot.EndTime:hh\\:mm})"
            : null;

        var detailRefNames = await ReferenceNamesAsync(new[] { (user.UserType, user.ReferenceUserId) });
        var model = new UserDetailsViewModel
        {
            ReportsToName = user.ReportsToUserId is null ? null
                : await dbContext.Users.AsNoTracking().Where(u => u.Id == user.ReportsToUserId)
                    .Select(u => (string.IsNullOrWhiteSpace(u.FullName) ? u.Username : u.FullName.Trim() + " (" + u.Username + ")"))
                    .FirstOrDefaultAsync(),
            Id = user.Id,
            UserType = user.UserType,
            ReferenceUserId = user.ReferenceUserId,
            ReferenceName = user.ReferenceUserId.HasValue ? detailRefNames.GetValueOrDefault((user.UserType, user.ReferenceUserId.Value)) : null,
            Username = user.Username,
            EmployeeCode = user.UserBranches.Where(ub => ub.IsActive).Select(ub => ub.EmployeeCode).FirstOrDefault() ?? string.Empty,
            Email = user.Email,
            FirstName = user.FirstName ?? string.Empty,
            LastName = user.LastName ?? string.Empty,
            PhoneNumber = user.PhoneNumber,
            DateOfJoining = user.DateOfJoining,
            DateOfBirth = user.DateOfBirth,
            Address = user.Address,
            Pincode = user.Pincode,
            CountryName = user.Country?.CountryName,
            StateName = user.State?.StateName,
            CityName = user.City?.CityName,
            IsActive = user.IsActive,
            IsNursingStaff = user.IsNursingStaff,
            IsPhlebotomist = user.IsPhlebotomist,
            IsPathologist = user.IsPathologist,
            IsLabTechnician = user.IsLabTechnician,
            IsLogisticsBoy = user.IsLogisticsBoy,
            IsVehicleAvailable = user.IsVehicleAvailable,
            VehicleRegNo = user.VehicleRegNo,
            CertificationNo = user.CertificationNo,
            RegistrationNo = user.RegistrationNo,
            PathologistCategoryNames = await GetCategoryNamesAsync(user.PathologistCategoryIds),
            ShiftSlotId = user.ShiftSlotId,
            ShiftSlotName = shiftSlotName,
            AssignedZoneId = user.AssignedZoneId,
            AssignedZoneName = user.AssignedZone?.AreaName,
            DailyCollectionTarget = user.DailyCollectionTarget,
            LabTechnicianShiftSlotId = user.LabTechnicianShiftSlotId,
            LabTechnicianShiftSlotName = labShiftSlotName,
            AnalyzerTrainedOn = user.AnalyzerTrainedOn,
            IsLockedOut = user.IsLockedOut,
            LastLoginDate = user.LastLoginDate,
            CreatedDate = user.CreatedDate,
            LastModifiedDate = user.LastModifiedDate,
            ProfilePicturePath = user.ProfilePicturePath,
            HasSignature = !string.IsNullOrWhiteSpace(user.SignaturePath),
            Branches = user.UserBranches.Select(b => b.Branch.BranchName).ToList(),
            DepartmentNames = departmentNames,
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
        NormalizeBranchRoles(model);
        if (!CanManage())
        {
            return RedirectToAction("Index", "Dashboard");
        }

        if (string.IsNullOrWhiteSpace(model.Password))
        {
            ModelState.AddModelError(nameof(model.Password), "Password is required.");
        }

        // sign-in is by e-mail (SQLScripts/2307): the e-mail is required and the user name is the e-mail
        RequireEmail(model);
        model.Username = (model.Email ?? "").Trim().ToLowerInvariant();
        ModelState.Remove(nameof(model.Username));
        if (model.Username.Length > 0 && await dbContext.Users.AnyAsync(x => x.Username == model.Username))
        {
            ModelState.AddModelError(nameof(model.Email), "This e-mail is already used as a sign-in.");
        }

        if (!model.SelectedBranchIds.Any())
        {
            ModelState.AddModelError(nameof(model.SelectedBranchIds), "Select at least one branch.");
        }

        if (model.IsPhlebotomist && string.IsNullOrWhiteSpace(model.CertificationNo))
        {
            ModelState.AddModelError(nameof(model.CertificationNo), "Certification No is mandatory when designated as Phlebotomist.");
        }

        if (model.IsPathologist && string.IsNullOrWhiteSpace(model.RegistrationNo))
        {
            ModelState.AddModelError(nameof(model.RegistrationNo), "Registration No is mandatory when designated as Pathologist.");
        }

        await ValidatePathologistCategoriesAsync(model);

        if (model.IsLogisticsBoy && string.IsNullOrWhiteSpace(model.VehicleRegNo))
        {
            ModelState.AddModelError(nameof(model.VehicleRegNo), "Vehicle Reg No is mandatory when designated as Logistics Boy.");
        }

        await ValidateEmployeeCodeUniquenessAsync(model);
        await ValidateContactUniquenessAsync(model, User.GetCompanyId(), null, null);
        await ValidateReportsToAsync(model, User.GetCompanyId());
        ValidateProfilePicture(model);
        await ValidateSignatureAsync(model);

        if (!ModelState.IsValid)
        {
            await PopulateSelections(model);
            return View(model);
        }

        var normalizedEmployeeCode = string.IsNullOrWhiteSpace(model.EmployeeCode)
            ? null
            : model.EmployeeCode.Trim().ToUpperInvariant();
        var profilePicturePath = await SaveProfilePictureAsync(model.ProfilePictureFile, null);
        var signaturePath = await ApplySignatureAsync(model, null);

        var (hash, salt) = passwordHasherService.HashPassword(model.Password!);
        var deptIds = (model.SelectedDepartmentIds != null && model.SelectedDepartmentIds.Any())
            ? string.Join(",", model.SelectedDepartmentIds.Distinct().OrderBy(id => id))
            : null;

        var user = new User
        {
            CompanyId = User.GetCompanyId(),
            Username = model.Username,
            Email = model.Email?.Trim().ToLowerInvariant(),
            PasswordHash = hash,
            Salt = salt,
            FirstName = model.FirstName.Trim(),
            LastName = model.LastName.Trim(),
            FullName = string.Concat(model.FirstName.Trim(), " ", model.LastName.Trim()),
            PhoneNumber = model.PhoneNumber,
            Phone = model.PhoneNumber,
            ReportsToUserId = model.ReportsToUserId > 0 ? model.ReportsToUserId : null,
            DateOfJoining = model.DateOfJoining,
            DateOfBirth = model.DateOfBirth,
            Address = model.Address?.Trim(),
            Pincode = model.Pincode?.Trim(),
            CountryId = model.CountryId > 0 ? model.CountryId : null,
            StateId = model.StateId > 0 ? model.StateId : null,
            CityId = model.CityId > 0 ? model.CityId : null,
            ProfilePicturePath = profilePicturePath,
            SignaturePath = signaturePath,
            DepartmentIds = deptIds,
            IsActive = model.IsActive,
            IsNursingStaff = model.IsNursingStaff,
            IsPhlebotomist = model.IsPhlebotomist,
            IsPathologist = model.IsPathologist,
            IsLabTechnician = model.IsLabTechnician,
            IsLogisticsBoy = model.IsLogisticsBoy,
            IsVehicleAvailable = model.IsLogisticsBoy && model.IsVehicleAvailable,
            VehicleRegNo = model.IsLogisticsBoy ? model.VehicleRegNo?.Trim() : null,
            CertificationNo = model.IsPhlebotomist ? model.CertificationNo?.Trim() : null,
            RegistrationNo = model.IsPathologist ? model.RegistrationNo?.Trim() : null,
            PathologistCategoryIds = PathologistCategoryCsv(model),
            ShiftSlotId = model.IsPhlebotomist && model.ShiftSlotId > 0 ? model.ShiftSlotId : null,
            AssignedZoneId = model.IsPhlebotomist && model.AssignedZoneId > 0 ? model.AssignedZoneId : null,
            DailyCollectionTarget = model.IsPhlebotomist ? model.DailyCollectionTarget : null,
            LabTechnicianShiftSlotId = model.IsLabTechnician && model.LabTechnicianShiftSlotId > 0 ? model.LabTechnicianShiftSlotId : null,
            AnalyzerTrainedOn = model.IsLabTechnician ? model.AnalyzerTrainedOn?.Trim() : null,
            UserType = UserTypes.General,          // created in User Master (logins of other masters are created there)
            ReferenceUserId = null,
            PasswordLastChanged = DateTime.Now,
            CreatedDate = DateTime.Now,
            LastModifiedDate = DateTime.Now,
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
        if (!await MaySeeUserAsync(id)) return NotFound();

        var user = await dbContext.Users
            .Include(x => x.UserBranches)
            .Include(x => x.UserRoles)
            .FirstOrDefaultAsync(x => x.Id == id);

        if (user is null)
        {
            return NotFound();
        }

        var selectedDeptIds = new List<int>();
        if (!string.IsNullOrWhiteSpace(user.DepartmentIds))
        {
            selectedDeptIds = user.DepartmentIds.Split(',', StringSplitOptions.RemoveEmptyEntries)
                .Select(s => int.TryParse(s.Trim(), out var did) ? did : 0)
                .Where(did => did > 0)
                .ToList();
        }

        var editRefNames = await ReferenceNamesAsync(new[] { (user.UserType, user.ReferenceUserId) });
        var model = new UserFormViewModel
        {
            Id = user.Id,
            UserType = user.UserType,
            ReferenceUserId = user.ReferenceUserId,
            ReferenceName = user.ReferenceUserId.HasValue ? editRefNames.GetValueOrDefault((user.UserType, user.ReferenceUserId.Value)) : null,
            Username = user.Username,
            Email = user.Email,
            FirstName = user.FirstName ?? string.Empty,
            LastName = user.LastName ?? string.Empty,
            PhoneNumber = user.PhoneNumber,
            ReportsToUserId = user.ReportsToUserId,
            EmployeeCode = user.UserBranches.Where(x => x.IsActive).Select(x => x.EmployeeCode).FirstOrDefault() ?? string.Empty,
            ExistingProfilePicturePath = user.ProfilePicturePath,
            ExistingSignaturePath = user.SignaturePath,
            DateOfJoining = user.DateOfJoining,
            DateOfBirth = user.DateOfBirth,
            Address = user.Address,
            Pincode = user.Pincode,
            CountryId = user.CountryId,
            StateId = user.StateId,
            CityId = user.CityId,
            IsActive = user.IsActive,
            IsNursingStaff = user.IsNursingStaff,
            IsPhlebotomist = user.IsPhlebotomist,
            IsPathologist = user.IsPathologist,
            IsLabTechnician = user.IsLabTechnician,
            IsLogisticsBoy = user.IsLogisticsBoy,
            IsVehicleAvailable = user.IsVehicleAvailable,
            VehicleRegNo = user.VehicleRegNo,
            CertificationNo = user.CertificationNo,
            RegistrationNo = user.RegistrationNo,
            ShiftSlotId = user.ShiftSlotId,
            AssignedZoneId = user.AssignedZoneId,
            DailyCollectionTarget = user.DailyCollectionTarget,
            LabTechnicianShiftSlotId = user.LabTechnicianShiftSlotId,
            AnalyzerTrainedOn = user.AnalyzerTrainedOn,
            SelectedBranchIds = user.UserBranches.Where(x => x.IsActive).Select(x => x.BranchId).ToList(),
            SelectedRoleIds = user.UserRoles.Where(x => x.IsActive).Select(x => x.RoleId).ToList(),
            SelectedBranchRoles = user.UserRoles.Where(x => x.IsActive)
                .SelectMany(r => r.Branch_ID.HasValue
                    ? new[] { $"{r.Branch_ID}:{r.RoleId}" }
                    : user.UserBranches.Where(b => b.IsActive).Select(b => $"{b.BranchId}:{r.RoleId}"))
                .Distinct().ToList(),
            SelectedDepartmentIds = selectedDeptIds,
            SelectedTestCategoryIds = ParseIdCsv(user.PathologistCategoryIds)
        };

        await PopulateSelections(model);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(UserFormViewModel model)
    {
        NormalizeBranchRoles(model);
        if (!CanManage())
        {
            return RedirectToAction("Index", "Dashboard");
        }

        if (!await MaySeeUserAsync(model.Id)) return NotFound();
        var user = await dbContext.Users.FirstOrDefaultAsync(x => x.Id == model.Id);
        if (user is null)
        {
            return NotFound();
        }

        // A login created from another master (doctor / franchise / company): its username, name, e-mail, phone and
        // active status are maintained there - whatever the form sends for them is replaced by the stored values.
        model.UserType = user.UserType;
        model.ReferenceUserId = user.ReferenceUserId;
        if (model.IsLinkedLogin)
        {
            var refNames = await ReferenceNamesAsync(new[] { (user.UserType, user.ReferenceUserId) });
            model.ReferenceName = refNames.GetValueOrDefault((user.UserType, user.ReferenceUserId!.Value));
            model.Username = user.Username;
            model.FirstName = user.FirstName ?? string.Empty;
            model.LastName = user.LastName ?? string.Empty;
            if (!model.EmailEditable)   // a doctor login's e-mail is changed here too (Doctor Master follows), SQLScripts/2307
            {
                model.Email = user.Email;
                ModelState.Remove(nameof(model.Email));
            }
            model.PhoneNumber = user.PhoneNumber;
            model.IsActive = user.IsActive;
            ModelState.Remove(nameof(model.Username));
            ModelState.Remove(nameof(model.FirstName));
            ModelState.Remove(nameof(model.LastName));
            ModelState.Remove(nameof(model.PhoneNumber));
        }

        // the user name is not edited any more (sign-in is by e-mail, SQLScripts/2307): it follows the e-mail when it was
        // the e-mail (users created since), otherwise the existing user name stays as it is
        if (model.EmailEditable)
        {
            // user name = e-mail, on create and on edit; an older user whose e-mail is shared keeps the user name while
            // another user holds that e-mail as user name and the e-mail is unchanged (it must be unique once changed)
            RequireEmail(model);
            var newEmail = model.Email?.Trim().ToLowerInvariant() ?? "";
            var unchanged = string.Equals(newEmail, user.Email?.Trim(), StringComparison.OrdinalIgnoreCase);
            model.Username = newEmail.Length == 0
                || (unchanged && await dbContext.Users.AnyAsync(x => x.Id != user.Id && x.Username == newEmail))
                ? user.Username : newEmail;
            ModelState.Remove(nameof(model.Username));
        }
        if (await dbContext.Users.AnyAsync(x => x.Id != model.Id && x.Username == model.Username))
        {
            ModelState.AddModelError(nameof(model.Email), "This e-mail is already used as a sign-in.");
        }

        if (!model.SelectedBranchIds.Any())
        {
            ModelState.AddModelError(nameof(model.SelectedBranchIds), "Select at least one branch.");
        }

        if (model.IsPhlebotomist && string.IsNullOrWhiteSpace(model.CertificationNo))
        {
            ModelState.AddModelError(nameof(model.CertificationNo), "Certification No is mandatory when designated as Phlebotomist.");
        }

        if (model.IsPathologist && string.IsNullOrWhiteSpace(model.RegistrationNo))
        {
            ModelState.AddModelError(nameof(model.RegistrationNo), "Registration No is mandatory when designated as Pathologist.");
        }

        await ValidatePathologistCategoriesAsync(model);

        if (model.IsLogisticsBoy && string.IsNullOrWhiteSpace(model.VehicleRegNo))
        {
            ModelState.AddModelError(nameof(model.VehicleRegNo), "Vehicle Reg No is mandatory when designated as Logistics Boy.");
        }

        await ValidateEmployeeCodeUniquenessAsync(model);
        // e-mail / phone: checked when changed (existing records may already share them); a linked login keeps its own
        await ValidateContactUniquenessAsync(model, user.CompanyId ?? User.GetCompanyId(), user.Email, user.PhoneNumber);
        await ValidateReportsToAsync(model, user.CompanyId ?? User.GetCompanyId());
        ValidateProfilePicture(model);
        await ValidateSignatureAsync(model);

        if (!ModelState.IsValid)
        {
            model.ExistingSignaturePath = user.SignaturePath;   // the stored file is unchanged; keep showing it
            await PopulateSelections(model);
            return View(model);
        }

        var normalizedEmployeeCode = string.IsNullOrWhiteSpace(model.EmployeeCode)
            ? null
            : model.EmployeeCode.Trim().ToUpperInvariant();

        // a doctor's login: the e-mail (and a user name that is the e-mail) can change here - the doctor's e-mail follows
        if (model.IsLinkedLogin && model.UserType == UserTypes.Doctor && user.ReferenceUserId is int doctorId)
        {
            user.Username = model.Username.Trim();
            user.Email = model.Email?.Trim().ToLowerInvariant();
            var doctor = await dbContext.DoctorMasters.FirstOrDefaultAsync(d => d.DoctorId == doctorId);
            if (doctor is not null) doctor.EmailId = user.Email ?? doctor.EmailId;
        }
        if (!model.IsLinkedLogin)
        {
            user.Username = model.Username.Trim();
            user.Email = model.Email?.Trim().ToLowerInvariant();
            user.FirstName = model.FirstName.Trim();
            user.LastName = model.LastName.Trim();
            user.FullName = string.Concat(model.FirstName.Trim(), " ", model.LastName.Trim());
            user.PhoneNumber = model.PhoneNumber;
            user.Phone = model.PhoneNumber;
        }
        user.ReportsToUserId = model.ReportsToUserId > 0 ? model.ReportsToUserId : null;
        user.DateOfJoining = model.DateOfJoining;
        user.DateOfBirth = model.DateOfBirth;
        user.Address = model.Address?.Trim();
        user.Pincode = model.Pincode?.Trim();
        user.CountryId = model.CountryId > 0 ? model.CountryId : null;
        user.StateId = model.StateId > 0 ? model.StateId : null;
        user.CityId = model.CityId > 0 ? model.CityId : null;
        user.DepartmentIds = (model.SelectedDepartmentIds != null && model.SelectedDepartmentIds.Any())
            ? string.Join(",", model.SelectedDepartmentIds.Distinct().OrderBy(id => id))
            : null;
        if (!model.IsLinkedLogin) user.IsActive = model.IsActive;
        user.IsNursingStaff = model.IsNursingStaff;
        user.IsPhlebotomist = model.IsPhlebotomist;
        user.IsPathologist = model.IsPathologist;
        user.IsLabTechnician = model.IsLabTechnician;
        user.IsLogisticsBoy = model.IsLogisticsBoy;
        user.IsVehicleAvailable = model.IsLogisticsBoy && model.IsVehicleAvailable;
        user.VehicleRegNo = model.IsLogisticsBoy ? model.VehicleRegNo?.Trim() : null;
        user.CertificationNo = model.IsPhlebotomist ? model.CertificationNo?.Trim() : null;
        user.RegistrationNo = model.IsPathologist ? model.RegistrationNo?.Trim() : null;
        user.PathologistCategoryIds = PathologistCategoryCsv(model);
        user.ShiftSlotId = model.IsPhlebotomist && model.ShiftSlotId > 0 ? model.ShiftSlotId : null;
        user.AssignedZoneId = model.IsPhlebotomist && model.AssignedZoneId > 0 ? model.AssignedZoneId : null;
        user.DailyCollectionTarget = model.IsPhlebotomist ? model.DailyCollectionTarget : null;
        user.LabTechnicianShiftSlotId = model.IsLabTechnician && model.LabTechnicianShiftSlotId > 0 ? model.LabTechnicianShiftSlotId : null;
        user.AnalyzerTrainedOn = model.IsLabTechnician ? model.AnalyzerTrainedOn?.Trim() : null;
        user.LastModifiedDate = DateTime.Now;

        user.ProfilePicturePath = await SaveProfilePictureAsync(model.ProfilePictureFile, user.ProfilePicturePath);
        user.SignaturePath = await ApplySignatureAsync(model, user.SignaturePath);

        if (!string.IsNullOrWhiteSpace(model.Password))
        {
            var (hash, salt) = passwordHasherService.HashPassword(model.Password);
            user.PasswordHash = hash;
            user.Salt = salt;
            user.PasswordLastChanged = DateTime.Now;
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

        if (!await MaySeeUserAsync(id)) return NotFound();
        var user = await dbContext.Users.FirstOrDefaultAsync(x => x.Id == id);
        if (user is null)
        {
            return NotFound();
        }

        if (user.UserType != UserTypes.General && user.ReferenceUserId.HasValue)
        {
            TempData["Error"] = user.UserType == UserTypes.Doctor
                ? $"'{user.Username}' is a doctor's login - switch it on or off in Doctor Master (Login Account)."
                : $"'{user.Username}' is the login of a {UserTypes.Label(user.UserType).ToLowerInvariant()} - switch it on or off where it was created.";
            return RedirectToAction(nameof(Index));
        }

        user.IsActive = !user.IsActive;
        user.LastModifiedDate = DateTime.Now;
        await dbContext.SaveChangesAsync();
        await auditLogService.LogAsync("MasterData", "Users.ToggleStatus", $"Toggled user status: {user.Username} => {(user.IsActive ? "Active" : "Inactive")}", user.Id);
        TempData["Success"] = "User status updated.";

        return RedirectToAction(nameof(Index));
    }

    /// <summary>Names of the records logins belong to: doctor (Doctor Master), franchise, company.</summary>
    private async Task<Dictionary<(string Type, int Id), string>> ReferenceNamesAsync(IEnumerable<(string Type, int? Id)> refs)
    {
        var list = refs.Where(r => r.Id.HasValue && r.Type != UserTypes.General).Select(r => (r.Type, Id: r.Id!.Value)).Distinct().ToList();
        var names = new Dictionary<(string, int), string>();
        var doctorIds = list.Where(r => r.Type == UserTypes.Doctor).Select(r => r.Id).ToList();
        if (doctorIds.Count > 0)
            foreach (var d in await dbContext.DoctorMasters.AsNoTracking().Where(d => doctorIds.Contains(d.DoctorId))
                         .Select(d => new { d.DoctorId, d.NamePrefix, d.FullName }).ToListAsync())
                names[(UserTypes.Doctor, d.DoctorId)] = string.IsNullOrWhiteSpace(d.NamePrefix) ? d.FullName : $"{d.NamePrefix} {d.FullName}";
        var companyIds = list.Where(r => r.Type == UserTypes.Company).Select(r => r.Id).ToList();
        if (companyIds.Count > 0)
            foreach (var c in await dbContext.CorporateMasters.AsNoTracking().Where(c => companyIds.Contains(c.Corporate_ID))
                         .Select(c => new { c.Corporate_ID, c.Corporate_Name }).ToListAsync())
                names[(UserTypes.Company, c.Corporate_ID)] = c.Corporate_Name;
        var franchiseIds = list.Where(r => r.Type == UserTypes.Franchise).Select(r => r.Id).ToList();
        if (franchiseIds.Count > 0)
            foreach (var f in await dbContext.Database.GetDbConnection().QueryAsync<(int Id, string Name)>(
                         "SELECT Franchise_ID, Franchise_Name FROM dbo.LabFranchiseMaster WHERE Franchise_ID IN @franchiseIds", new { franchiseIds }))
                names[(UserTypes.Franchise, f.Id)] = f.Name;
        return names;
    }

    // ── AJAX Cascade Endpoints for Dependable Dropdowns ───────────
    [HttpGet]
    public async Task<IActionResult> GetStatesByCountry(int countryId)
    {
        var states = await stateService.GetByCountryAsync(countryId);
        return Json(states.Where(s => s.IsActive).OrderBy(s => s.StateName).Select(s => new { s.StateId, s.StateName }));
    }

    [HttpGet]
    public async Task<IActionResult> GetCitiesByState(int stateId)
    {
        var cities = await cityService.GetByStateAsync(stateId);
        return Json(cities.Where(c => c.IsActive).OrderBy(c => c.CityName).Select(c => new { c.CityId, c.CityName }));
    }

    [HttpGet]
    public async Task<IActionResult> GetAreasByCity(int cityId)
    {
        var areas = await areaService.GetByCityAsync(cityId);
        return Json(areas.Where(a => a.IsActive).OrderBy(a => a.AreaName).Select(a => new { a.AreaId, a.AreaName, a.AreaCode }));
    }

    /// <summary>Splits a stored CSV of ids ("3,7,11") into a list, ignoring anything unparseable.</summary>
    private static List<int> ParseIdCsv(string? csv) =>
        string.IsNullOrWhiteSpace(csv)
            ? new List<int>()
            : csv.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                 .Select(x => int.TryParse(x, out var id) ? id : 0)
                 .Where(id => id > 0)
                 .Distinct()
                 .ToList();

    /// <summary>Categories are kept only while the user is a pathologist.</summary>
    private static string? PathologistCategoryCsv(UserFormViewModel model)
    {
        if (!model.IsPathologist || model.SelectedTestCategoryIds == null || model.SelectedTestCategoryIds.Count == 0)
            return null;

        return string.Join(",", model.SelectedTestCategoryIds.Distinct().OrderBy(id => id));
    }

    /// <summary>
    /// The posted categories must exist and must belong to a department the user has access to.
    /// Checked on the server so the rule holds regardless of what the browser sent.
    /// </summary>
    private async Task ValidatePathologistCategoriesAsync(UserFormViewModel model)
    {
        if (!model.IsPathologist || model.SelectedTestCategoryIds == null || model.SelectedTestCategoryIds.Count == 0)
            return;

        // The field error sits inside the Pathologist popup (closed after a post-back), so the same message
        // is also added at model level to reach the summary at the top of the page.
        void Fail(string message)
        {
            ModelState.AddModelError(nameof(model.SelectedTestCategoryIds), message);
            ModelState.AddModelError(string.Empty, message);
        }

        if (model.SelectedDepartmentIds == null || model.SelectedDepartmentIds.Count == 0)
        {
            Fail("Select at least one Department Access before assigning Test Categories to a Pathologist.");
            return;
        }

        try
        {
            var allowedIds = (await labTestCategoryApiClient.GetByDepartmentsAsync(
                    string.Join(",", model.SelectedDepartmentIds.Distinct()), User.GetCompanyId()))
                .Select(x => x.CategoryId)
                .ToHashSet();

            if (model.SelectedTestCategoryIds.Any(id => !allowedIds.Contains(id)))
            {
                Fail("One or more selected Test Categories do not belong to the departments granted to this user. Please re-select.");
            }
        }
        catch (HttpRequestException)
        {
            Fail("Test Categories could not be verified because the lab service is unreachable. Please try again.");
        }
    }

    /// <summary>Names of the assigned categories, for the read-only Details page.</summary>
    private async Task<List<string>> GetCategoryNamesAsync(string? categoryIdCsv)
    {
        var ids = ParseIdCsv(categoryIdCsv);
        if (ids.Count == 0) return new List<string>();

        try
        {
            var all = await labTestCategoryApiClient.GetByDepartmentsAsync(null, User.GetCompanyId());
            return all.Where(c => ids.Contains(c.CategoryId))
                      .Select(c => string.IsNullOrWhiteSpace(c.DepartmentName) ? c.CategoryName : $"{c.CategoryName} ({c.DepartmentName})")
                      .ToList();
        }
        catch (HttpRequestException)
        {
            return new List<string>();   // the page still renders without the names
        }
    }

    /// <summary>Categories of the given departments - feeds the Pathologist Configuration dropdown.</summary>
    [HttpGet]
    public async Task<IActionResult> GetTestCategoriesByDepartments(string? departmentIds)
    {
        var ids = ParseIdCsv(departmentIds);
        if (ids.Count == 0)
            return Json(new { success = true, categories = Array.Empty<object>() });

        try
        {
            var categories = await labTestCategoryApiClient.GetByDepartmentsAsync(
                string.Join(",", ids), User.GetCompanyId());

            return Json(new
            {
                success = true,
                categories = categories.Select(c => new
                {
                    categoryId = c.CategoryId,
                    categoryName = c.CategoryName,
                    departmentId = c.DepartmentId,
                    departmentName = c.DepartmentName
                })
            });
        }
        catch (HttpRequestException)
        {
            return Json(new { success = false, message = "The lab service is unreachable. Please try again." });
        }
    }

    private async Task PopulateSelections(UserFormViewModel model)
    {
        // Reports To: the active users of the company (the one already chosen stays listed even if inactive), not the user
        var companyId = User.GetCompanyId();
        var reportsTo = await dbContext.Users.AsNoTracking()
            .Where(u => u.CompanyId == companyId && u.Id != model.Id && (u.IsActive || u.Id == model.ReportsToUserId))
            .Select(u => new { u.Id, u.FullName, u.FirstName, u.LastName, u.Username, u.IsActive })
            .ToListAsync();
        model.ReportsToOptions = reportsTo
            .Select(u => new { u.Id, Name = !string.IsNullOrWhiteSpace(u.FullName) ? u.FullName.Trim() : $"{u.FirstName} {u.LastName}".Trim(), u.Username, u.IsActive })
            .OrderBy(u => string.IsNullOrWhiteSpace(u.Name) ? u.Username : u.Name)
            .Select(u => new SelectListItem(
                (string.IsNullOrWhiteSpace(u.Name) ? u.Username : $"{u.Name} ({u.Username})") + (u.IsActive ? "" : " - inactive"),
                u.Id.ToString(), u.Id == model.ReportsToUserId))
            .ToList();

        var branches = await dbContext.BranchMasters
            .Where(x => x.IsActive)
            .OrderBy(x => x.BranchName)
            .Select(x => new { x.BranchId, x.BranchName, x.BranchCode })
            .ToListAsync();

        model.BranchOptions = branches
            .Select(x => new SelectListItem(
                string.IsNullOrWhiteSpace(x.BranchCode)
                    ? x.BranchName
                    : $"{x.BranchCode} - {x.BranchName}",
                x.BranchId.ToString()))
            .ToList();

        var departments = await dbContext.DepartmentMasters
            .Where(x => x.IsActive)
            .OrderBy(x => x.DeptName)
            .Select(x => new { x.DeptId, x.DeptCode, x.DeptName, x.DeptType })
            .ToListAsync();

        model.DepartmentOptions = departments
            .Select(x => new SelectListItem(
                string.IsNullOrWhiteSpace(x.DeptCode)
                    ? x.DeptName
                    : $"{x.DeptName} ({x.DeptCode})",
                x.DeptId.ToString()))
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

        var countries = await countryService.GetActiveAsync();
        model.CountryOptions = countries
            .OrderBy(c => c.CountryName)
            .Select(c => new SelectListItem(c.CountryName, c.CountryId.ToString(), model.CountryId.HasValue && c.CountryId == model.CountryId.Value))
            .ToList();

        if (model.CountryId.HasValue && model.CountryId.Value > 0)
        {
            var states = await stateService.GetByCountryAsync(model.CountryId.Value);
            model.StateOptions = states
                .Where(s => s.IsActive)
                .OrderBy(s => s.StateName)
                .Select(s => new SelectListItem(s.StateName, s.StateId.ToString(), model.StateId.HasValue && s.StateId == model.StateId.Value))
                .ToList();
        }

        if (model.StateId.HasValue && model.StateId.Value > 0)
        {
            var cities = await cityService.GetByStateAsync(model.StateId.Value);
            model.CityOptions = cities
                .Where(c => c.IsActive)
                .OrderBy(c => c.CityName)
                .Select(c => new SelectListItem(c.CityName, c.CityId.ToString(), model.CityId.HasValue && c.CityId == model.CityId.Value))
                .ToList();
        }

        // Shift Slot options for Pathologist
        var shifts = await dbContext.ShiftMasters
            .Where(s => s.Status)
            .OrderBy(s => s.ShiftName)
            .ToListAsync();

        model.ShiftSlotOptions = shifts
            .Select(s => new SelectListItem(
                $"{s.ShiftName} ({s.ShiftCode}) [{s.StartTime:hh\\:mm} - {s.EndTime:hh\\:mm}]",
                s.ShiftMaster_ID.ToString(),
                model.ShiftSlotId.HasValue && s.ShiftMaster_ID == model.ShiftSlotId.Value))
            .ToList();

        // Shift Slot options for Lab Technician
        model.LabShiftSlotOptions = shifts
            .Select(s => new SelectListItem(
                $"{s.ShiftName} ({s.ShiftCode}) [{s.StartTime:hh\\:mm} - {s.EndTime:hh\\:mm}]",
                s.ShiftMaster_ID.ToString(),
                model.LabTechnicianShiftSlotId.HasValue && s.ShiftMaster_ID == model.LabTechnicianShiftSlotId.Value))
            .ToList();

        // Standard LAB related Analyzers
        var standardAnalyzers = new[]
        {
            "Fully Automated Biochemistry Analyzer (Roche Cobas / Beckman Coulter AU)",
            "Semi-Automated Biochemistry Analyzer (Erba / Mindray)",
            "5-Part Differential Hematology Analyzer (Sysmex XN / Mindray BC-6000)",
            "3-Part Hematology Cell Counter (Mindray BC-3000 / Nihon Kohden)",
            "Automated Immunoassay & Chemiluminescence (CLIA) Analyzer (Abbott Architect / Roche Elecsys)",
            "Arterial Blood Gas (ABG) & Electrolyte Analyzer (Radiometer ABL / Nova Biomedical)",
            "Automated Coagulation Analyzer (Stago STA Compact / Sysmex CS)",
            "Automated Urine Chemistry & Sediment Analyzer (Dirui / Sysmex UC)",
            "Molecular Diagnostics & Real-Time PCR (Bio-Rad CFX / GeneXpert)",
            "ELISA Microplate Reader & Automated Washer",
            "Microbiology Automated Microbial Identification & AST (bioMérieux VITEK 2 / BD Phoenix)",
            "High Performance Liquid Chromatography (HPLC) HbA1c Analyzer"
        };

        model.LabAnalyzerOptions = standardAnalyzers
            .Select(a => new SelectListItem(a, a, !string.IsNullOrWhiteSpace(model.AnalyzerTrainedOn) && string.Equals(model.AnalyzerTrainedOn, a, StringComparison.OrdinalIgnoreCase)))
            .ToList();

        // Area options for Phlebotomist Assigned Zone
        if (model.CityId.HasValue && model.CityId.Value > 0)
        {
            var areas = await areaService.GetByCityAsync(model.CityId.Value);
            model.AssignedZoneOptions = areas
                .Where(a => a.IsActive)
                .OrderBy(a => a.AreaName)
                .Select(a => new SelectListItem(
                    string.IsNullOrWhiteSpace(a.AreaCode) ? a.AreaName : $"{a.AreaName} ({a.AreaCode})",
                    a.AreaId.ToString(),
                    model.AssignedZoneId.HasValue && a.AreaId == model.AssignedZoneId.Value))
                .ToList();
        }
        else if (model.AssignedZoneId.HasValue && model.AssignedZoneId.Value > 0)
        {
            var area = await areaService.GetByIdAsync(model.AssignedZoneId.Value);
            if (area != null)
            {
                model.AssignedZoneOptions = new List<SelectListItem>
                {
                    new SelectListItem(
                        string.IsNullOrWhiteSpace(area.AreaCode) ? area.AreaName : $"{area.AreaName} ({area.AreaCode})",
                        area.AreaId.ToString(),
                        true)
                };
            }
        }
    }

    /// <summary>The ticked (branch, role) pairs, limited to branches the user is actually mapped to.</summary>
    private static List<(int BranchId, int RoleId)> ParseBranchRoles(UserFormViewModel model)
    {
        var branches = model.SelectedBranchIds.ToHashSet();
        return model.SelectedBranchRoles
            .Select(v => v.Split(':'))
            .Where(p => p.Length == 2 && int.TryParse(p[0], out _) && int.TryParse(p[1], out _))
            .Select(p => (BranchId: int.Parse(p[0]), RoleId: int.Parse(p[1])))
            .Where(p => branches.Contains(p.BranchId))
            .Distinct()
            .ToList();
    }

    /// <summary>Keeps SelectedRoleIds (used by validation and the form) in step with the posted branch-role pairs.</summary>
    private static void NormalizeBranchRoles(UserFormViewModel model)
    {
        model.SelectedRoleIds = ParseBranchRoles(model).Select(p => p.RoleId).Distinct().ToList();
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
                CreatedDate = DateTime.Now,
                ModifiedDate = DateTime.Now,
                CreatedBy = User.GetUserId(),
                ModifiedBy = User.GetUserId()
            });
        dbContext.UserBranches.AddRange(branchMappings);

        var existingRoles = await dbContext.UserRoles.Where(x => x.UserId == userId).ToListAsync();
        dbContext.UserRoles.RemoveRange(existingRoles);

        // Roles are branch-scoped: each ticked role applies only in the branch whose tab it was ticked on.
        var roleMappings = ParseBranchRoles(model)
            .Select(br => new UserRole
            {
                UserId = userId,
                RoleId = br.RoleId,
                Branch_ID = br.BranchId,
                IsActive = true,
                AssignedDate = DateTime.Now,
                AssignedBy = User.GetUserId(),
                CreatedDate = DateTime.Now,
                CreatedBy = User.GetUserId(),
                ModifiedDate = DateTime.Now,
                ModifiedBy = User.GetUserId()
            });
        dbContext.UserRoles.AddRange(roleMappings);
    }

    /// <summary>
    /// E-mail and phone number are unique within the company (SQLScripts/2305): e-mail ignoring case and spaces, phone by
    /// its last 10 digits (so 09007524092 and 9007524092 are the same number). On edit a value is checked only when it is
    /// changed, so records that already share one can still be saved.
    /// </summary>
    private async Task ValidateContactUniquenessAsync(UserFormViewModel model, int? companyId, string? storedEmail, string? storedPhone)
    {
        static string Phone10(string? phone)
        {
            var digits = new string((phone ?? "").Where(char.IsDigit).ToArray());
            return digits.Length > 10 ? digits[^10..] : digits;
        }

        var email = model.Email?.Trim();
        if (!string.IsNullOrEmpty(email)
            && !string.Equals(email, storedEmail?.Trim(), StringComparison.OrdinalIgnoreCase))
        {
            // e-mail is the sign-in: unique in the whole application (SQLScripts/2307)
            var lower = email.ToLower();
            var taken = await dbContext.Users.AsNoTracking()
                .Where(u => u.Id != model.Id && u.Email != null && u.Email.Trim().ToLower() == lower)
                .Select(u => new { u.Username, u.CompanyId }).FirstOrDefaultAsync();
            if (taken is not null)
                ModelState.AddModelError(nameof(model.Email), taken.CompanyId == companyId
                    ? $"This e-mail is already used by user '{taken.Username}'."
                    : "This e-mail is already registered to another account.");
        }

        var phone = Phone10(model.PhoneNumber);
        if (phone.Length > 0 && phone != Phone10(storedPhone))
        {
            // compared in memory by the last 10 digits (numbers are stored with or without a leading 0 / +91)
            var tail = phone.Length >= 6 ? phone[^6..] : phone;
            var candidates = await dbContext.Users.AsNoTracking()
                .Where(u => u.CompanyId == companyId && u.Id != model.Id && u.PhoneNumber != null && u.PhoneNumber.Contains(tail))
                .Select(u => new { u.Username, u.PhoneNumber }).ToListAsync();
            var taken = candidates.FirstOrDefault(u => Phone10(u.PhoneNumber) == phone);
            if (taken is not null)
                ModelState.AddModelError(nameof(model.PhoneNumber), $"This phone number is already used by user '{taken.Username}' in this company.");
        }
    }

    private void RequireEmail(UserFormViewModel model)
    {
        if (string.IsNullOrWhiteSpace(model.Email))
            ModelState.AddModelError(nameof(model.Email), "E-mail is required - it is used to sign in.");
    }

    /// <summary>
    /// User Master: is this e-mail free to sign in with? (SQLScripts/2307) Checked while typing; the save checks again.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> CheckEmail(string? email, int id = 0)
    {
        if (!CanManage()) return Forbid();
        var e = (email ?? "").Trim();
        if (e.Length == 0) return Json(new { valid = false, available = false, message = "" });
        if (e.Length > 100 || !new System.ComponentModel.DataAnnotations.EmailAddressAttribute().IsValid(e) || !e.Contains('.'))
            return Json(new { valid = false, available = false, message = "Enter a valid e-mail address." });
        var lower = e.ToLower();
        var taken = await dbContext.Users.AsNoTracking()
            .Where(u => u.Id != id && ((u.Email != null && u.Email.Trim().ToLower() == lower) || u.Username == lower))
            .Select(u => new { u.Username, u.CompanyId }).FirstOrDefaultAsync();
        if (taken is null) return Json(new { valid = true, available = true, message = "Available - this e-mail will be the sign-in." });
        return Json(new
        {
            valid = true, available = false,
            message = taken.CompanyId == User.GetCompanyId() ? $"Already used by user '{taken.Username}'." : "Already registered to another account."
        });
    }

    /// <summary>Reports To (SQLScripts/2305): a user of the same company, not the user itself, and no reporting loop.</summary>
    private async Task ValidateReportsToAsync(UserFormViewModel model, int? companyId)
    {
        if (model.ReportsToUserId is not > 0) { model.ReportsToUserId = null; return; }
        if (model.ReportsToUserId == model.Id)
        {
            ModelState.AddModelError(nameof(model.ReportsToUserId), "A user cannot report to himself / herself.");
            return;
        }
        if (!await dbContext.Users.AnyAsync(u => u.Id == model.ReportsToUserId && u.CompanyId == companyId))
        {
            ModelState.AddModelError(nameof(model.ReportsToUserId), "Choose a user of this company.");
            return;
        }
        if (model.Id <= 0) return;   // a new user cannot be anybody's manager yet
        // walk up the chain from the chosen manager: reaching this user again would make a loop
        var seen = new HashSet<int>();
        int? cur = model.ReportsToUserId;
        while (cur is int id && seen.Add(id))
        {
            if (id == model.Id)
            {
                ModelState.AddModelError(nameof(model.ReportsToUserId), "This would make a reporting loop - the chosen user already reports (directly or through others) to this user.");
                return;
            }
            cur = await dbContext.Users.Where(u => u.Id == id).Select(u => u.ReportsToUserId).FirstOrDefaultAsync();
        }
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

    // ── Pathologist signature ─────────────────────────────────────────────────
    // Stored under App_Data/signatures (outside wwwroot, so never a public static file) and served only through
    // the authorised Signature action below.

    private const long MaxSignatureBytes = 2 * 1024 * 1024;

    private string SignatureRoot => Path.Combine(webHostEnvironment.ContentRootPath, "App_Data", "signatures");

    /// <summary>Resolves a stored name to its file. Only the file-name part is used, so a tampered value cannot escape the folder.</summary>
    private string SignatureFullPath(string storedName) => Path.Combine(SignatureRoot, Path.GetFileName(storedName));

    /// <summary>"png" / "jpg" from the file's first bytes (not from its name or the browser's content type), else null.</summary>
    private static async Task<string?> DetectSignatureTypeAsync(IFormFile file)
    {
        var header = new byte[8];
        await using var stream = file.OpenReadStream();
        var read = await stream.ReadAsync(header.AsMemory(0, header.Length));
        if (read >= 8 && header[0] == 0x89 && header[1] == 0x50 && header[2] == 0x4E && header[3] == 0x47
            && header[4] == 0x0D && header[5] == 0x0A && header[6] == 0x1A && header[7] == 0x0A) return "png";
        if (read >= 3 && header[0] == 0xFF && header[1] == 0xD8 && header[2] == 0xFF) return "jpg";
        return null;
    }

    /// <summary>A signature is only kept for pathologists; when one is uploaded it must be a real PNG / JPG of up to 2 MB.</summary>
    private async Task ValidateSignatureAsync(UserFormViewModel model)
    {
        if (!model.IsPathologist || model.SignatureFile is null || model.SignatureFile.Length == 0)
            return;

        var ext = Path.GetExtension(model.SignatureFile.FileName).ToLowerInvariant();
        if (ext is not (".png" or ".jpg" or ".jpeg"))
        {
            ModelState.AddModelError(nameof(model.SignatureFile), "Signature must be a .png, .jpg or .jpeg file.");
            return;
        }

        if (model.SignatureFile.Length > MaxSignatureBytes)
        {
            ModelState.AddModelError(nameof(model.SignatureFile), "Signature image size must be up to 2 MB.");
            return;
        }

        if (await DetectSignatureTypeAsync(model.SignatureFile) is null)
        {
            ModelState.AddModelError(nameof(model.SignatureFile), "The selected file is not a valid PNG or JPEG image.");
        }
    }

    /// <summary>
    /// Decides what the stored signature becomes: dropped when the user is not (or no longer) a pathologist, replaced when a new
    /// file was uploaded, deleted when "remove" was ticked, otherwise kept. Returns the new stored name (or null).
    /// </summary>
    private async Task<string?> ApplySignatureAsync(UserFormViewModel model, string? existing)
    {
        if (!model.IsPathologist)
        {
            DeleteSignatureIfExists(existing);
            return null;
        }

        if (model.SignatureFile is { Length: > 0 })
        {
            var type = await DetectSignatureTypeAsync(model.SignatureFile);   // already validated; re-checked here as well
            if (type is null) return existing;

            Directory.CreateDirectory(SignatureRoot);
            var fileName = $"sig_{Guid.NewGuid():N}.{type}";
            await using (var stream = new FileStream(SignatureFullPath(fileName), FileMode.CreateNew))
            {
                await model.SignatureFile.CopyToAsync(stream);
            }

            DeleteSignatureIfExists(existing);
            return fileName;
        }

        if (model.RemoveSignature)
        {
            DeleteSignatureIfExists(existing);
            return null;
        }

        return existing;
    }

    private void DeleteSignatureIfExists(string? storedName)
    {
        if (string.IsNullOrWhiteSpace(storedName)) return;

        try
        {
            var full = SignatureFullPath(storedName);
            if (System.IO.File.Exists(full)) System.IO.File.Delete(full);
        }
        catch
        {
            // a leftover file is harmless; never fail the save because of it
        }
    }

    /// <summary>The user's signature image (for the Pathologist Configuration preview and the Details page). Signed-in administrators only.</summary>
    [HttpGet]
    public async Task<IActionResult> Signature(int id)
    {
        if (!CanManage()) return NotFound();

        var companyId = User.GetCompanyId();
        var stored = await dbContext.Users.AsNoTracking()
            .Where(x => x.Id == id && (User.IsSuperAdmin() || x.CompanyId == companyId))
            .Select(x => x.SignaturePath)
            .FirstOrDefaultAsync();

        if (string.IsNullOrWhiteSpace(stored)) return NotFound();

        var full = SignatureFullPath(stored);
        if (!System.IO.File.Exists(full)) return NotFound();

        Response.Headers.CacheControl = "private, no-store";
        Response.Headers["X-Content-Type-Options"] = "nosniff";
        return PhysicalFile(full, Path.GetExtension(full).Equals(".png", StringComparison.OrdinalIgnoreCase) ? "image/png" : "image/jpeg");
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
