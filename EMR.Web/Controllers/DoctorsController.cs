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
    IDoctorSpecialityService doctorSpecialityService,
    IDepartmentService departmentService,
    IDoctorConsultingFeeService consultingFeeService,
    ApplicationDbContext dbContext,
    IAuditLogService auditLogService) : Controller
{
    public async Task<IActionResult> Index()
    {
        var branchId = User.GetCurrentBranchId();
        var doctors = await doctorService.GetListForBranchAsync(branchId);

        ViewBag.BranchName = branchId.HasValue
            ? (await dbContext.BranchMasters.FindAsync(branchId.Value))?.BranchName
            : null;

        return View(doctors);
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

        if (!ModelState.IsValid)
        {
            await PopulateFormSelections(model, isEdit: false);
            return View(model);
        }

        var doctor = new DoctorMaster
        {
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
            CreatedBranchId = currentBranchId.Value
        };

        await doctorService.CreateAsync(doctor, model.SelectedBranchIds, model.SelectedDepartmentIds, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Doctors.Create", $"Created doctor: {doctor.FullName} ({doctor.EmailId})");
        TempData["Success"] = "Doctor created successfully.";
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
            SelectedDepartmentIds = await doctorService.GetDepartmentIdsAsync(doctor.DoctorId)
        };

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

        await ApplyBranchAssignmentRules(model, currentBranchId.Value);
        ValidateForm(model);

        if (!ModelState.IsValid)
        {
            await PopulateFormSelections(model, isEdit: true);
            return View(model);
        }

        var doctor = await doctorService.GetByIdAsync(model.DoctorId);
        if (doctor is null) return NotFound();

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
