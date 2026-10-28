using System.Security.Claims;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.ViewFeatures;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Options;

namespace EMR.Web.Services;

/// <summary>What the printed document adds to the data points (bill / report number, dates, who printed it).</summary>
public class PrintDocInfo
{
    public string? DocNo { get; set; }
    public string? DocDate { get; set; }
    public string? TokenNo { get; set; }
    public string? CopyLabel { get; set; } = "Original";
    public string? ProcessingLab { get; set; }
    public string? PrintedAt { get; set; }
    public string? PrintedBy { get; set; }
    public string? CreatedBy { get; set; }
}

/// <summary>
/// Utility > Print Templates at print time (SQLScripts/2324): the branch's published header / footer template for bills
/// or lab reports (cached; dropped when a template is published or assigned), the values of its data points, and the
/// draft of a template for the designer's preview. No template, or EMR.Api not reachable = null = the Classic print.
/// </summary>
public interface IPrintTemplateRuntime
{
    Task<PrintLayout?> ResolveAsync(int branchId, string kind);
    Task<PrintLayout?> DraftAsync(int companyId, int templateId);
    Task<Dictionary<string, string?>> ValuesAsync(int branchId, PrintDocInfo doc);
    Task<HospitalSettings?> SettingsAsync(int branchId);
    /// <summary>Puts the template (or the previewed draft) of a bill into ViewData: PrintTemplate, PrintValues, PrintLogoUrl.</summary>
    Task ApplyToBillAsync(ViewDataDictionary viewData, ClaimsPrincipal user, int branchId, PrintDocInfo doc, int? previewTemplateId);
    /// <summary>The template (or previewed draft) of a lab report, and its values; null = the Classic report.</summary>
    Task<(PrintLayout? Layout, Dictionary<string, string?> Values)> ForReportAsync(ClaimsPrincipal? user, int companyId, int branchId, PrintDocInfo doc, int? previewTemplateId);
    void Invalidate();
}

