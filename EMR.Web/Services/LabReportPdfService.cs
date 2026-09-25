using System.Security.Claims;
using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.DTOs;
using EMR.Web.Models.ViewModels;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

/// <summary>
/// Builds the printable Lab Report. Shared by the Report Entry page and the Report Dispatch dashboard
/// so both print exactly the same document.
/// </summary>
public interface ILabReportPdfService
{
    /// <summary>The report view model, or null when the order has no reporting detail.</summary>
    /// <param name="scope">"all" (default), "approved" or "pending" - see <see cref="LabReportPrintBuilder"/>.</param>
    Task<LabReportPrintViewModel?> BuildAsync(int labOrderId, ClaimsPrincipal user, string scope = LabReportPrintBuilder.ScopeAll);

    /// <summary>Hospital logo bytes for the letterhead (png / jpg inside wwwroot only).</summary>
    byte[]? LoadLogo(string? logoPath);

    /// <summary>Reads an uploaded signature from App_Data/signatures (png / jpg only).</summary>
    byte[]? LoadSignature(string? signaturePath);

    /// <summary>How many times the report of this bill has already been printed (audit trail).</summary>
    Task<int> GetPrintCountAsync(string? billNo, string scope = LabReportPrintBuilder.ScopeAll);
}

public class LabReportPdfService(
    ILabReportingApiClient labReportingApiClient,
    ILabOrderApiClient labOrderApiClient,
    ILabReportingConditionApiClient conditionApiClient,
    ILabDefaultSignatoryApiClient defaultSignatoryApiClient,
    ApplicationDbContext dbContext,
    IWebHostEnvironment env) : ILabReportPdfService
{
    public const string PrintedAction = "LAB.ReportPrinted";

    public async Task<LabReportPrintViewModel?> BuildAsync(int labOrderId, ClaimsPrincipal user, string scope = LabReportPrintBuilder.ScopeAll)
    {
        scope = LabReportPrintBuilder.NormalizeScope(scope);
        var detail = await labReportingApiClient.GetDetailAsync(labOrderId);
        if (detail == null) return null;

        LabReportPrintMetaDto? meta = null;
        try { meta = await labReportingApiClient.GetPrintMetaAsync(labOrderId); }
        catch (HttpRequestException) { /* the report still prints without the extra grouping data */ }

        LabOrderDetailDto? order = null;
        try { order = await labOrderApiClient.GetOrderDetailAsync(labOrderId); }
        catch (HttpRequestException) { /* patient fields fall back to the reporting detail */ }

        var settings = await dbContext.HospitalSettings
            .Where(s => s.BranchId == detail.BranchId && s.IsActive)
            .FirstOrDefaultAsync();
        var branch = await dbContext.BranchMasters
            .FirstOrDefaultAsync(b => b.BranchId == detail.BranchId);

        var printedBy = user.FindFirst("DisplayName")?.Value ?? user.Identity?.Name ?? "System";

        // The signature panel is decided server side from how the bill was actually approved:
        // level-by-level on the Pathologist Dashboard, or from the Entry screen (then the branch's configured
        // signatories, or the approver). This call never blocks the print.
        List<LabReportSignoffLevelDto> signoffLevels = [];
        try { signoffLevels = await labReportingApiClient.GetSignoffPanelAsync(labOrderId, detail.BranchId, reportingType: "Numeric"); }
        catch (HttpRequestException) { /* the report still prints without the signature panel */ }

        var vm = LabReportPrintBuilder.Build(detail, order, meta, settings, branch, printedBy, DateTime.Now, scope, signoffLevels);

        // the uploaded signature images live outside wwwroot and are read here, by file name only
        foreach (var level in vm.LevelSignatories)
            level.SignatureImage = LoadSignature(signoffLevels.FirstOrDefault(l => l.LevelNo == level.LevelNo)?.SignaturePath);

        // Conditions of Reporting master: the order's own company + billing branch (not the signed-in user's)
        try
        {
            var conditions = await conditionApiClient.GetForReportAsync(branch?.CompanyId ?? user.GetCompanyId(), detail.BranchId);
            if (conditions is { HasConfiguration: true })
                vm.Conditions = conditions.Conditions;
        }
        catch (HttpRequestException) { /* fall back to the built-in conditions text */ }

        // Every copy after the first one is a duplicate, on screen and on paper.
        vm.PrintSequence = await GetPrintCountAsync(vm.BillNo, scope) + 1;

        return vm;
    }

    /// <summary>Description marker of a print of the "not approved" copy; those prints are counted separately.</summary>
    public const string PendingCopyMarker = "[scope:pending]";

    public async Task<int> GetPrintCountAsync(string? billNo, string scope = LabReportPrintBuilder.ScopeAll)
    {
        if (string.IsNullOrWhiteSpace(billNo)) return 0;

        try
        {
            // The "not approved" copy and the approved / full report are different documents: printing one must not
            // turn the first print of the other into a DUPLICATE.
            var pending = LabReportPrintBuilder.NormalizeScope(scope) == LabReportPrintBuilder.ScopePending;
            var query = dbContext.AuditLogs
                .AsNoTracking()
                .Where(a => a.ModuleCode == "LAB" && a.ActionName == PrintedAction && a.ReferenceNo == billNo);

            return pending
                ? await query.CountAsync(a => a.Description != null && a.Description.Contains(PendingCopyMarker))
                : await query.CountAsync(a => a.Description == null || !a.Description.Contains(PendingCopyMarker));
        }
        catch
        {
            return 0; // the duplicate marker is informational - never block the print
        }
    }

    /// <summary>
    /// Reads an uploaded signature from App_Data/signatures. Only a bare file name is accepted, so a stored value
    /// can never walk out of that folder.
    /// </summary>
    public byte[]? LoadSignature(string? signaturePath)
    {
        if (string.IsNullOrWhiteSpace(signaturePath)) return null;

        try
        {
            var name = Path.GetFileName(signaturePath.Trim());
            if (string.IsNullOrWhiteSpace(name)) return null;

            var ext = Path.GetExtension(name).ToLowerInvariant();
            if (ext is not (".png" or ".jpg" or ".jpeg")) return null;

            var root = Path.GetFullPath(Path.Combine(env.ContentRootPath, "App_Data", "signatures"));
            var full = Path.GetFullPath(Path.Combine(root, name));
            if (!full.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.Ordinal) || !File.Exists(full))
                return null;

            return File.ReadAllBytes(full);
        }
        catch
        {
            return null;   // a missing signature must never stop a report printing
        }
    }

    /// <summary>Reads the hospital logo from wwwroot (png/jpg only, and only from inside wwwroot).</summary>
    public byte[]? LoadLogo(string? logoPath)
    {
        if (string.IsNullOrWhiteSpace(logoPath)) return null;

        try
        {
            var relative = logoPath.Split('?')[0].TrimStart('~', '/', '\\');
            var root = Path.GetFullPath(env.WebRootPath);
            var full = Path.GetFullPath(Path.Combine(root, relative));

            if (!full.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.Ordinal) || !File.Exists(full))
                return null;

            var ext = Path.GetExtension(full).ToLowerInvariant();
            return ext is ".png" or ".jpg" or ".jpeg" ? File.ReadAllBytes(full) : null;
        }
        catch
        {
            return null;
        }
    }
}
