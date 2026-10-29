using System.Net.Http.Json;
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
    ILabDefaultSignatoryApiClient signatoryApiClient,
    ILabFtpService labFtpService) : Controller
{
    // ── FTP credentials for external lab report documents (Lab tab, SQLScripts/2354) ─────────
    // Saved on their own (not with the main form). The password is encrypted and never sent back to the page.

    [HttpGet]
    public async Task<IActionResult> FtpSettings()
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return Json(new { success = false, message = "No active branch." });
        var own = await labFtpService.GetOwnAsync(branchId.Value);
        var used = own ?? await labFtpService.GetForBranchAsync(User.GetCompanyId(), branchId.Value);
        return Json(new
        {
            success = true,
            own = own is not null,
            inheritedFromBranchId = own is null ? used?.BranchId : null,
            host = used?.Host, port = used?.Port ?? 21, userName = used?.UserName,
            rootFolder = used?.RootFolder ?? "emedidoc/reports", usePassive = used?.UsePassive ?? true, useFtps = used?.UseFtps ?? false,
            hasPassword = !string.IsNullOrEmpty(own?.PasswordEnc), modifiedDate = own?.ModifiedDate
        });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveFtpSettings(string? host, int? port, string? userName, string? password, string? rootFolder,
        bool usePassive, bool useFtps)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return Json(new { success = false, message = "No active branch." });
        var (settings, error) = await ReadFtpForm(branchId.Value, host, port, userName, rootFolder, usePassive, useFtps);
        if (error is not null) return Json(new { success = false, message = error });
        var own = await labFtpService.GetOwnAsync(branchId.Value);
        if (string.IsNullOrEmpty(password) && string.IsNullOrEmpty(own?.PasswordEnc))
            return Json(new { success = false, message = "Enter the FTP password." });

        await labFtpService.SaveAsync(settings!, password, User.GetUserId());
        await auditLogService.LogAsync("Update", "HospitalSettings",
            $"FTP credentials for report documents saved (host {settings!.Host}, user {settings.UserName})", User.GetUserId(), branchId);
        return Json(new { success = true, message = "FTP credentials saved." });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> TestFtpSettings(string? host, int? port, string? userName, string? password, string? rootFolder,
        bool usePassive, bool useFtps)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return Json(new { success = false, message = "No active branch." });
        var (settings, error) = await ReadFtpForm(branchId.Value, host, port, userName, rootFolder, usePassive, useFtps);
        if (error is not null) return Json(new { success = false, message = error });
        if (string.IsNullOrEmpty(password))
        {
            var stored = await labFtpService.GetOwnAsync(branchId.Value);
            if (string.IsNullOrEmpty(stored?.PasswordEnc)) return Json(new { success = false, message = "Enter the FTP password." });
            settings!.PasswordEnc = stored.PasswordEnc;
        }
        var (ok, message) = await labFtpService.TestAsync(settings!, password);
        return Json(new { success = ok, message });
    }

    private async Task<(Services.LabFtpSettings? Settings, string? Error)> ReadFtpForm(int branchId, string? host, int? port,
        string? userName, string? rootFolder, bool usePassive, bool useFtps)
    {
        host = host?.Trim().Replace("ftp://", "", StringComparison.OrdinalIgnoreCase).TrimEnd('/');
        if (string.IsNullOrWhiteSpace(host) || host.Length > 200 || host.Any(char.IsWhiteSpace))
            return (null, "Enter a valid FTP host name or IP address.");
        if (port is < 1 or > 65535) return (null, "Port must be between 1 and 65535.");
        if (string.IsNullOrWhiteSpace(userName)) return (null, "Enter the FTP user ID.");
        rootFolder = (rootFolder ?? "").Trim().Replace('\\', '/').Trim('/');
        if (rootFolder.Contains("..") || rootFolder.Length > 300) return (null, "Enter a valid root folder (e.g. emedidoc/reports).");
        var companyId = await dbContext.BranchMasters.Where(b => b.BranchId == branchId).Select(b => b.CompanyId).FirstOrDefaultAsync();
        return (new Services.LabFtpSettings
        {
            CompanyId = companyId == 0 ? User.GetCompanyId() : companyId, BranchId = branchId, Host = host,
            Port = port ?? 21, UserName = userName.Trim(), RootFolder = rootFolder, UsePassive = usePassive, UseFtps = useFtps
        }, null);
    }

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
        // Copy from Head Office (SQLScripts/2318) is offered only on a branch
        ViewBag.IsHeadOffice = branch?.IsHOBranch ?? false;
        ViewBag.HeadOfficeName = branch is null ? null : await dbContext.BranchMasters
            .Where(b => b.CompanyId == branch.CompanyId && b.IsHOBranch).Select(b => b.BranchName).FirstOrDefaultAsync();
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

    /// <summary>
    /// Copy from Head Office (SQLScripts/2318): every Hospital Settings value of the head office onto the branch signed in
    /// to (not on the head office itself). The branch's previous values go to the audit log.
    /// </summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> CopyFromHeadOffice([FromServices] IHttpClientFactory httpFactory)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) { TempData["Error"] = "No active branch found."; return RedirectToAction(nameof(Index)); }
        try
        {
            var http = httpFactory.CreateClient("EmrApi");
            var res = await http.PostAsJsonAsync("api/hospital-settings/copy-from-ho", new { targetBranchId = branchId.Value, userId = User.GetUserId() });
            System.Text.Json.JsonElement body = default;
            try { body = await res.Content.ReadFromJsonAsync<System.Text.Json.JsonElement>(); } catch (System.Text.Json.JsonException) { }
            var ok = res.IsSuccessStatusCode && body.ValueKind == System.Text.Json.JsonValueKind.Object
                     && body.TryGetProperty("success", out var sv) && sv.GetBoolean();
            if (!ok)
            {
                TempData["Error"] = body.ValueKind == System.Text.Json.JsonValueKind.Object && body.TryGetProperty("message", out var m)
                    ? m.GetString() : "The settings could not be copied - nothing was changed.";
                return RedirectToAction(nameof(Index));
            }
            var data = body.GetProperty("data");
            var source = data.TryGetProperty("sourceBranchName", out var sn) ? sn.GetString() : "Head Office";
            var previous = data.TryGetProperty("previousValuesJson", out var pv) && pv.ValueKind == System.Text.Json.JsonValueKind.String ? pv.GetString() : null;
            // the branch's previous values go into the metadata (no length limit), so they can be restored if needed
            await auditLogService.LogActivityAsync(
                eventType: "Update",
                actionName: "HospitalSettings.CopyFromHeadOffice",
                description: $"Hospital settings of branch {branchId} copied from {source} ({(data.TryGetProperty("columnsCopied", out var cc) ? cc.GetInt32() : 0)} settings). Previous values are in the metadata.",
                userId: User.GetUserId(),
                branchId: branchId,
                moduleCode: "SETTINGS",
                metadata: new { SourceBranch = source, PreviousValues = previous is null ? (System.Text.Json.JsonElement?)null : System.Text.Json.JsonDocument.Parse(previous).RootElement });
            TempData["Success"] = $"All settings copied from {source}. Review them and use Edit Settings for anything this branch needs different (address, contacts, logo).";
        }
        catch (HttpRequestException)
        {
            TempData["Error"] = "The API is not reachable - nothing was copied.";
        }
        return RedirectToAction(nameof(Index));
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
        model.DoctorIpComputeMode = string.IsNullOrWhiteSpace(model.DoctorIpComputeMode) ? "Manual" : model.DoctorIpComputeMode;
        if (model.DoctorIpComputeMode != "Manual" && !TimeSpan.TryParse(model.DoctorIpAutoRunTime, out _))
            ModelState.AddModelError(nameof(model.DoctorIpAutoRunTime), "Enter the scheduled time for the automatic Doctor IP commission run.");

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
            existing.EnableAiBillingFeatures = model.EnableAiBillingFeatures;
            EMR.Web.Services.AiBillingFeatures.Invalidate(HttpContext.RequestServices.GetRequiredService<Microsoft.Extensions.Caching.Memory.IMemoryCache>(), existing.BranchId);
            existing.EnableAskAiFeatures = model.EnableAskAiFeatures;
            EMR.Web.Services.AskAiFeatures.Invalidate(HttpContext.RequestServices.GetRequiredService<Microsoft.Extensions.Caching.Memory.IMemoryCache>(), existing.BranchId);
            existing.TokenGenerateOnDuePayment = model.TokenGenerateOnDuePayment;
            existing.LabReportEmailNotificationRequired = model.LabReportEmailNotificationRequired;
            existing.PathologistApprovalRequired = model.PathologistApprovalRequired;
            existing.ShowLabReportPrintOnList = model.ShowLabReportPrintOnList;
            existing.CriticalValueCommunicationRequired = model.CriticalValueCommunicationRequired;
            existing.CriticalValueInformMinutes = model.CriticalValueInformMinutes;
            existing.LabB2CBillPrintHeaderRequired = model.LabB2CBillPrintHeaderRequired;
            existing.LabBillPrintPageSize = model.LabBillPrintPageSize == "A5L" ? "A5L" : "A4";
            existing.LabB2CReportPrintHeaderRequired = model.LabB2CReportPrintHeaderRequired;
            existing.DoctorIpComputeMode = model.DoctorIpComputeMode;
            existing.MembershipCardNoPrefix = string.IsNullOrWhiteSpace(model.MembershipCardNoPrefix) ? "MC" : model.MembershipCardNoPrefix.Trim().ToUpperInvariant();
            existing.MembershipCardWhatsAppRequired = model.MembershipCardWhatsAppRequired;
            existing.MembershipCardEmailRequired = model.MembershipCardEmailRequired;
            existing.MembershipCardAutoSendOnIssue = model.MembershipCardAutoSendOnIssue;
            existing.MembershipRenewalWindowDays = model.MembershipRenewalWindowDays;
            existing.MembershipDiscountWithManualDiscount = model.MembershipDiscountWithManualDiscount;
            existing.MembershipRedeemOtpRequired = model.MembershipRedeemOtpRequired;
            existing.MembershipPointsExpiryTime = TimeSpan.TryParse(model.MembershipPointsExpiryTime, out var expAt) ? expAt : new TimeSpan(1, 0, 0);
            existing.MembershipRenewalReminderEnabled = model.MembershipRenewalReminderEnabled;
            existing.MembershipRenewalReminderDays = NormalizeReminderDays(model.MembershipRenewalReminderDays);
            existing.MembershipRenewalReminderTime = TimeSpan.TryParse(model.MembershipRenewalReminderTime, out var remAt) ? remAt : new TimeSpan(10, 0, 0);
            existing.MembershipRenewalReminderTemplate = string.IsNullOrWhiteSpace(model.MembershipRenewalReminderTemplate) ? HospitalSettings.DefaultMembershipRenewalReminderMessage : model.MembershipRenewalReminderTemplate.Trim();
            existing.MembershipCardMessageTemplate = string.IsNullOrWhiteSpace(model.MembershipCardMessageTemplate) ? HospitalSettings.DefaultMembershipCardMessage : model.MembershipCardMessageTemplate.Trim();
            existing.DoctorIpAutoRunTime = model.DoctorIpComputeMode != "Manual" && TimeSpan.TryParse(model.DoctorIpAutoRunTime, out var ipRun) ? ipRun : null;
            existing.LabPatientPortalRequired = model.LabPatientPortalRequired;
            existing.OpdFollowUpNotificationRequired = model.OpdFollowUpNotificationRequired;
            existing.OpdCertificateNotificationRequired = model.OpdCertificateNotificationRequired;
            existing.DayClosingBlockBilling = model.DayClosingBlockBilling;
            existing.DayClosingAllowSelfVerify = model.DayClosingAllowSelfVerify;
            existing.DayClosingLoginReminder = model.DayClosingLoginReminder;
            existing.PharmacyEnabled = model.PharmacyEnabled;
            existing.PharmacyName = model.PharmacyName;
            existing.PharmacyDrugLicence20B = model.PharmacyDrugLicence20B;
            existing.PharmacyDrugLicence20BValidTo = model.PharmacyDrugLicence20BValidTo;
            existing.PharmacyDrugLicence21B = model.PharmacyDrugLicence21B;
            existing.PharmacyDrugLicence21BValidTo = model.PharmacyDrugLicence21BValidTo;
            existing.PharmacyGstin = string.IsNullOrWhiteSpace(model.PharmacyGstin) ? null : model.PharmacyGstin.Trim().ToUpperInvariant();
            existing.PharmacistName = model.PharmacistName;
            existing.PharmacistRegNo = model.PharmacistRegNo;
            existing.PharmacyNdpsLicenceNo = model.PharmacyNdpsLicenceNo;
            existing.PharmacyContactNo = model.PharmacyContactNo;
            existing.PharmacyAllowNegativeStock = model.PharmacyAllowNegativeStock;
            existing.PharmacyMinShelfLifeSaleDays = model.PharmacyMinShelfLifeSaleDays;
            existing.PharmacyMinShelfLifeIpdDays = model.PharmacyMinShelfLifeIpdDays;
            existing.PharmacyMinShelfLifeGrnDays = model.PharmacyMinShelfLifeGrnDays;
            existing.PharmacyNearExpiryAlertDays = model.PharmacyNearExpiryAlertDays;
            existing.PharmacySaleReturnDays = model.PharmacySaleReturnDays;
            existing.PharmacyLooseReturnAllowed = model.PharmacyLooseReturnAllowed;
            existing.PharmacyMaxManualDiscountPercent = model.PharmacyMaxManualDiscountPercent;
            existing.PharmacyIpdGstExempt = model.PharmacyIpdGstExempt;
            existing.PharmacyBlockDischargeOnPendingIndent = model.PharmacyBlockDischargeOnPendingIndent;
            existing.PharmacyTtoBillingMode = model.PharmacyTtoBillingMode == "SALE" ? "SALE" : "IPD";
            existing.PharmacyRoundOffBill = model.PharmacyRoundOffBill;
            existing.PharmacyBillPrintFormat = model.PharmacyBillPrintFormat is "A5" or "80MM" ? model.PharmacyBillPrintFormat : "A4";
            existing.PharmacyBillNotificationRequired = model.PharmacyBillNotificationRequired;
            existing.PharmacyGrnNotRequired = model.PharmacyGrnNotRequired;
            existing.LoginRetryCount = model.LoginRetryCount;
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
            EnableAiBillingFeatures = s.EnableAiBillingFeatures,
            EnableAskAiFeatures = s.EnableAskAiFeatures,
            TokenGenerateOnDuePayment = s.TokenGenerateOnDuePayment,
            LabReportEmailNotificationRequired = s.LabReportEmailNotificationRequired,
            PathologistApprovalRequired = s.PathologistApprovalRequired,
            ShowLabReportPrintOnList = s.ShowLabReportPrintOnList,
            CriticalValueCommunicationRequired = s.CriticalValueCommunicationRequired,
            CriticalValueInformMinutes = s.CriticalValueInformMinutes,
            LabB2CBillPrintHeaderRequired = s.LabB2CBillPrintHeaderRequired,
            LabBillPrintPageSize = s.LabBillPrintPageSize == "A5L" ? "A5L" : "A4",
            LabB2CReportPrintHeaderRequired = s.LabB2CReportPrintHeaderRequired,
            DoctorIpComputeMode = string.IsNullOrWhiteSpace(s.DoctorIpComputeMode) ? "Manual" : s.DoctorIpComputeMode,
            MembershipCardNoPrefix = string.IsNullOrWhiteSpace(s.MembershipCardNoPrefix) ? "MC" : s.MembershipCardNoPrefix,
            MembershipCardWhatsAppRequired = s.MembershipCardWhatsAppRequired,
            MembershipCardEmailRequired = s.MembershipCardEmailRequired,
            MembershipCardAutoSendOnIssue = s.MembershipCardAutoSendOnIssue,
            MembershipRenewalWindowDays = s.MembershipRenewalWindowDays,
            MembershipDiscountWithManualDiscount = s.MembershipDiscountWithManualDiscount,
            MembershipRedeemOtpRequired = s.MembershipRedeemOtpRequired,
            MembershipPointsExpiryTime = s.MembershipPointsExpiryTime.ToString(@"hh\:mm"),
            MembershipRenewalReminderEnabled = s.MembershipRenewalReminderEnabled,
            MembershipRenewalReminderDays = s.MembershipRenewalReminderDays,
            MembershipRenewalReminderTime = s.MembershipRenewalReminderTime.ToString(@"hh\:mm"),
            MembershipRenewalReminderTemplate = s.MembershipRenewalReminderTemplate,
            MembershipCardMessageTemplate = s.MembershipCardMessageTemplate,
            DoctorIpAutoRunTime = s.DoctorIpAutoRunTime.HasValue ? s.DoctorIpAutoRunTime.Value.ToString(@"hh\:mm") : null,
            LabPatientPortalRequired = s.LabPatientPortalRequired,
            OpdFollowUpNotificationRequired = s.OpdFollowUpNotificationRequired,
            OpdCertificateNotificationRequired = s.OpdCertificateNotificationRequired,
            DayClosingBlockBilling = s.DayClosingBlockBilling,
            DayClosingAllowSelfVerify = s.DayClosingAllowSelfVerify,
            DayClosingLoginReminder = s.DayClosingLoginReminder,
            PharmacyEnabled = s.PharmacyEnabled,
            PharmacyName = s.PharmacyName,
            PharmacyDrugLicence20B = s.PharmacyDrugLicence20B,
            PharmacyDrugLicence20BValidTo = s.PharmacyDrugLicence20BValidTo,
            PharmacyDrugLicence21B = s.PharmacyDrugLicence21B,
            PharmacyDrugLicence21BValidTo = s.PharmacyDrugLicence21BValidTo,
            PharmacyGstin = s.PharmacyGstin,
            PharmacistName = s.PharmacistName,
            PharmacistRegNo = s.PharmacistRegNo,
            PharmacyNdpsLicenceNo = s.PharmacyNdpsLicenceNo,
            PharmacyContactNo = s.PharmacyContactNo,
            PharmacyAllowNegativeStock = s.PharmacyAllowNegativeStock,
            PharmacyMinShelfLifeSaleDays = s.PharmacyMinShelfLifeSaleDays,
            PharmacyMinShelfLifeIpdDays = s.PharmacyMinShelfLifeIpdDays,
            PharmacyMinShelfLifeGrnDays = s.PharmacyMinShelfLifeGrnDays,
            PharmacyNearExpiryAlertDays = s.PharmacyNearExpiryAlertDays,
            PharmacySaleReturnDays = s.PharmacySaleReturnDays,
            PharmacyLooseReturnAllowed = s.PharmacyLooseReturnAllowed,
            PharmacyMaxManualDiscountPercent = s.PharmacyMaxManualDiscountPercent,
            PharmacyIpdGstExempt = s.PharmacyIpdGstExempt,
            PharmacyBlockDischargeOnPendingIndent = s.PharmacyBlockDischargeOnPendingIndent,
            PharmacyTtoBillingMode = s.PharmacyTtoBillingMode,
            PharmacyRoundOffBill = s.PharmacyRoundOffBill,
            PharmacyBillPrintFormat = s.PharmacyBillPrintFormat,
            PharmacyBillNotificationRequired = s.PharmacyBillNotificationRequired,
            PharmacyGrnNotRequired = s.PharmacyGrnNotRequired,
            LoginRetryCount = s.LoginRetryCount,
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
            EnableAiBillingFeatures = m.EnableAiBillingFeatures,
            EnableAskAiFeatures = m.EnableAskAiFeatures,
            TokenGenerateOnDuePayment = m.TokenGenerateOnDuePayment,
            LabReportEmailNotificationRequired = m.LabReportEmailNotificationRequired,
            PathologistApprovalRequired = m.PathologistApprovalRequired,
            ShowLabReportPrintOnList = m.ShowLabReportPrintOnList,
            CriticalValueCommunicationRequired = m.CriticalValueCommunicationRequired,
            CriticalValueInformMinutes = m.CriticalValueInformMinutes,
            LabB2CBillPrintHeaderRequired = m.LabB2CBillPrintHeaderRequired,
            LabBillPrintPageSize = m.LabBillPrintPageSize == "A5L" ? "A5L" : "A4",
            LabB2CReportPrintHeaderRequired = m.LabB2CReportPrintHeaderRequired,
            DoctorIpComputeMode = m.DoctorIpComputeMode,
            MembershipCardNoPrefix = string.IsNullOrWhiteSpace(m.MembershipCardNoPrefix) ? "MC" : m.MembershipCardNoPrefix.Trim().ToUpperInvariant(),
            MembershipCardWhatsAppRequired = m.MembershipCardWhatsAppRequired,
            MembershipCardEmailRequired = m.MembershipCardEmailRequired,
            MembershipCardAutoSendOnIssue = m.MembershipCardAutoSendOnIssue,
            MembershipRenewalWindowDays = m.MembershipRenewalWindowDays,
            MembershipDiscountWithManualDiscount = m.MembershipDiscountWithManualDiscount,
            MembershipRedeemOtpRequired = m.MembershipRedeemOtpRequired,
            MembershipPointsExpiryTime = TimeSpan.TryParse(m.MembershipPointsExpiryTime, out var expAt) ? expAt : new TimeSpan(1, 0, 0),
            MembershipRenewalReminderEnabled = m.MembershipRenewalReminderEnabled,
            MembershipRenewalReminderDays = NormalizeReminderDays(m.MembershipRenewalReminderDays),
            MembershipRenewalReminderTime = TimeSpan.TryParse(m.MembershipRenewalReminderTime, out var remAt) ? remAt : new TimeSpan(10, 0, 0),
            MembershipRenewalReminderTemplate = string.IsNullOrWhiteSpace(m.MembershipRenewalReminderTemplate) ? HospitalSettings.DefaultMembershipRenewalReminderMessage : m.MembershipRenewalReminderTemplate.Trim(),
            MembershipCardMessageTemplate = string.IsNullOrWhiteSpace(m.MembershipCardMessageTemplate) ? HospitalSettings.DefaultMembershipCardMessage : m.MembershipCardMessageTemplate.Trim(),
            DoctorIpAutoRunTime = m.DoctorIpComputeMode != "Manual" && TimeSpan.TryParse(m.DoctorIpAutoRunTime, out var ipRun) ? ipRun : null,
            LabPatientPortalRequired = m.LabPatientPortalRequired,
            OpdFollowUpNotificationRequired = m.OpdFollowUpNotificationRequired,
            OpdCertificateNotificationRequired = m.OpdCertificateNotificationRequired,
            DayClosingBlockBilling = m.DayClosingBlockBilling,
            DayClosingAllowSelfVerify = m.DayClosingAllowSelfVerify,
            DayClosingLoginReminder = m.DayClosingLoginReminder,
            PharmacyEnabled = m.PharmacyEnabled,
            PharmacyName = m.PharmacyName,
            PharmacyDrugLicence20B = m.PharmacyDrugLicence20B,
            PharmacyDrugLicence20BValidTo = m.PharmacyDrugLicence20BValidTo,
            PharmacyDrugLicence21B = m.PharmacyDrugLicence21B,
            PharmacyDrugLicence21BValidTo = m.PharmacyDrugLicence21BValidTo,
            PharmacyGstin = string.IsNullOrWhiteSpace(m.PharmacyGstin) ? null : m.PharmacyGstin.Trim().ToUpperInvariant(),
            PharmacistName = m.PharmacistName,
            PharmacistRegNo = m.PharmacistRegNo,
            PharmacyNdpsLicenceNo = m.PharmacyNdpsLicenceNo,
            PharmacyContactNo = m.PharmacyContactNo,
            PharmacyAllowNegativeStock = m.PharmacyAllowNegativeStock,
            PharmacyMinShelfLifeSaleDays = m.PharmacyMinShelfLifeSaleDays,
            PharmacyMinShelfLifeIpdDays = m.PharmacyMinShelfLifeIpdDays,
            PharmacyMinShelfLifeGrnDays = m.PharmacyMinShelfLifeGrnDays,
            PharmacyNearExpiryAlertDays = m.PharmacyNearExpiryAlertDays,
            PharmacySaleReturnDays = m.PharmacySaleReturnDays,
            PharmacyLooseReturnAllowed = m.PharmacyLooseReturnAllowed,
            PharmacyMaxManualDiscountPercent = m.PharmacyMaxManualDiscountPercent,
            PharmacyIpdGstExempt = m.PharmacyIpdGstExempt,
            PharmacyBlockDischargeOnPendingIndent = m.PharmacyBlockDischargeOnPendingIndent,
            PharmacyTtoBillingMode = m.PharmacyTtoBillingMode == "SALE" ? "SALE" : "IPD",
            PharmacyRoundOffBill = m.PharmacyRoundOffBill,
            PharmacyBillPrintFormat = m.PharmacyBillPrintFormat is "A5" or "80MM" ? m.PharmacyBillPrintFormat : "A4",
            PharmacyBillNotificationRequired = m.PharmacyBillNotificationRequired,
            PharmacyGrnNotRequired = m.PharmacyGrnNotRequired,
            LoginRetryCount = m.LoginRetryCount,
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

    /// <summary>"30, 15,1,15" -> "30,15,1": distinct days 0..365, largest first; empty falls back to 30,15,1.</summary>
    private static string NormalizeReminderDays(string? value)
    {
        var days = (value ?? string.Empty).Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(v => int.TryParse(v, out var d) ? d : -1)
            .Where(d => d is >= 0 and <= 365)
            .Distinct().OrderByDescending(d => d).ToList();
        return days.Count == 0 ? "30,15,1" : string.Join(",", days);
    }
}
