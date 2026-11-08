using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Services;

/// <summary>
/// Header / footer of an IPD print (views in EMR.Web.Ipd, SQLScripts/2422+): the branch's Bill print template
/// (Utility > Print Templates) when assigned, else the hospital details of Hospital Settings - as OPD and LAB bills.
/// </summary>
public static class IpdPrint
{
    public static async Task PrepareAsync(Controller c, IPrintTemplateRuntime runtime, ILogger logger, int branchId, PrintDocInfo doc)
    {
        var s = await runtime.SettingsAsync(branchId);
        c.ViewBag.PrintHospital = new IpdPrintHospital
        {
            Name = s?.HospitalName, Address = s?.Address, Phone = s?.ContactNumber1, Email = s?.EmailAddress, Gstin = s?.GSTCode,
            RegistrationNo = s?.RegistrationNumber, Nabh = s?.NabhStatus, LogoPath = s?.LogoPath
        };
        c.ViewBag.PrintedBy = doc.PrintedBy;
        try
        {
            await runtime.ApplyToBillAsync(c.ViewData, c.User, branchId, doc, null);
            if (c.ViewData["PrintTemplate"] is PrintLayout layout && c.ViewData["PrintValues"] is Dictionary<string, string?> values)
            {
                var logo = c.ViewData["PrintLogoUrl"] as string;
                c.ViewData["IpdBandHeader"] = new PrintBandView { Band = layout.Header, Values = values, LogoUrl = logo };
                c.ViewData["IpdBandFooter"] = new PrintBandView { Band = layout.Footer, IsFooter = true, Values = values, LogoUrl = logo };
            }
        }
        catch (Exception ex) { logger.LogWarning(ex, "IPD print: Bill template not applied, the classic header is used"); }
    }

    public static string PrintedBy(this Controller c) => c.User.FindFirst("DisplayName")?.Value ?? c.User.Identity?.Name ?? "";
}
