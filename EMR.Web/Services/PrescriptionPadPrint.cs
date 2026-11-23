using EMR.Web.ApiClients;
using EMR.Web.ApiClients.Models;
using EMR.Web.Data;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

/// <summary>
/// The doctor's prescription pad (OPD > Print Dr. Prescription, SQLScripts/2527) made ready to print: the visit, the
/// branch's Hospital Settings and its Dr. Prescription print template (Utility > Print Templates, SQLScripts/2530) - or,
/// without one, the Bill template header as before. Used by OPD/PrintPrescriptionPad and the designer's preview.
/// </summary>
public static class PrescriptionPadPrint
{
    public const string View = "~/Views/OPD/PrintPrescriptionPad.cshtml";

    /// <summary>The pad of a visit (null = not found / not this branch's). previewTemplateId: a draft to print with.</summary>
    public static async Task<PrescriptionPadInfo?> PrepareAsync(Controller c, IServiceBookingApiClient api, ApplicationDbContext db,
        IPrintTemplateRuntime runtime, int opdServiceId, int? branchId, int? previewTemplateId)
    {
        var pad = await api.GetPrescriptionPadAsync(opdServiceId, branchId);
        if (pad is null) return null;

        var settings = await db.HospitalSettings.AsNoTracking().FirstOrDefaultAsync(s => s.BranchId == pad.BranchId);
        var branch = await db.BranchMasters.AsNoTracking().FirstOrDefaultAsync(b => b.BranchId == pad.BranchId);
        c.ViewBag.Settings = settings;
        c.ViewBag.BranchName = branch?.BranchName ?? string.Empty;
        // pre-printed letterhead (as the bill): blank space instead of the header; the designer's preview always shows it
        c.ViewBag.ShowHeaderFooter = previewTemplateId is > 0 || (settings?.LabB2CBillPrintHeaderRequired ?? true);
        await runtime.ApplyToPrescriptionAsync(c.ViewData, c.User, pad.BranchId, new PrintDocInfo
        {
            DocNo = pad.OPDBillNo,
            DocDate = pad.VisitDate.ToString("dd-MMM-yyyy"),
            TokenNo = pad.TokenNo,
            CopyLabel = "Prescription",
            PrintedBy = c.User?.FindFirst("DisplayName")?.Value ?? c.User?.Identity?.Name,
            CreatedBy = pad.CreatedByUser
        }, previewTemplateId);
        return pad;
    }
}
