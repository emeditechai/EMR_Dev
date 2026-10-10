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
    /// <param name="reportingType">Which report: "Numeric" (Lab Report Entry, default) or "Template" (Microbiology Report Entry).</param>
    Task<LabReportPrintViewModel?> BuildAsync(int labOrderId, ClaimsPrincipal user, string scope = LabReportPrintBuilder.ScopeAll, string reportingType = "Numeric");

    /// <summary>Hospital logo bytes for the letterhead (png / jpg inside wwwroot only).</summary>
    byte[]? LoadLogo(string? logoPath);

    /// <summary>Reads an uploaded signature from App_Data/signatures (png / jpg only).</summary>
    byte[]? LoadSignature(string? signaturePath);

    /// <summary>How many times the report of this bill has already been printed (audit trail), per report type.</summary>
    Task<int> GetPrintCountAsync(string? billNo, string scope = LabReportPrintBuilder.ScopeAll, string reportingType = LabReportTypes.Numeric);

    /// <summary>The reports of the bill that have something to print in this scope: Numeric (Lab Report) and/or Template (Microbiology).</summary>
    Task<List<string>> GetPrintableReportTypesAsync(int labOrderId, string scope = LabReportPrintBuilder.ScopeAll);
}

/// <summary>
/// The lab reports printed as a PDF: the Lab Report (Numeric tests, Lab Report Entry) and the Microbiology Report
/// (Reporting Type Template, Microbiology Report Entry). Image reports have their own print page.
/// </summary>
public static class LabReportTypes
{
    public const string Numeric = "Numeric";
    public const string Template = "Template";

    /// <summary>Marks the audit entry of a Microbiology report print, so each report counts its own original / duplicate copies.</summary>
    public const string TemplateCopyMarker = "[report:template]";

    public static string Normalize(string? type) =>
        string.Equals(type?.Trim(), Template, StringComparison.OrdinalIgnoreCase) ? Template : Numeric;

    public static string Title(string type) => Normalize(type) == Template ? "Microbiology report" : "Lab report";

    public static string FilePrefix(string type) => Normalize(type) == Template ? "MicrobiologyReport" : "LabReport";

    /// <summary>" [report:template]" for a Microbiology print, nothing for the Lab Report (existing entries stay as they are).</summary>
    public static string Marker(string type) => Normalize(type) == Template ? " " + TemplateCopyMarker : string.Empty;
}

public class LabReportPdfService(
    ILabReportingApiClient labReportingApiClient,
    ILabOrderApiClient labOrderApiClient,
    ILabReportingConditionApiClient conditionApiClient,
    ILabDefaultSignatoryApiClient defaultSignatoryApiClient,
    ILabParameterOptionApiClient parameterOptionApiClient,
    ApplicationDbContext dbContext,
    IWebHostEnvironment env) : ILabReportPdfService
{
    public const string PrintedAction = "LAB.ReportPrinted";

    public async Task<LabReportPrintViewModel?> BuildAsync(int labOrderId, ClaimsPrincipal user, string scope = LabReportPrintBuilder.ScopeAll, string reportingType = "Numeric")
    {
        scope = LabReportPrintBuilder.NormalizeScope(scope);
        var detail = await labReportingApiClient.GetDetailAsync(labOrderId, null, reportingType);
        if (detail == null) return null;

        // Microbiology (Template) report: a picklist parameter has no numeric range - its normal answers are printed instead.
        if (!string.Equals(reportingType, "Numeric", StringComparison.OrdinalIgnoreCase))
            await FillPicklistRangesAsync(detail, user);

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
        try { signoffLevels = await labReportingApiClient.GetSignoffPanelAsync(labOrderId, detail.BranchId, reportingType: reportingType); }
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
        vm.PrintSequence = await GetPrintCountAsync(vm.BillNo, scope, reportingType) + 1;

        return vm;
    }

    private async Task FillPicklistRangesAsync(LabReportingOrderDetailDto detail, ClaimsPrincipal user)
    {
        var picklist = detail.Items
            .Where(i => string.Equals(i.ReportingType?.Trim(), "Select", StringComparison.OrdinalIgnoreCase) && (string.IsNullOrWhiteSpace(i.ReferenceRange) || i.ReferenceRange.Trim() == "—"))
            .ToList();
        if (picklist.Count == 0) return;

        try
        {
            var testIds = picklist.Select(i => i.InvestigationID).ToHashSet();
            var normal = (await parameterOptionApiClient.GetListAsync(status: true, companyId: user.GetCompanyId()))
                .Where(o => testIds.Contains(o.Test_ID) && !o.Is_Abnormal)
                .GroupBy(o => o.Test_ID)
                .ToDictionary(g => g.Key, g => string.Join(" / ", g.OrderBy(o => o.Display_Order).Select(o => o.Option_Text)));
            foreach (var i in picklist)
                if (normal.TryGetValue(i.InvestigationID, out var text)) i.ReferenceRange = text;
        }
        catch (HttpRequestException) { /* the report still prints without them */ }
    }

    /// <summary>Description marker of a print of the "not approved" copy; those prints are counted separately.</summary>
    public const string PendingCopyMarker = "[scope:pending]";

    public async Task<List<string>> GetPrintableReportTypesAsync(int labOrderId, string scope = LabReportPrintBuilder.ScopeAll)
    {
        scope = LabReportPrintBuilder.NormalizeScope(scope);
        var types = new List<string>();
        foreach (var type in new[] { LabReportTypes.Numeric, LabReportTypes.Template })
        {
            var detail = await labReportingApiClient.GetDetailAsync(labOrderId, null, type);
            if (detail?.Items is { Count: > 0 } && LabReportPrintBuilder.Summarize(detail, scope).IncludedTestCount > 0)
                types.Add(type);
        }
        return types;
    }

    public async Task<int> GetPrintCountAsync(string? billNo, string scope = LabReportPrintBuilder.ScopeAll, string reportingType = LabReportTypes.Numeric)
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
            // The Lab Report and the Microbiology Report of a bill are separate documents, each with its own first print.
            query = LabReportTypes.Normalize(reportingType) == LabReportTypes.Template
                ? query.Where(a => a.Description != null && a.Description.Contains(LabReportTypes.TemplateCopyMarker))
                : query.Where(a => a.Description == null || !a.Description.Contains(LabReportTypes.TemplateCopyMarker));

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
