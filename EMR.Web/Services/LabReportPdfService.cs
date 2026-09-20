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
    Task<LabReportPrintViewModel?> BuildAsync(int labOrderId, ClaimsPrincipal user);

    /// <summary>Hospital logo bytes for the letterhead (png / jpg inside wwwroot only).</summary>
    byte[]? LoadLogo(string? logoPath);

    /// <summary>How many times the report of this bill has already been printed (audit trail).</summary>
    Task<int> GetPrintCountAsync(string? billNo);
}

public class LabReportPdfService(
    ILabReportingApiClient labReportingApiClient,
    ILabOrderApiClient labOrderApiClient,
    ILabReportingConditionApiClient conditionApiClient,
    ApplicationDbContext dbContext,
    IWebHostEnvironment env) : ILabReportPdfService
{
    public const string PrintedAction = "LAB.ReportPrinted";

    public async Task<LabReportPrintViewModel?> BuildAsync(int labOrderId, ClaimsPrincipal user)
    {
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
        var vm = LabReportPrintBuilder.Build(detail, order, meta, settings, branch, printedBy, DateTime.Now);

        // Conditions of Reporting master: the order's own company + billing branch (not the signed-in user's)
        try
        {
            var conditions = await conditionApiClient.GetForReportAsync(branch?.CompanyId ?? user.GetCompanyId(), detail.BranchId);
            if (conditions is { HasConfiguration: true })
                vm.Conditions = conditions.Conditions;
        }
        catch (HttpRequestException) { /* fall back to the built-in conditions text */ }

        // Every copy after the first one is a duplicate, on screen and on paper.
        vm.PrintSequence = await GetPrintCountAsync(vm.BillNo) + 1;

        return vm;
    }

    public async Task<int> GetPrintCountAsync(string? billNo)
    {
        if (string.IsNullOrWhiteSpace(billNo)) return 0;

        try
        {
            return await dbContext.AuditLogs
                .AsNoTracking()
                .CountAsync(a => a.ModuleCode == "LAB" && a.ActionName == PrintedAction && a.ReferenceNo == billNo);
        }
        catch
        {
            return 0; // the duplicate marker is informational - never block the print
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
