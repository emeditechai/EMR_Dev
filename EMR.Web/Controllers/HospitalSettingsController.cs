using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Models.DTOs;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class HospitalSettingsController(
    ApplicationDbContext dbContext,
    IAuditLogService auditLogService,
    IWebHostEnvironment webHostEnvironment,
    ILabDefaultSignatoryApiClient signatoryApiClient) : Controller
{
    // ── Default report signatories (Level 1..3) ──────────────────────────────
    // Configured when "Pathologist Approval Required" is switched off, so a released report still has named
    // signatories. Stored server-side only for now; no report or approval behaviour is changed by them yet.

    private const long MaxSignatureBytes = 2 * 1024 * 1024;

    private string SignatureRoot => Path.Combine(webHostEnvironment.ContentRootPath, "App_Data", "signatures");

    /// <summary>"png" / "jpg" from the file's first bytes (never from its name or the browser's content type).</summary>
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

    /// <summary>Saves an uploaded signature and returns its stored file name, or null when there is nothing to save.</summary>
    private async Task<string?> SaveSignatureAsync(IFormFile? file)
    {
        if (file is null || file.Length == 0) return null;

        var ext = Path.GetExtension(file.FileName).ToLowerInvariant();
        if (ext is not (".png" or ".jpg" or ".jpeg"))
            throw new InvalidOperationException("Signature must be a .png, .jpg or .jpeg file.");
        if (file.Length > MaxSignatureBytes)
            throw new InvalidOperationException("Signature image size must be up to 2 MB.");

        var type = await DetectSignatureTypeAsync(file)
                   ?? throw new InvalidOperationException("The selected file is not a valid PNG or JPEG image.");

        Directory.CreateDirectory(SignatureRoot);
        var name = $"sig_{Guid.NewGuid():N}.{type}";
        await using var target = System.IO.File.Create(Path.Combine(SignatureRoot, name));
        await file.CopyToAsync(target);
        return name;
    }

    [HttpGet]
    public async Task<IActionResult> GetSignatoriesJson()
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return Json(new { success = false, message = "No active branch found." });

        try
        {
            var result = await signatoryApiClient.GetListAsync(branchId.Value, User.GetCompanyId());
            return Json(new { success = true, signatories = result.Signatories, candidates = result.Candidates, departments = result.Departments });
        }
        catch (HttpRequestException)
        {
            return Json(new { success = false, message = "The service is unreachable. Please try again." });
        }
    }

    /// <summary>
    /// Saves department-wise signatories (up to 3 slots per department).
    /// Form keys: userId_&lt;deptId&gt;_&lt;slot&gt;, signature_&lt;deptId&gt;_&lt;slot&gt;
    /// </summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequestSizeLimit(16 * 1024 * 1024)]
    public async Task<IActionResult> SaveSignatoriesJson()
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return Json(new { success = false, message = "No active branch found." });

        var items = new List<LabDefaultSignatoryItem>();

        try
        {
            // Form keys are: userId_<deptId>_<slot>   e.g.  userId_3_1, userId_3_2
            foreach (var key in Request.Form.Keys)
            {
                if (!key.StartsWith("userId_")) continue;

                var tail = key["userId_".Length..];                   // "3_1"
                var parts = tail.Split('_');
                if (parts.Length != 2) continue;
                if (!int.TryParse(parts[0], out var deptId) || deptId <= 0) continue;
                if (!int.TryParse(parts[1], out var slot)   || slot is < 1 or > 3) continue;

                var raw = Request.Form[key].ToString();
                if (!int.TryParse(raw, out var userId) || userId <= 0) continue;  // slot left empty

                items.Add(new LabDefaultSignatoryItem
                {
                    DepartmentId  = deptId,
                    SlotNo        = slot,
                    UserId        = userId,
                    SignaturePath = await SaveSignatureAsync(
                        Request.Form.Files[$"signature_{deptId}_{slot}"])
                });
            }
        }
        catch (InvalidOperationException ex)
        {
            return Json(new { success = false, message = ex.Message });
        }

        try
        {
            var (saved, error) = await signatoryApiClient.SaveAsync(new LabDefaultSignatorySaveRequest
            {
                BranchId = branchId.Value,
                CompanyId = User.GetCompanyId(),
                UserId = User.GetUserId(),
                Items = items
            });

            if (error != null) return Json(new { success = false, message = error });

            try
            {
                await auditLogService.LogActivityAsync(
                    eventType: "Hospital Settings",
                    actionName: "LAB.ReportSignatoriesSaved",
                    description: $"Default lab report signatories configured ({saved} level(s)) for the branch.",
                    userId: User.GetUserId(),
                    branchId: branchId,
                    moduleCode: "LAB",
                    metadata: new { BranchId = branchId, Items = items });
            }
            catch { /* audit only */ }

            return Json(new
            {
                success = true,
                savedCount = saved,
                message = saved == 0
                    ? "No signatory configured. The report will fall back to the approval signatures."
                    : $"{saved} signatory level(s) saved."
            });
        }
        catch (HttpRequestException)
        {
            return Json(new { success = false, message = "The service is unreachable. Please try again." });
        }
    }

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null)
        {
            TempData["Error"] = "No active branch found. Please select a branch first.";
            return RedirectToAction("Index", "Dashboard");
        }

        var branch = await dbContext.BranchMasters.FindAsync(branchId.Value);
        var settings = await dbContext.HospitalSettings
            .FirstOrDefaultAsync(x => x.BranchId == branchId.Value);

        if (settings is null)
        {
            var empty = new HospitalSettingsViewModel
            {
                BranchId = branchId.Value,
                BranchName = branch?.BranchName ?? string.Empty
            };
            return View(empty);
        }

        var model = MapToViewModel(settings, branch?.BranchName ?? string.Empty);
        return View(model);
    }

    [HttpGet]
    public async Task<IActionResult> Edit()
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null)
        {
            TempData["Error"] = "No active branch found.";
            return RedirectToAction("Index", "Dashboard");
        }

        var branch = await dbContext.BranchMasters.FindAsync(branchId.Value);
        var settings = await dbContext.HospitalSettings
            .FirstOrDefaultAsync(x => x.BranchId == branchId.Value);

        if (settings is null)
        {
            return View(new HospitalSettingsViewModel
            {
                BranchId = branchId.Value,
                BranchName = branch?.BranchName ?? string.Empty,
                IsActive = true
            });
        }

        return View(MapToViewModel(settings, branch?.BranchName ?? string.Empty));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(HospitalSettingsViewModel model)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null)
            return RedirectToAction("Index", "Dashboard");

        // Ensure the model is always tied to the session branch (no tampering)
        model.BranchId = branchId.Value;

        ValidateLogoFile(model);

        if (!ModelState.IsValid)
        {
            var br = await dbContext.BranchMasters.FindAsync(branchId.Value);
            model.BranchName = br?.BranchName ?? string.Empty;
            return View(model);
        }

        var userId = User.GetUserId();
        var existing = await dbContext.HospitalSettings
            .FirstOrDefaultAsync(x => x.BranchId == branchId.Value);

        if (existing is null)
        {
            var entity = MapToEntity(model, userId, User.GetCompanyId());
            entity.LogoPath = await SaveLogoFileAsync(model.LogoFile, entity.LogoPath);
            dbContext.HospitalSettings.Add(entity);

            await dbContext.SaveChangesAsync();
            await auditLogService.LogAsync("Create", "HospitalSettings",
                $"Hospital settings created for branch {branchId}", userId, branchId);
            TempData["Success"] = "Hospital settings saved successfully.";
        }
        else
        {
            existing.HospitalName = model.HospitalName;
            existing.HospitalType = model.HospitalType;
            existing.RegistrationNumber = model.RegistrationNumber;
            existing.Address = model.Address;
            existing.ContactNumber1 = model.ContactNumber1;
            existing.ContactNumber2 = model.ContactNumber2;
            existing.EmergencyNumber = model.EmergencyNumber;
            existing.EmailAddress = model.EmailAddress;
            existing.Website = model.Website;
            existing.GSTCode = model.GSTCode;
            existing.LogoPath = await SaveLogoFileAsync(model.LogoFile, existing.LogoPath);
            existing.NabhStatus = model.NabhStatus;
            existing.NabhCertificateNo = model.NabhCertificateNo;
            existing.NabhValidFrom = DateTime.TryParse(model.NabhValidFrom, out var nvf) ? nvf : null;
            existing.NabhValidTo = DateTime.TryParse(model.NabhValidTo, out var nvt) ? nvt : null;
            existing.IsTeachingHospital = model.IsTeachingHospital;
            existing.CheckInTime = TimeSpan.TryParse(model.CheckInTime, out var cin) ? cin : null;
            existing.CheckOutTime = TimeSpan.TryParse(model.CheckOutTime, out var cout) ? cout : null;
            existing.OpdRegistrationValidityDays = model.OpdRegistrationValidityDays;
            existing.GlobalPatientSearchRequired = model.GlobalPatientSearchRequired;
            existing.EmailNotificationRequired = model.EmailNotificationRequired;
            existing.LabEmailNotificationRequired = model.LabEmailNotificationRequired;
            existing.IsSampleCollectionMandatory = model.IsSampleCollectionMandatory;
            existing.BarcodeGenerateAtBilling = model.BarcodeGenerateAtBilling;
            existing.TokenGenerateOnDuePayment = model.TokenGenerateOnDuePayment;
            existing.LabReportEmailNotificationRequired = model.LabReportEmailNotificationRequired;
            existing.PathologistApprovalRequired = model.PathologistApprovalRequired;
            existing.ShowLabReportPrintOnList = model.ShowLabReportPrintOnList;
            existing.IsActive = model.IsActive;
            existing.LastModifiedDate = DateTime.Now;
            existing.LastModifiedBy = userId;

            await dbContext.SaveChangesAsync();
            await auditLogService.LogAsync("Update", "HospitalSettings",
                $"Hospital settings updated for branch {branchId}", userId, branchId);
            TempData["Success"] = "Hospital settings updated successfully.";
        }

        return RedirectToAction(nameof(Index));
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    private static HospitalSettingsViewModel MapToViewModel(HospitalSettings s, string branchName) =>
        new()
        {
            Id = s.Id,
            BranchId = s.BranchId,
            BranchName = branchName,
            HospitalName = s.HospitalName,
            HospitalType = s.HospitalType,
            RegistrationNumber = s.RegistrationNumber,
            Address = s.Address,
            ContactNumber1 = s.ContactNumber1,
            ContactNumber2 = s.ContactNumber2,
            EmergencyNumber = s.EmergencyNumber,
            EmailAddress = s.EmailAddress,
            Website = s.Website,
            GSTCode = s.GSTCode,
            LogoPath = s.LogoPath,
            NabhStatus = s.NabhStatus,
            NabhCertificateNo = s.NabhCertificateNo,
            NabhValidFrom = s.NabhValidFrom?.ToString("yyyy-MM-dd"),
            NabhValidTo = s.NabhValidTo?.ToString("yyyy-MM-dd"),
            IsTeachingHospital = s.IsTeachingHospital,
            CheckInTime = s.CheckInTime.HasValue
                ? s.CheckInTime.Value.ToString(@"hh\:mm") : null,
            CheckOutTime = s.CheckOutTime.HasValue
                ? s.CheckOutTime.Value.ToString(@"hh\:mm") : null,
            OpdRegistrationValidityDays = s.OpdRegistrationValidityDays,
            GlobalPatientSearchRequired = s.GlobalPatientSearchRequired,
            EmailNotificationRequired = s.EmailNotificationRequired,
            LabEmailNotificationRequired = s.LabEmailNotificationRequired,
            IsSampleCollectionMandatory = s.IsSampleCollectionMandatory,
            BarcodeGenerateAtBilling = s.BarcodeGenerateAtBilling,
            TokenGenerateOnDuePayment = s.TokenGenerateOnDuePayment,
            LabReportEmailNotificationRequired = s.LabReportEmailNotificationRequired,
            PathologistApprovalRequired = s.PathologistApprovalRequired,
            ShowLabReportPrintOnList = s.ShowLabReportPrintOnList,
            IsActive = s.IsActive,
            CreatedDate = s.CreatedDate,
            LastModifiedDate = s.LastModifiedDate
        };

    private static HospitalSettings MapToEntity(HospitalSettingsViewModel m, int userId, int companyId = 1) =>
        new()
        {
            CompanyId = companyId,
            BranchId = m.BranchId,
            HospitalName = m.HospitalName,
            HospitalType = m.HospitalType,
            RegistrationNumber = m.RegistrationNumber,
            Address = m.Address,
            ContactNumber1 = m.ContactNumber1,
            ContactNumber2 = m.ContactNumber2,
            EmergencyNumber = m.EmergencyNumber,
            EmailAddress = m.EmailAddress,
            Website = m.Website,
            GSTCode = m.GSTCode,
            LogoPath = m.LogoPath,
            NabhStatus = m.NabhStatus,
            NabhCertificateNo = m.NabhCertificateNo,
            NabhValidFrom = DateTime.TryParse(m.NabhValidFrom, out var nvf) ? nvf : null,
            NabhValidTo = DateTime.TryParse(m.NabhValidTo, out var nvt) ? nvt : null,
            IsTeachingHospital = m.IsTeachingHospital,
            CheckInTime = TimeSpan.TryParse(m.CheckInTime, out var cin) ? cin : null,
            CheckOutTime = TimeSpan.TryParse(m.CheckOutTime, out var cout) ? cout : null,
            OpdRegistrationValidityDays = m.OpdRegistrationValidityDays,
            GlobalPatientSearchRequired = m.GlobalPatientSearchRequired,
            EmailNotificationRequired = m.EmailNotificationRequired,
            LabEmailNotificationRequired = m.LabEmailNotificationRequired,
            IsSampleCollectionMandatory = m.IsSampleCollectionMandatory,
            BarcodeGenerateAtBilling = m.BarcodeGenerateAtBilling,
            TokenGenerateOnDuePayment = m.TokenGenerateOnDuePayment,
            LabReportEmailNotificationRequired = m.LabReportEmailNotificationRequired,
            PathologistApprovalRequired = m.PathologistApprovalRequired,
            ShowLabReportPrintOnList = m.ShowLabReportPrintOnList,
            IsActive = m.IsActive,
            CreatedDate = DateTime.Now,
            CreatedBy = userId
        };



    private void ValidateLogoFile(HospitalSettingsViewModel model)
    {
        if (model.LogoFile is null || model.LogoFile.Length == 0)
        {
            return;
        }

        var ext = Path.GetExtension(model.LogoFile.FileName).ToLowerInvariant();
        var allowed = new[] { ".png", ".jpg", ".jpeg" };
        if (!allowed.Contains(ext))
        {
            ModelState.AddModelError(nameof(model.LogoFile), "Supported formats: png, jpg, jpeg.");
        }

        const long maxBytes = 2 * 1024 * 1024;
        if (model.LogoFile.Length > maxBytes)
        {
            ModelState.AddModelError(nameof(model.LogoFile), "Logo file size must be up to 2 MB.");
        }
    }

    private async Task<string?> SaveLogoFileAsync(IFormFile? file, string? existingPath)
    {
        if (file is null || file.Length == 0)
        {
            return existingPath;
        }

        var ext = Path.GetExtension(file.FileName).ToLowerInvariant();
        var fileName = $"hospital_logo_{Guid.NewGuid():N}{ext}";
        var relativePath = $"/uploads/logos/{fileName}";
        var saveDir = Path.Combine(webHostEnvironment.WebRootPath, "uploads", "logos");
        Directory.CreateDirectory(saveDir);
        var savePath = Path.Combine(saveDir, fileName);

        await using (var stream = new FileStream(savePath, FileMode.Create))
        {
            await file.CopyToAsync(stream);
        }

        DeleteFileIfExists(existingPath);
        return relativePath;
    }

    private void DeleteFileIfExists(string? relativePath)
    {
        if (string.IsNullOrWhiteSpace(relativePath)) return;

        var cleanPath = relativePath.TrimStart('/').Replace('/', Path.DirectorySeparatorChar);
        var physicalPath = Path.Combine(webHostEnvironment.WebRootPath, cleanPath);
        if (System.IO.File.Exists(physicalPath))
        {
            System.IO.File.Delete(physicalPath);
        }
    }
}
