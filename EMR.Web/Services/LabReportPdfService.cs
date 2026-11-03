using System.Security.Claims;
using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.DTOs;
using EMR.Web.Models.ViewModels;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Caching.Memory;

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

    /// <summary>Utility > Print Templates (SQLScripts/2324): puts the branch's Lab Report template (or, for the designer's
    /// preview, a template's draft) on the report. BuildAsync already applies the published one.</summary>
    Task ApplyPrintTemplateAsync(LabReportPrintViewModel vm, ClaimsPrincipal? user, int companyId, int? previewTemplateId);
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
    IWebHostEnvironment env,
    IPrintTemplateRuntime printTemplates,
    ILabFtpService ftp,
    Microsoft.Extensions.Caching.Memory.IMemoryCache cache,
    ILogger<LabReportPdfService> logger) : ILabReportPdfService
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

        // Investigation Master > Reporting Name is the name printed on the report (every format); the screens keep the
        // Test Name. A test without a reporting name prints its Test Name (SQLScripts/2223).
        try
        {
            var ids = detail.Items.Select(i => i.InvestigationID).Where(i => i > 0).Distinct().ToList();
            if (ids.Count > 0)
            {
                var names = (await Dapper.SqlMapper.QueryAsync<(int Id, string Name)>(dbContext.Database.GetDbConnection(),
                        @"SELECT Test_ID, LTRIM(RTRIM(Reporting_Name)) FROM dbo.LabInvestigationMaster
                           WHERE Test_ID IN @ids AND NULLIF(LTRIM(RTRIM(Reporting_Name)), '') IS NOT NULL", new { ids }))
                    .ToDictionary(x => x.Id, x => x.Name);
                foreach (var item in detail.Items)
                    if (names.TryGetValue(item.InvestigationID, out var printName)) item.TestName = printName;
            }
        }
        catch (Exception) { /* the report prints with the Test Name */ }

        var vm = LabReportPrintBuilder.Build(detail, order, meta, settings, branch, printedBy, DateTime.Now, scope, signoffLevels);
        // franchise B2B bill whose Report Header Required is No: no header / footer (B2C and company B2B unchanged)
        vm.FranchiseHeaderRequired = await LabFranchiseHeader.ForOrderAsync(dbContext, labOrderId);
        if (vm.FranchiseHeaderRequired == false) vm.ShowLetterhead = false;

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

        // LAB > External Document Upload (SQLScripts/2391): each approved test's external document, merged below the test
        await AttachExternalDocumentsAsync(vm, labOrderId, branch?.CompanyId ?? user.GetCompanyId());

        // Every copy after the first one is a duplicate, on screen and on paper.
        vm.PrintSequence = await GetPrintCountAsync(vm.BillNo, scope, reportingType) + 1;

        // Utility > Print Templates (SQLScripts/2324): the billing branch's Lab Report template, for every print,
        // email and WhatsApp copy alike (none = the Classic letterhead and footer)
        await ApplyPrintTemplateAsync(vm, user, branch?.CompanyId ?? user.GetCompanyId(), null);

        return vm;
    }

    // a row of dbo.usp_Lab_ExternalDoc_ForReport (properties, so extra columns of the procedure do not break the read)
    private sealed class ExternalDocRow
    {
        public int DocumentId { get; set; }
        public int CompanyId { get; set; }
        public int BranchId { get; set; }
        public int InvestigationId { get; set; }
        public string? OriginalFileName { get; set; }
        public string FileName { get; set; } = "";
        public string FilePath { get; set; } = "";
        public string? ContentType { get; set; }
        public DateTime UpdatedDate { get; set; }
    }

    private const int MaxExternalPages = 15;

    /// <summary>
    /// Merges the external documents (dbo.LabExternalDocument) into the report: a document goes under the group of its test,
    /// only when that test is printed and approved. PDF pages become images (150 dpi), JPG / PNG are used as they are;
    /// a Word file or an unreachable FTP server leaves a note instead. Files are cached for 10 minutes per upload, so a
    /// reprint or the e-mail / WhatsApp copy does not read the FTP server again. Never blocks the report.
    /// </summary>
    private async Task AttachExternalDocumentsAsync(LabReportPrintViewModel vm, int labOrderId, int companyId)
    {
        try
        {
            var docs = (await Dapper.SqlMapper.QueryAsync<ExternalDocRow>(dbContext.Database.GetDbConnection(),
                "dbo.usp_Lab_ExternalDoc_ForReport", new { LabOrderId = labOrderId }, commandType: System.Data.CommandType.StoredProcedure)).ToList();
            if (docs.Count == 0) return;

            foreach (var d in docs)
            {
                var group = vm.Sections.SelectMany(s => s.Groups)
                    .FirstOrDefault(g => g.Rows.Any(r => r.InvestigationId == d.InvestigationId && r.IsApproved));
                if (group is null) continue;   // the test is not on this report, or not approved yet
                var row = group.Rows.First(r => r.InvestigationId == d.InvestigationId);

                var ext = new LabReportExternalDoc { TestName = row.TestName, FileName = d.OriginalFileName ?? d.FileName };
                var kind = ExternalKind(d.FileName, d.ContentType);
                if (kind == "word")
                    ext.Note = $"External document \"{ext.FileName}\" (Word file) is not printed here - it is kept with the booking.";
                else
                {
                    var key = $"labextdoc:{d.DocumentId}:{d.UpdatedDate.Ticks}";
                    var pages = await cache.GetOrCreateAsync(key, async e =>
                    {
                        e.AbsoluteExpirationRelativeToNow = TimeSpan.FromMinutes(10);
                        var settings = await ftp.GetForBranchAsync(d.CompanyId > 0 ? d.CompanyId : companyId, d.BranchId);
                        if (settings is null) return null;
                        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(45));
                        var bytes = await ftp.DownloadAsync(settings, d.FilePath, cts.Token);
                        if (bytes is null || bytes.Length == 0) return null;
                        return kind == "pdf" ? PdfPages(bytes) : new List<byte[]> { bytes };
                    });
                    if (pages is { Count: > 0 }) ext.Pages = pages;
                    else
                    {
                        cache.Remove(key);   // not kept: the next print tries the server again
                        ext.Note = $"External document \"{ext.FileName}\" could not be read from the document server.";
                    }
                }
                group.ExternalDocuments.Add(ext);
            }
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "External documents of lab order {LabOrderId} were not merged into the report", labOrderId);
        }
    }

    private static string ExternalKind(string fileName, string? contentType)
    {
        var ext = Path.GetExtension(fileName).ToLowerInvariant();
        if (ext == ".pdf" || string.Equals(contentType, "application/pdf", StringComparison.OrdinalIgnoreCase)) return "pdf";
        if (ext is ".jpg" or ".jpeg" or ".png") return "image";
        return "word";
    }

    /// <summary>The pages of a PDF as PNG images (at most <see cref="MaxExternalPages"/>).</summary>
    private static List<byte[]> PdfPages(byte[] pdf)
    {
        var pages = new List<byte[]>();
        int count;
        using (var s = new MemoryStream(pdf)) count = Math.Min(PDFtoImage.Conversion.GetPageCount(s), MaxExternalPages);
        for (var i = 0; i < count; i++)
        {
            using var src = new MemoryStream(pdf);
            using var png = new MemoryStream();
            PDFtoImage.Conversion.SavePng(png, src, i, options: new PDFtoImage.RenderOptions(Dpi: 150, BackgroundColor: SkiaSharp.SKColors.White));
            pages.Add(png.ToArray());
        }
        return pages;
    }

    public async Task ApplyPrintTemplateAsync(LabReportPrintViewModel vm, ClaimsPrincipal? user, int companyId, int? previewTemplateId)
    {
        if (vm.BranchId <= 0) return;
        var lab = vm.ProcessingLabName ?? vm.HospitalName;
        var (layout, values) = await printTemplates.ForReportAsync(user, companyId, vm.BranchId, new PrintDocInfo
        {
            DocNo = vm.BillNo,
            DocDate = vm.Reported?.ToString("dd-MMM-yyyy hh:mm tt"),
            CopyLabel = vm.IsDuplicate ? $"Duplicate copy - print #{vm.PrintSequence}" : "Original",
            ProcessingLab = string.IsNullOrWhiteSpace(vm.ProcessingLabAddress) ? lab : $"{lab}, {vm.ProcessingLabAddress}",
            PrintedAt = vm.PrintedOn.ToString("dd-MMM-yyyy hh:mm tt"),
            PrintedBy = vm.PrintedBy
        }, previewTemplateId);
        vm.PrintTemplate = layout;
        vm.PrintValues = values;
        vm.PrintImages.Clear();
        if (layout is null) return;
        // uploaded images are read now: the PDF is drawn without file access
        foreach (var path in new[] { layout.Header, layout.Footer }.SelectMany(b => b.Rows).SelectMany(r => r.Cols).SelectMany(c => c.Blocks)
                     .Where(b => b.Type == "image" && !string.IsNullOrWhiteSpace(b.ImageUrl)).Select(b => b.ImageUrl!).Distinct())
            if (LoadLogo(path) is { } bytes) vm.PrintImages[path] = bytes;
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