public class PrintTemplateRuntime(
    IPrintTemplateApiClient api,
    ApplicationDbContext db,
    IMemoryCache cache,
    IPermissionService permissions,
    IOptionsMonitor<EmrAuthorizationOptions> authOptions,
    ILogger<PrintTemplateRuntime> logger) : IPrintTemplateRuntime
{
    public const string PageCode = "UTILITY.PRINTTEMPLATES";
    private static int generation;   // bumped on publish / assign: every cached layout is read again

    public void Invalidate() => Interlocked.Increment(ref generation);

    public async Task<PrintLayout?> ResolveAsync(int branchId, string kind)
    {
        if (branchId <= 0) return null;
        var key = $"ptpl:{Volatile.Read(ref generation)}:{branchId}:{kind}";
        if (cache.TryGetValue(key, out PrintLayout? hit)) return hit;
        PrintLayout? layout = null;
        try
        {
            var r = await api.ResolveAsync(branchId, kind);
            layout = PrintLayout.Parse(r?.LayoutJson);
        }
        catch (Exception ex)
        {
            // never stop a print: the Classic header / footer is used
            logger.LogWarning(ex, "Print template of branch {BranchId} ({Kind}) could not be read; the Classic print is used.", branchId, kind);
            return null;
        }
        cache.Set(key, layout, TimeSpan.FromMinutes(5));
        return layout;
    }

    public async Task<PrintLayout?> DraftAsync(int companyId, int templateId)
    {
        try { return PrintLayout.Parse((await api.GetAsync(companyId, templateId))?.DraftJson); }
        catch (Exception ex) { logger.LogWarning(ex, "Draft of print template {TemplateId} could not be read.", templateId); return null; }
    }

    public async Task<HospitalSettings?> SettingsAsync(int branchId) =>
        await db.HospitalSettings.AsNoTracking().Where(s => s.BranchId == branchId)
            .OrderByDescending(s => s.IsActive).ThenByDescending(s => s.Id).FirstOrDefaultAsync();

    public async Task<Dictionary<string, string?>> ValuesAsync(int branchId, PrintDocInfo doc)
    {
        var s = await SettingsAsync(branchId);
        var branchName = await db.BranchMasters.AsNoTracking().Where(b => b.BranchId == branchId).Select(b => b.BranchName).FirstOrDefaultAsync();
        var nabh = s?.NabhStatus?.Trim();
        bool showNabh = !string.IsNullOrWhiteSpace(nabh) && !new[] { "not applied", "n/a", "na", "none", "not applicable" }.Contains(nabh.ToLowerInvariant());
        string? validity = s?.NabhValidFrom is { } f && s.NabhValidTo is { } t ? $"{f:dd-MMM-yyyy} to {t:dd-MMM-yyyy}" : null;
        return new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase)
        {
            ["hospitalName"] = s?.HospitalName,
            ["hospitalType"] = s?.HospitalType,
            ["registrationNo"] = s?.RegistrationNumber,
            ["gstCode"] = s?.GSTCode,
            ["branchName"] = branchName,
            ["address"] = s?.Address,
            ["contact1"] = s?.ContactNumber1,
            ["contact2"] = s?.ContactNumber2,
            ["emergency"] = s?.EmergencyNumber,
            ["email"] = s?.EmailAddress,
            ["website"] = s?.Website,
            ["nabhStatus"] = showNabh ? nabh : null,
            ["nabhCertNo"] = showNabh ? s?.NabhCertificateNo : null,
            ["nabhValidity"] = showNabh ? validity : null,
            ["docNo"] = doc.DocNo,
            ["docDate"] = doc.DocDate,
            ["tokenNo"] = doc.TokenNo,
            ["copyLabel"] = doc.CopyLabel,
            ["processingLab"] = doc.ProcessingLab,
            ["printedAt"] = doc.PrintedAt ?? DateTime.Now.ToString("dd-MMM-yyyy hh:mm tt"),
            ["printedBy"] = doc.PrintedBy,
            ["createdBy"] = doc.CreatedBy,
            ["__logo"] = s?.LogoPath
        };
    }

    /// <summary>A draft is shown only to a user who may open Print Templates (the designer's Preview buttons).</summary>
    private async Task<bool> MayPreviewAsync(ClaimsPrincipal? user)
    {
        if (user is null) return false;
        var opts = authOptions.CurrentValue;
        var subject = PermissionSubjectReader.FromPrincipal(user);
        if (subject is null) return !opts.IsEnforced(PageCode);
        var set = await permissions.GetPermissionSetAsync(subject);
        return !set.Blocks(opts, PageCode, PermissionControls.View);
    }

    private async Task<PrintLayout?> LayoutAsync(ClaimsPrincipal? user, int companyId, int branchId, string kind, int? previewTemplateId) =>
        previewTemplateId is > 0 && await MayPreviewAsync(user)
            ? await DraftAsync(companyId, previewTemplateId.Value)
            : await ResolveAsync(branchId, kind);

    public async Task ApplyToBillAsync(ViewDataDictionary viewData, ClaimsPrincipal user, int branchId, PrintDocInfo doc, int? previewTemplateId)
    {
        var companyId = int.TryParse(user.FindFirst("CompanyId")?.Value, out var c) ? c : 1;
        var layout = await LayoutAsync(user, companyId, branchId, "BILL", previewTemplateId);
        if (layout is null) return;
        var values = await ValuesAsync(branchId, doc);
        viewData["PrintTemplate"] = layout;
        viewData["PrintValues"] = values;
        viewData["PrintLogoUrl"] = values.GetValueOrDefault("__logo");
    }

    public async Task<(PrintLayout? Layout, Dictionary<string, string?> Values)> ForReportAsync(ClaimsPrincipal? user, int companyId, int branchId, PrintDocInfo doc, int? previewTemplateId)
    {
        var layout = await LayoutAsync(user, companyId, branchId, "REPORT", previewTemplateId);
        return layout is null ? (null, new()) : (layout, await ValuesAsync(branchId, doc));
    }
}
