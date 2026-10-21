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
using EMR.Shared.Security;
using System.Text.RegularExpressions;

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
    /// <summary>Doctor Master list, paged and filtered on the server (SQLScripts/2315).</summary>
    public async Task<IActionResult> Index([FromQuery] int? doctorId = null, [FromQuery] string? search = null, [FromQuery] string? status = null,
        [FromQuery] string? referral = null, [FromQuery] string? speciality = null, [FromQuery] string? department = null,
        [FromQuery] int page = 1, [FromQuery] int pageSize = 25)
    {
        var branchId = User.GetCurrentBranchId();

        ViewBag.BranchName = branchId.HasValue
            ? (await dbContext.BranchMasters.FindAsync(branchId.Value))?.BranchName
            : null;
        ViewBag.SelectedDoctorId = doctorId;

        if (page < 1) page = 1;
        if (pageSize is not (10 or 25 or 50 or 100)) pageSize = 25;
        status = status?.Trim().ToLowerInvariant() is "active" or "inactive" ? status.Trim().ToLowerInvariant() : null;
        referral = referral?.Trim().ToLowerInvariant() is "yes" or "no" ? referral.Trim().ToLowerInvariant() : null;
        search = string.IsNullOrWhiteSpace(search) ? null : search.Trim();
        speciality = string.IsNullOrWhiteSpace(speciality) ? null : speciality.Trim();
        department = string.IsNullOrWhiteSpace(department) ? null : department.Trim();
        var oneDoctor = doctorId is > 0 ? doctorId : null;

        try
        {
            // Strictly via EMR.Api — no DB fallback
            var result = await doctorApiClient.GetPagedListAsync(User.GetCompanyId(), branchId, search, status, referral, speciality, department, oneDoctor, page, pageSize);
            // a page past the end (e.g. after narrowing the filter): show the last page
            var lastPage = Math.Max(1, (int)Math.Ceiling(result.FilteredCount / (double)pageSize));
            if (page > lastPage)
            {
                page = lastPage;
                result = await doctorApiClient.GetPagedListAsync(User.GetCompanyId(), branchId, search, status, referral, speciality, department, oneDoctor, page, pageSize);
            }
            if (oneDoctor.HasValue && result.Items.FirstOrDefault() is { } selected)
                ViewBag.SelectedDoctorName = $"{selected.FullName} ({selected.PrimarySpecialityName})";

            var model = new DoctorListPageViewModel
            {
                Items = result.Items.Select(d => new DoctorListItemViewModel
                {
                    DoctorId              = d.DoctorId,
                    FullName              = d.FullName,
                    PrimarySpecialityName = d.PrimarySpecialityName ?? string.Empty,
                    DepartmentNames       = d.DepartmentNames ?? string.Empty,
                    PhoneNumber           = d.PhoneNumber ?? string.Empty,
                    EmailId               = d.EmailId ?? string.Empty,
                    IsActive              = d.IsActive,
                    ConsultingFeeNames    = d.ConsultingFeeNames ?? string.Empty,
                    HasOPDDept            = d.HasOPDDept,
                    IsReferralDoctor      = d.IsReferralDoctor
                }).ToList(),
                TotalDoctors = result.TotalDoctors,
                ActiveDoctors = result.ActiveDoctors,
                InactiveDoctors = result.InactiveDoctors,
                OpdDoctors = result.OpdDoctors,
                WithFees = result.WithFees,
                FilteredCount = result.FilteredCount,
                Page = page,
                PageSize = pageSize,
                Search = search,
                Status = status,
                Referral = referral,
                Speciality = speciality,
                Department = department,
                DoctorId = oneDoctor,
                Specialities = result.Specialities,
                Departments = result.Departments.Select(d => (d.Name, d.Type)).ToList()
            };
            return View(model);
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
            var apiDoctors = await doctorApiClient.GetListAsync(branchId, q, companyId: User.GetCompanyId());

            var results = apiDoctors.Items.Select(d => new
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


    // ── Login account: username suggestions and availability ─────────────────
    /// <summary>
    /// Free usernames for the doctor's login, built from the doctor's name and e-mail (dr.first, first.last, ...),
    /// and - when <paramref name="check"/> is given - whether that username is free. The doctor's own login
    /// (Users 'D' for <paramref name="doctorId"/>) does not count as taken.
    /// </summary>
    [HttpGet]
    [RequiresPermission("MASTER.DOCTORS", PermissionControls.Create)]
    [RequiresPermission("MASTER.DOCTORS", PermissionControls.Edit)]
    /// <summary>
    /// Doctor Master > Login Account: is the doctor's e-mail free to sign in with? (SQLScripts/2307) Checked while typing;
    /// the save checks again. The doctor's own login is not counted.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> CheckLoginEmail(string? email, int? doctorId)
    {
        var e = (email ?? "").Trim().ToLower();
        if (e.Length == 0) return Json(new { valid = false, available = false, message = "" });
        if (e.Length > 100 || !new System.ComponentModel.DataAnnotations.EmailAddressAttribute().IsValid(e) || !e.Contains('.'))
            return Json(new { valid = false, available = false, message = e.Length > 100 ? "Up to 100 characters for a login e-mail." : "Enter a valid e-mail address." });
        int? ownUserId = null;
        if (doctorId is > 0)
            ownUserId = await dbContext.Users.Where(u => u.UserType == UserTypes.Doctor && u.ReferenceUserId == doctorId)
                                             .Select(u => (int?)u.Id).FirstOrDefaultAsync();
        var own = ownUserId is int oid ? await dbContext.Users.AsNoTracking().Where(u => u.Id == oid).Select(u => u.Email).FirstOrDefaultAsync() : null;
        if (own is not null && string.Equals(own.Trim(), e, StringComparison.OrdinalIgnoreCase))
            return Json(new { valid = true, available = true, message = "Current sign-in of this doctor." });
        var taken = await dbContext.Users.AsNoTracking()
            .Where(u => (ownUserId == null || u.Id != ownUserId) && ((u.Email != null && u.Email.Trim().ToLower() == e) || u.Username == e))
            .Select(u => u.Username).FirstOrDefaultAsync();
        return taken is null
            ? Json(new { valid = true, available = true, message = "Available - the doctor will sign in with this e-mail." })
            : Json(new { valid = true, available = false, message = $"Already used by the sign-in '{taken}' - choose another e-mail." });
    }

    public async Task<IActionResult> SuggestLoginUsernames(string? fullName, string? email, string? check, int? doctorId)
    {
        int? ownUserId = null;
        if (doctorId is > 0)
            ownUserId = await dbContext.Users.Where(u => u.UserType == UserTypes.Doctor && u.ReferenceUserId == doctorId)
                                             .Select(u => (int?)u.Id).FirstOrDefaultAsync();

        var candidates = UsernameCandidates(fullName, email);
        var taken = await TakenUsernamesAsync(candidates, ownUserId);
        var suggestions = candidates.Where(c => !taken.Contains(c)).Take(5).ToList();

        // still short of five (common names): number the first base until five are free
        var baseName = candidates.FirstOrDefault();
        if (suggestions.Count < 5 && baseName is not null)
        {
            var numbered = Enumerable.Range(1, 30).Select(i => $"{baseName}{i}").ToList();
            var takenNumbered = await TakenUsernamesAsync(numbered, ownUserId);
            suggestions.AddRange(numbered.Where(n => !takenNumbered.Contains(n)).Take(5 - suggestions.Count));
        }

        object? checkResult = null;
        var wanted = check?.Trim();
        if (!string.IsNullOrEmpty(wanted))
        {
            var error = UsernameFormatError(wanted);
            var free = error is null && !await dbContext.Users.AnyAsync(u => u.Username == wanted && (!ownUserId.HasValue || u.Id != ownUserId.Value));
            checkResult = new { username = wanted, available = free, message = error ?? (free ? "Username is available." : "This username is already taken.") };
        }

        return Json(new { suggestions, check = checkResult });
    }

    /// <summary>Usernames to offer, most natural first: dr.first, first.last, dr.first.last, firstlast, first, e-mail name, first.l.</summary>
    private static List<string> UsernameCandidates(string? fullName, string? email)
    {
        static string Clean(string? v) => Regex.Replace((v ?? string.Empty).ToLowerInvariant(), "[^a-z0-9]", "");
        var words = (fullName ?? string.Empty).Split(new[] { ' ', '.', ',', '-', '_' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(Clean).Where(w => w.Length > 0)
            .Where(w => w is not ("dr" or "mr" or "mrs" or "ms" or "prof"))
            .ToList();
        var list = new List<string>();
        if (words.Count > 0)
        {
            var first = words[0];
            var last = words.Count > 1 ? words[^1] : null;
            list.Add($"dr.{first}");
            if (last is not null)
            {
                list.Add($"{first}.{last}");
                list.Add($"dr.{first}.{last}");
                list.Add($"{first}{last}");
            }
            list.Add(first);
            if (last is not null) list.Add($"{first}.{last[0]}");
        }
        var local = (email ?? string.Empty).Split('@')[0];
        var emailName = Regex.Replace(local.ToLowerInvariant(), "[^a-z0-9._-]", "").Trim('.', '_', '-');
        if (emailName.Length >= 3) list.Insert(Math.Min(2, list.Count), emailName);
        return list.Where(u => u.Length is >= 3 and <= 50).Distinct().ToList();
    }

    private async Task<HashSet<string>> TakenUsernamesAsync(List<string> names, int? ownUserId)
    {
        if (names.Count == 0) return new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var taken = await dbContext.Users.Where(u => names.Contains(u.Username) && (!ownUserId.HasValue || u.Id != ownUserId.Value))
                                         .Select(u => u.Username).ToListAsync();
        return new HashSet<string>(taken, StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>A login username: 3-50 characters, letters, digits and . _ - only, no spaces.</summary>
    private static string? UsernameFormatError(string username) =>
        username.Length is < 3 or > 50 ? "Use 3 to 50 characters."
        : !Regex.IsMatch(username, "^[A-Za-z0-9._-]+$") ? "Use only letters, digits and . _ - (no spaces)."
        : null;

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

        var doctor = new DoctorMaster
        {
            CompanyId = User.GetCompanyId(),
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
            IsReferralDoctor = model.IsReferralDoctor,
            CreatedBranchId = currentBranchId.Value,
            LinkedUserId = null
        };

        // the doctor first: its login points at the doctor (Users.User_Type 'D', ReferenceUserID = DoctorId)
        var doctorId = await doctorService.CreateAsync(doctor, model.SelectedBranchIds, model.SelectedDepartmentIds, User.GetUserId());
        doctor.DoctorId = doctorId;
        if (model.IsLoginRequired)
        {
            var loginUserId = await CreateLinkedUserAsync(model, doctor.FullName, doctorId);
            await doctorService.SetLinkedUserAsync(doctorId, loginUserId);
        }

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
            IsReferralDoctor = doctor.IsReferralDoctor,
            SelectedBranchIds = await doctorService.GetBranchIdsAsync(doctor.DoctorId),
            SelectedDepartmentIds = await doctorService.GetDepartmentIdsAsync(doctor.DoctorId),
            LinkedUserId = doctor.LinkedUserId
        };

        // the doctor's login: switched on when DoctorMaster links it; a switched-off one is shown so it is re-used
        var login = await FindDoctorLoginAsync(doctor);
        if (login is not null)
        {
            model.LoginAccountId = login.Id;
            model.LoginUsername = login.Username;
            model.IsLoginRequired = doctor.LinkedUserId == login.Id;
            model.LinkedUserId = model.IsLoginRequired ? login.Id : null;
        }
        else
        {
            model.LinkedUserId = null;
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

        var doctor = await doctorService.GetByIdAsync(model.DoctorId);
        if (doctor is null) return NotFound();

        // The doctor's login is looked up here (Users 'D' + this DoctorId, or the doctor's link) - any id posted
        // with the form is ignored, so one doctor's form can never change another user's account.
        var login = await FindDoctorLoginAsync(doctor);
        model.LoginAccountId = login?.Id;
        model.LinkedUserId = doctor.LinkedUserId.HasValue && login?.Id == doctor.LinkedUserId ? login!.Id : null;
        if (login is not null && model.IsLoginRequired)
        {
            model.LoginUsername = login.Username;      // the username of an existing login is changed in User Master
            ModelState.Remove(nameof(model.LoginPassword));
            ModelState.Remove(nameof(model.LoginConfirmPassword));
        }

        await ApplyBranchAssignmentRules(model, currentBranchId.Value);
        ValidateForm(model);
        if (model.IsLoginRequired)
            await ValidateLoginFieldsAsync(model, existingUserId: login?.Id);

        if (!ModelState.IsValid)
        {
            await PopulateFormSelections(model, isEdit: true);
            return View(model);
        }

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
        doctor.IsReferralDoctor = model.IsReferralDoctor;

        // ── Login account management ──────────────────────────────────────────
        if (model.IsLoginRequired)
        {
            if (login is null)
            {
                // no login yet - create the doctor's login
                doctor.LinkedUserId = await CreateLinkedUserAsync(model, doctor.FullName, doctor.DoctorId);
            }
            else
            {
                // the doctor's login (switched on, or switched off earlier and now re-activated) - sync it
                await SyncLinkedUserAsync(model, login.Id, doctor.FullName, doctor.DoctorId);
                doctor.LinkedUserId = login.Id;
            }
        }
        else if (login is not null && doctor.LinkedUserId.HasValue)
        {
            // login switched off - the account stays the doctor's (type 'D') but cannot sign in
            login.IsActive = false;
            login.LastModifiedDate = DateTime.Now;
            await dbContext.SaveChangesAsync();
            await auditLogService.LogAsync("MasterData", "Doctors.DisableLogin",
                $"Switched off login account '{login.Username}' of doctor '{doctor.FullName}'", login.Id);
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
        // Sign-in is by e-mail (SQLScripts/2307): the doctor's login signs in with the doctor's e-mail and its user name
        // is that e-mail. The e-mail must be unique among all sign-ins when it is new or changed; an older login whose
        // e-mail is shared keeps its user name until the e-mail is changed to a unique one.
        var email = model.EmailId?.Trim().ToLowerInvariant() ?? "";
        var stored = existingUserId.HasValue
            ? await dbContext.Users.AsNoTracking().Where(u => u.Id == existingUserId.Value).Select(u => new { u.Username, u.Email }).FirstOrDefaultAsync()
            : null;
        var emailChanged = stored is null || !string.Equals(stored.Email?.Trim(), email, StringComparison.OrdinalIgnoreCase);
        ModelState.Remove(nameof(model.LoginUsername));
        if (email.Length == 0)
        {
            ModelState.AddModelError(nameof(model.EmailId), "E-mail is required when login is enabled - the doctor signs in with it.");
            model.LoginUsername = stored?.Username;
        }
        else if (email.Length > 100)
        {
            ModelState.AddModelError(nameof(model.EmailId), "For a doctor with a login the e-mail can be up to 100 characters (it is the sign-in).");
            model.LoginUsername = stored?.Username;
        }
        else
        {
            var others = dbContext.Users.Where(u => !existingUserId.HasValue || u.Id != existingUserId.Value);
            if (emailChanged && await others.AnyAsync(u => (u.Email != null && u.Email.Trim().ToLower() == email) || u.Username == email))
                ModelState.AddModelError(nameof(model.EmailId), "This e-mail is already used by another sign-in - the doctor's login signs in with this e-mail.");
            // user name = e-mail, unless another login already holds it (only possible for an unchanged, shared e-mail)
            model.LoginUsername = await others.AnyAsync(u => u.Username == email) && stored is not null ? stored.Username : email;
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

    /// <summary>
    /// The doctor's login: the user of type 'D' whose ReferenceUserID is this doctor, else the user the doctor links to
    /// (DoctorMaster.LinkedUserId) when that user is not some other record's login. Null when the doctor has none.
    /// </summary>
    private async Task<User?> FindDoctorLoginAsync(DoctorMaster doctor)
    {
        var login = await dbContext.Users.FirstOrDefaultAsync(u => u.UserType == UserTypes.Doctor && u.ReferenceUserId == doctor.DoctorId);
        if (login is null && doctor.LinkedUserId.HasValue)
        {
            var linked = await dbContext.Users.FindAsync(doctor.LinkedUserId.Value);
            if (linked is not null && (linked.UserType == UserTypes.General
                                       || (linked.UserType == UserTypes.Doctor && linked.ReferenceUserId == doctor.DoctorId)))
                login = linked;
        }
        return login;
    }

    /// <summary>Creates the doctor's login (User_Type 'D', ReferenceUserID = DoctorId) and returns the new User.Id.</summary>
    private async Task<int> CreateLinkedUserAsync(DoctorFormViewModel model, string fullName, int doctorId)
    {
        var (hash, salt) = passwordHasherService.HashPassword(model.LoginPassword!);

        // Split full name roughly for FirstName / LastName
        var nameParts = fullName.Trim().Split(' ', 2);
        var firstName = nameParts[0];
        var lastName  = nameParts.Length > 1 ? nameParts[1] : string.Empty;

        var user = new User
        {
            CompanyId        = User.GetCompanyId(),
            Username         = model.LoginUsername!.Trim(),       // the e-mail (ValidateLoginFieldsAsync), SQLScripts/2307
            Email            = model.EmailId.Trim().ToLowerInvariant(),
            PasswordHash     = hash,
            Salt             = salt,
            FirstName        = firstName,
            LastName         = lastName,
            FullName         = fullName,
            PhoneNumber      = model.PhoneNumber.Trim(),
            Phone            = model.PhoneNumber.Trim(),
            IsActive         = true,
            UserType         = UserTypes.Doctor,
            ReferenceUserId  = doctorId,
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

    /// <summary>Syncs the doctor's login (details, active status, branches) with the doctor.</summary>
    private async Task SyncLinkedUserAsync(DoctorFormViewModel model, int linkedUserId, string fullName, int doctorId)
    {
        var user = await dbContext.Users.FindAsync(linkedUserId);
        if (user is null) return;

        user.UserType        = UserTypes.Doctor;     // the login belongs to this doctor
        user.ReferenceUserId = doctorId;

        var nameParts = fullName.Trim().Split(' ', 2);
        user.Username        = model.LoginUsername!.Trim();       // the e-mail (ValidateLoginFieldsAsync), SQLScripts/2307
        user.Email           = model.EmailId.Trim().ToLowerInvariant();
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

        // Re-sync branch mappings: existing rows are kept (with their employee codes) and switched on / off
        var selected = model.SelectedBranchIds.Distinct().ToHashSet();
        var existingBranches = await dbContext.UserBranches.Where(x => x.UserId == linkedUserId).ToListAsync();
        foreach (var ub in existingBranches)
        {
            var on = selected.Contains(ub.BranchId);
            if (ub.IsActive != on) { ub.IsActive = on; ub.ModifiedDate = DateTime.Now; ub.ModifiedBy = User.GetUserId(); }
        }
        dbContext.UserBranches.AddRange(selected.Where(bid => existingBranches.All(x => x.BranchId != bid)).Select(bid => new UserBranch
        {
            UserId       = linkedUserId,
            BranchId     = bid,
            IsActive     = true,
            CreatedDate  = DateTime.Now,
            ModifiedDate = DateTime.Now,
            CreatedBy    = User.GetUserId(),
            ModifiedBy   = User.GetUserId()
        }));

        // the doctor's login always carries the Doctor role (e.g. when a switched-off login is turned on again)
        var doctorRoleId = await dbContext.Roles.Where(r => r.Name.ToLower() == "doctor").Select(r => (int?)r.Id).FirstOrDefaultAsync();
        if (doctorRoleId.HasValue && !await dbContext.UserRoles.AnyAsync(r => r.UserId == linkedUserId && r.RoleId == doctorRoleId.Value && r.IsActive))
        {
            dbContext.UserRoles.Add(new UserRole
            {
                UserId       = linkedUserId,
                RoleId       = doctorRoleId.Value,
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

        await consultingFeeService.AddAsync(req.DoctorId, req.ServiceId, req.GraceTime, branchId.Value, User.GetUserId());
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

    /// POST /Doctors/UpdateGraceTime
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> UpdateGraceTime([FromBody] ConsultingFeeUpdateGraceTimeRequest req)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return Unauthorized();
        if (req.MappingId <= 0 || req.DoctorId <= 0)
            return BadRequest(new { error = "Invalid request." });

        await consultingFeeService.UpdateGraceTimeAsync(req.MappingId, req.DoctorId, branchId.Value, req.GraceTime);
        var fees = await consultingFeeService.GetByDoctorAsync(req.DoctorId, branchId.Value);
        return Json(new { success = true, fees });
    }
}

public record ConsultingFeeRequest(int DoctorId, int ServiceId, int? GraceTime);
public record ConsultingFeeRemoveRequest(int MappingId, int DoctorId);
public record ConsultingFeeUpdateGraceTimeRequest(int MappingId, int DoctorId, int? GraceTime);
