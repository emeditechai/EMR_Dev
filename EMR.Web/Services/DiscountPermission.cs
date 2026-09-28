using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

/// <summary>
/// Giving a discount is its own control (DISCOUNT) on each billing screen, ticked explicitly in Settings > Security.
/// The booking saves check their own screen. The shared payment modal (/OPD/SavePayment) does not say which screen
/// it was opened from, so there a user may discount when they hold DISCOUNT on any billing screen of the bill's module.
/// </summary>
public static class DiscountPermission
{
    private static readonly string[] OpdScreens = ["OPD.PATIENTREGISTRATION", "OPD.SERVICEBOOKING", "OPD.DASHBOARD"];
    private static readonly string[] LabScreens =
        ["LAB.LABORDERBOOKING.B2CBOOKING", "LAB.LABORDERBOOKING.B2BBOOKING", "LAB.LABORDERBOOKING.B2CORDERLIST", "LAB.LABORDERBOOKING.B2BREGISTRATION"];

    /// <summary>The billing screens of a module (OPD / LAB) where the payment modal can give a discount.</summary>
    public static IReadOnlyList<string> ScreensOf(string? moduleCode) =>
        string.Equals(moduleCode, "LAB", StringComparison.OrdinalIgnoreCase) ? LabScreens : OpdScreens;

    /// <summary>The page a hosting view belongs to, for the payment modal's own "offer the discount" decision.</summary>
    public static string? ScreenFor(string? controller, string? action) => (controller, action) switch
    {
        ("OPD", "PatientRegistration") => "OPD.PATIENTREGISTRATION",
        ("OPD", "ServiceBooking") => "OPD.SERVICEBOOKING",
        ("OPD", "Dashboard") => "OPD.DASHBOARD",
        ("LabOrderBooking", "B2CBooking") => "LAB.LABORDERBOOKING.B2CBOOKING",
        ("LabOrderBooking", "B2BBooking") => "LAB.LABORDERBOOKING.B2BBOOKING",
        ("LabOrderBooking", "B2COrderList") => "LAB.LABORDERBOOKING.B2CORDERLIST",
        ("LabOrderBooking", "B2BRegistration") => "LAB.LABORDERBOOKING.B2BREGISTRATION",
        _ => null
    };

    /// <summary>
    /// For /OPD/SavePayment: true unless the payment adds or raises a discount the user may not give.
    /// Collecting a due on a bill whose discount is unchanged is never blocked.
    /// </summary>
    public static async Task<bool> AllowsPaymentAsync(HttpContext http, IActionPermissionGuard guard,
        IPaymentSummaryApiClient summaries, SavePaymentRequest request)
    {
        if (!PaymentService.HasDiscount(request)) return true;

        try
        {
            var existing = await summaries.GetAsync(request.ModuleCode, request.ModuleRefId);
            if (existing is { HasExistingPayment: true }
                && request.HeaderDiscountAmount <= existing.ExistingHeaderDiscountAmount
                && (request.LineItems?.Sum(l => l.LineDiscountAmount) ?? 0) <= existing.ExistingLineDiscountTotal)
                return true;
        }
        catch (HttpRequestException) { /* summary unavailable: treat the discount as new */ }

        return await guard.AllowsAnyAsync(http, ScreensOf(request.ModuleCode), PermissionControls.Discount);
    }
}
