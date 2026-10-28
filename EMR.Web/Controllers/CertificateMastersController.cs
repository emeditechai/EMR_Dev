using EMR.Shared.Security;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Master > OPD Master > Certificate Masters (SQLScripts/2341): types, purposes, vaccines, signing doctors.</summary>
[Authorize]
public class CertificateMastersController(
    ICertificateService certificates,
    IAuditLogService auditLogService,
    IActionPermissionGuard permissionGuard,
    IWebHostEnvironment env) : Controller
{
    private int BranchId => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
    private int CompanyId => User.GetCompanyId();
    private static readonly string[] ImageTypes = [".png", ".jpg", ".jpeg", ".webp"];

    [HttpGet]
    public async Task<IActionResult> Index(string? tab)
    {
        await certificates.EnsureMastersAsync(CompanyId);
        ViewBag.Tab = tab ?? "types";
        ViewBag.Types = await certificates.GetTypesAsync(CompanyId, BranchId, false);
        ViewBag.Purposes = await certificates.GetPurposesAsync(CompanyId, false);
        ViewBag.Vaccines = await certificates.GetVaccinesAsync(CompanyId, false);
        ViewBag.Disabilities = await certificates.GetDisabilityTypesAsync();
        ViewBag.Doctors = await certificates.GetDoctorsAsync(CompanyId, BranchId, false);
        ViewBag.FeeServices = await certificates.GetFeeServicesAsync(CompanyId, BranchId);
        ViewBag.CanEdit = await permissionGuard.AllowsAsync(HttpContext, "MASTER.CERTIFICATEMASTERS", "EDIT");
        return View();
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveType(CertificateTypeRow row)
    {
        if (string.IsNullOrWhiteSpace(row.TypeName) || string.IsNullOrWhiteSpace(row.PrintTitle) || string.IsNullOrWhiteSpace(row.NumberPrefix))
            return Done("types", "Name, print title and number prefix are required.");
        if (!System.Text.RegularExpressions.Regex.IsMatch(row.NumberPrefix.Trim(), "^[A-Za-z0-9]{1,10}$"))
            return Done("types", "Number prefix: letters and digits only, up to 10.");
        row.NumberPrefix = row.NumberPrefix.Trim();
        await certificates.SaveTypeAsync(CompanyId, row, User.GetUserId());
        await auditLogService.LogAsync("CertificateMasters", "SaveType", $"Certificate type {row.TypeName} saved", User.GetUserId(), BranchId);
        return Done("types", null);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> SavePurpose(CertificatePurposeRow row)
    {
        if (string.IsNullOrWhiteSpace(row.PurposeName) || string.IsNullOrWhiteSpace(row.TypeCode)) return Done("purposes", "Type and purpose are required.");
        row.PurposeName = row.PurposeName.Trim();
        await certificates.SavePurposeAsync(CompanyId, row, User.GetUserId());
        await auditLogService.LogAsync("CertificateMasters", "SavePurpose", $"Certificate purpose {row.PurposeName} saved", User.GetUserId(), BranchId);
        return Done("purposes", null);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveVaccine(VaccineRow row)
    {
        if (string.IsNullOrWhiteSpace(row.VaccineName)) return Done("vaccines", "Vaccine name is required.");
        row.VaccineName = row.VaccineName.Trim();
        await certificates.SaveVaccineAsync(CompanyId, row, User.GetUserId());
        await auditLogService.LogAsync("CertificateMasters", "SaveVaccine", $"Vaccine {row.VaccineName} saved", User.GetUserId(), BranchId);
        return Done("vaccines", null);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveDoctor(SigningDoctorRow row, IFormFile? signatureFile, IFormFile? stampFile)
    {
        if (row.RegistrationYear is { } y && (y < 1950 || y > DateTime.Today.Year)) return Done("doctors", "Registration year is not valid.");
        try
        {
            row.SignaturePath = await SaveImageAsync(signatureFile, row.DoctorId, "sign");
            row.StampPath = await SaveImageAsync(stampFile, row.DoctorId, "stamp");
        }
        catch (InvalidOperationException ex) { return Done("doctors", ex.Message); }
        await certificates.SaveDoctorAsync(CompanyId, row, User.GetUserId());
        await auditLogService.LogAsync("CertificateMasters", "SaveDoctor", $"Signing doctor {row.DoctorId} saved (can sign: {row.CanSign})", User.GetUserId(), BranchId);
        return Done("doctors", null);
    }

    private async Task<string?> SaveImageAsync(IFormFile? file, int doctorId, string kind)
    {
        if (file == null || file.Length == 0) return null;
        var ext = Path.GetExtension(file.FileName).ToLowerInvariant();
        if (!ImageTypes.Contains(ext)) throw new InvalidOperationException("Signature / stamp: PNG, JPG or WEBP only.");
        if (file.Length > 1024 * 1024) throw new InvalidOperationException("Signature / stamp: up to 1 MB.");
        var dir = Path.Combine(env.WebRootPath, "uploads", "certificates");
        Directory.CreateDirectory(dir);
        var name = $"doctor{doctorId}_{kind}_{Guid.NewGuid():N}{ext}";
        await using (var fs = System.IO.File.Create(Path.Combine(dir, name))) await file.CopyToAsync(fs);
        return "/uploads/certificates/" + name;
    }

    private IActionResult Done(string tab, string? error)
    {
        if (error != null) TempData["Error"] = error; else TempData["Success"] = "Saved.";
        return RedirectToAction(nameof(Index), new { tab });
    }
}
