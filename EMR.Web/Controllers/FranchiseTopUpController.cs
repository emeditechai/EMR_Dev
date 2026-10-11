using System.Data;
using System.Globalization;
using System.Text.Json;
using ClosedXML.Excel;
using Dapper;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.DTOs;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

/// <summary>
/// Utility > Franchise Top-Up (SQLScripts/2225): dashboard and list of franchise wallet top-ups, the top-up itself, its
/// receipt and an Excel export. Only an active franchise whose Credit Facility Type is Prepaid (Wallet) can be topped
/// up (checked here and, authoritatively, in usp_B2B_FranchiseWallet_TopUp). Every action is a control of the page
/// UTILITY.FRANCHISETOPUP: VIEW, TOPUP, PRINT, EXPORT.
/// </summary>
[Authorize]
public class FranchiseTopUpController(
    IDbConnectionFactory db,
    ApplicationDbContext dbContext,
    IB2BBillingApiClient b2bBillingApiClient,
    IPaymentService paymentService,
    IAuditLogService auditLogService,
    ILogger<FranchiseTopUpController> logger) : Controller
{
    public const string PageCode = "UTILITY.FRANCHISETOPUP";
    public const string TopUpControl = "TOPUP";
    private const decimal MaxAmount = 9_999_999.99m;
    private const int PrepaidWallet = 1;

    // ── Screen ────────────────────────────────────────────────────────────────
    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> Index()
    {
        var methods = (await paymentService.GetActiveMethodsAsync()).ToList();
        return View(new FranchiseTopUpPageViewModel { PaymentMethods = methods });
    }

    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> Dashboard(string? fromDate, string? toDate, int? franchiseId, int? paymentMethodId, string? search)
    {
        if (!TryRange(fromDate, toDate, out var f, out var t, out var error))
            return Json(new { success = false, message = error });
        try
        {
            var data = await LoadAsync(f, t, franchiseId, paymentMethodId, search);
            return Json(new { success = true, data });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Franchise top-up dashboard could not be loaded");
            return Json(new { success = false, message = "Unable to load the franchise top-ups. Please try again." });
        }
    }

    /// <summary>One franchise's wallet statement (top-ups and bill deductions) for the period.</summary>
    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.View)]
    public async Task<IActionResult> Statement(int franchiseId, string? fromDate, string? toDate)
    {
        if (franchiseId <= 0) return Json(new { success = false, message = "Select a franchise." });
        if (!TryRange(fromDate, toDate, out var f, out var t, out var error))
            return Json(new { success = false, message = error });
        try
        {
            var rows = await b2bBillingApiClient.GetWalletStatementAsync(franchiseId, f, t);
            return Json(new { success = true, data = rows.OrderByDescending(r => r.CreatedDate).ThenByDescending(r => r.TransactionId) });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Wallet statement of franchise {FranchiseId} could not be loaded", franchiseId);
            return Json(new { success = false, message = "Unable to load the wallet statement. Please try again." });
        }
    }

    // ── Top-up ────────────────────────────────────────────────────────────────
    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequiresPermission(PageCode, TopUpControl)]
    public async Task<IActionResult> TopUp([FromBody] FranchiseTopUpRequest? request)
    {
        if (request is null) return Json(new { success = false, message = "Enter the top-up details." });
        var branchId = User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId");
        if (branchId is null or <= 0) return Json(new { success = false, message = "Please select a branch first." });

        var reference = (request.TransactionRef ?? string.Empty).Trim();
        var narration = (request.Narration ?? string.Empty).Trim();
        if (request.FranchiseId <= 0) return Json(new { success = false, message = "Select a franchise." });
        if (request.Amount <= 0) return Json(new { success = false, message = "Enter a top-up amount greater than zero." });
        if (request.Amount > MaxAmount) return Json(new { success = false, message = "Top-up amount cannot be more than ₹99,99,999.99 in one receipt." });
        if (decimal.Round(request.Amount, 2) != request.Amount) return Json(new { success = false, message = "Top-up amount can have at most two decimals." });
        if (request.PaymentMethodId <= 0) return Json(new { success = false, message = "Select the payment mode." });
        if (reference.Length > 100) return Json(new { success = false, message = "Reference can be at most 100 characters." });
        if (narration.Length > 500) return Json(new { success = false, message = "Remarks can be at most 500 characters." });

        // the franchise must be active and Prepaid (Wallet) - the procedure checks again inside its transaction
        using (var con = db.CreateConnection())
        {
            var fr = await con.QuerySingleOrDefaultAsync<(string Name, bool IsActive, int Facility)>(@"
                SELECT f.Franchise_Name, CAST(ISNULL(f.IsActive, 0) AS BIT), ISNULL(c.Credit_Facility_Type, 1)
                FROM dbo.LabFranchiseMaster f
                LEFT JOIN dbo.LabFranchiseCreditLimitMaster c ON c.Franchise_ID = f.Franchise_ID
                WHERE f.Franchise_ID = @Id AND ISNULL(f.IsDeleted, 0) = 0", new { Id = request.FranchiseId });
            if (fr.Name is null) return Json(new { success = false, message = "Franchise not found." });
            if (!fr.IsActive) return Json(new { success = false, message = $"{fr.Name} is inactive. Activate it in Franchise Master before a top-up." });
            if (fr.Facility != PrepaidWallet)
                return Json(new { success = false, message = $"Top-up is allowed only for a franchise whose Credit Facility Type is Prepaid (Wallet). {fr.Name} is {FacilityName(fr.Facility)}." });
        }

        try
        {
            var result = await b2bBillingApiClient.TopUpWalletAsync(new WalletTopUpDto
            {
                FranchiseId = request.FranchiseId,
                Amount = request.Amount,
                PaymentMethodId = request.PaymentMethodId,
                TransactionRef = reference.Length == 0 ? null : reference,
                BranchId = branchId.Value,
                Narration = narration.Length == 0 ? null : narration,
                ExpectedBalance = request.ExpectedBalance
            });
            if (result is not { Success: true })
                return Json(new { success = false, message = result?.Message ?? "Wallet top-up failed." });

            await auditLogService.LogActivityAsync(
                eventType: "Franchise Wallet Top-Up",
                actionName: "UTILITY.FranchiseTopUp",
                description: $"Wallet top-up of ₹{request.Amount:F2} for Franchise #{request.FranchiseId}. Receipt: {result.ReceiptNo}. New balance: ₹{result.NewBalance:F2}.",
                userId: User.GetUserId(),
                branchId: branchId,
                moduleCode: "LAB",
                referenceNo: result.ReceiptNo);
            return Json(new { success = true, receiptNo = result.ReceiptNo, newBalance = result.NewBalance });
        }
        catch (HttpRequestException ex)
        {
            // the procedure's own message (not Prepaid, duplicate reference ...) comes back as {"message": "..."}
            return Json(new { success = false, message = ApiMessage(ex.Message) ?? "Wallet top-up failed. Please try again." });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Wallet top-up of franchise {FranchiseId} failed", request.FranchiseId);
            return Json(new { success = false, message = "Wallet top-up failed. Please try again." });
        }
    }

    // ── Receipt ───────────────────────────────────────────────────────────────
    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.Print)]
    public async Task<IActionResult> Receipt(string receiptNo)
    {
        receiptNo = (receiptNo ?? string.Empty).Trim();
        if (receiptNo.Length == 0 || receiptNo.Length > 50)
            return View(new FranchiseTopUpReceiptViewModel { Message = "Receipt number is required." });

        FranchiseTopUpReceiptViewModel? vm;
        try
        {
            using var con = db.CreateConnection();
            vm = await con.QueryFirstOrDefaultAsync<FranchiseTopUpReceiptViewModel>("dbo.usp_FranchiseTopUp_Receipt",
                new { ReceiptNo = receiptNo }, commandType: CommandType.StoredProcedure);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Top-up receipt {ReceiptNo} could not be loaded", receiptNo);
            return View(new FranchiseTopUpReceiptViewModel { ReceiptNo = receiptNo, Message = "The receipt could not be loaded. Please try again." });
        }
        if (vm is null)
            return View(new FranchiseTopUpReceiptViewModel { ReceiptNo = receiptNo, Message = $"Top-up receipt {receiptNo} was not found." });

        var branchId = vm.BranchId ?? User.GetCurrentBranchId() ?? 0;
        var settings = await dbContext.HospitalSettings.Where(s => s.BranchId == branchId && s.IsActive).FirstOrDefaultAsync()
                       ?? await dbContext.HospitalSettings.FirstOrDefaultAsync(s => s.IsActive);
        vm.HospitalName       = settings?.HospitalName ?? "eMeditech Hospital";
        vm.HospitalAddress    = settings?.Address;
        vm.HospitalPhone      = settings?.ContactNumber1;
        vm.HospitalEmail      = settings?.EmailAddress;
        vm.HospitalGSTIN      = settings?.GSTCode;
        vm.HospitalLogoPath   = settings?.LogoPath;
        vm.RegistrationNumber = settings?.RegistrationNumber;
        return View(vm);
    }

    // ── Excel ─────────────────────────────────────────────────────────────────
    [HttpGet]
    [RequiresPermission(PageCode, PermissionControls.Export)]
    public async Task<IActionResult> Export(string? fromDate, string? toDate, int? franchiseId, int? paymentMethodId, string? search)
    {
        if (!TryRange(fromDate, toDate, out var f, out var t, out var error))
            return BadRequest(new { success = false, message = error });
        FranchiseTopUpDashboard data;
        try { data = await LoadAsync(f, t, franchiseId, paymentMethodId, search); }
        catch (Exception ex)
        {
            logger.LogError(ex, "Franchise top-up export failed");
            return StatusCode(StatusCodes.Status500InternalServerError, new { success = false, message = "Unable to export the franchise top-ups." });
        }

        var period = f.Date == t.Date ? f.ToString("dd MMM yyyy") : $"{f:dd MMM yyyy} – {t:dd MMM yyyy}";
        var ic = CultureInfo.GetCultureInfo("en-IN");
        using var wb = new XLWorkbook();
        var amber = XLColor.FromHtml("#0F766E");

        void Title(IXLWorksheet ws, string title, int cols)
        {
            ws.Cell(1, 1).Value = title;
            ws.Cell(1, 1).Style.Font.SetBold().Font.SetFontSize(14).Font.SetFontColor(amber);
            ws.Cell(2, 1).Value = $"Period: {period}" + (string.IsNullOrWhiteSpace(search) ? "" : $"   Search: \"{search.Trim()}\"");
            ws.Cell(3, 1).Value = $"Generated by {User.GetDisplayName()} on {DateTime.Now:dd MMM yyyy, hh:mm tt}";
            ws.Range(2, 1, 3, 1).Style.Font.SetFontColor(XLColor.FromHtml("#475569"));
            for (var r = 1; r <= 3; r++) ws.Range(r, 1, r, cols).Merge();
        }
        void Head(IXLWorksheet ws, int row, string[] heads)
        {
            for (var c = 0; c < heads.Length; c++) ws.Cell(row, c + 1).Value = heads[c];
            ws.Range(row, 1, row, heads.Length).Style.Font.SetBold().Font.SetFontColor(XLColor.White).Fill.SetBackgroundColor(amber);
        }

        // top-ups
        var ws1 = wb.Worksheets.Add("Top-ups");
        string[] h1 = ["Receipt No", "Date & Time", "Franchise Code", "Franchise", "Amount", "Payment Mode", "Reference", "Balance After", "Remarks", "Branch", "Received By"];
        Title(ws1, "Franchise Wallet Top-ups", h1.Length);
        Head(ws1, 5, h1);
        var row = 6;
        foreach (var x in data.TopUps)
        {
            ws1.Cell(row, 1).Value = x.ReceiptNo ?? "";
            ws1.Cell(row, 2).Value = x.CreatedDate; ws1.Cell(row, 2).Style.DateFormat.Format = "dd-MMM-yyyy hh:mm AM/PM";
            ws1.Cell(row, 3).Value = x.Franchise_Code ?? "";
            ws1.Cell(row, 4).Value = x.Franchise_Name ?? "";
            ws1.Cell(row, 5).Value = x.Amount;
            ws1.Cell(row, 6).Value = x.MethodName ?? "Not recorded";
            ws1.Cell(row, 7).Value = x.TransactionRef ?? "";
            ws1.Cell(row, 8).Value = x.BalanceAfter;
            ws1.Cell(row, 9).Value = x.Narration ?? "";
            ws1.Cell(row, 10).Value = x.BranchName ?? "";
            ws1.Cell(row, 11).Value = x.CreatedByName ?? "";
            row++;
        }
        ws1.Cell(row, 4).Value = $"Total ({data.TopUps.Count} top-up(s))";
        ws1.Cell(row, 5).Value = data.TopUps.Sum(x => x.Amount);
        ws1.Range(row, 1, row, h1.Length).Style.Font.SetBold().Border.SetTopBorder(XLBorderStyleValues.Medium);
        ws1.Range(6, 5, row, 5).Style.NumberFormat.Format = "#,##0.00";
        ws1.Range(6, 8, row, 8).Style.NumberFormat.Format = "#,##0.00";
        if (data.TopUps.Count > 0) ws1.Range(5, 1, row - 1, h1.Length).SetAutoFilter();
        ws1.Columns().AdjustToContents(5, row);
        ws1.SheetView.FreezeRows(5);

        // franchise wallets
        var ws2 = wb.Worksheets.Add("Franchise wallets");
        string[] h2 = ["Franchise Code", "Franchise", "Credit Facility", "Status", "Wallet Balance", "Top-ups in period", "Top-up amount", "Used in period", "Used last 30 days", "Days of cover", "Last top-up", "Last top-up amount"];
        Title(ws2, "Franchise wallets", h2.Length);
        Head(ws2, 5, h2);
        row = 6;
        foreach (var x in data.Franchises)
        {
            ws2.Cell(row, 1).Value = x.Franchise_Code ?? "";
            ws2.Cell(row, 2).Value = x.Franchise_Name ?? "";
            ws2.Cell(row, 3).Value = FacilityName(x.CreditFacilityType);
            ws2.Cell(row, 4).Value = !x.IsActive ? "Inactive" : (x.IsSuspended ? "Suspended" : "Active");
            ws2.Cell(row, 5).Value = x.WalletBalance;
            ws2.Cell(row, 6).Value = x.PeriodTopUpCount;
            ws2.Cell(row, 7).Value = x.PeriodTopUp;
            ws2.Cell(row, 8).Value = x.PeriodUsage;
            ws2.Cell(row, 9).Value = x.UsedLast30Days;
            if (x.DaysOfCover is { } dc) ws2.Cell(row, 10).Value = dc;
            if (x.LastTopUpOn is { } lt) { ws2.Cell(row, 11).Value = lt; ws2.Cell(row, 11).Style.DateFormat.Format = "dd-MMM-yyyy"; }
            if (x.LastTopUpAmount is { } la) ws2.Cell(row, 12).Value = la;
            row++;
        }
        foreach (var c in new[] { 5, 7, 8, 9, 12 }) ws2.Range(6, c, Math.Max(6, row), c).Style.NumberFormat.Format = "#,##0.00";
        ws2.Columns().AdjustToContents(5, row);
        ws2.SheetView.FreezeRows(5);

        // by payment mode
        var ws3 = wb.Worksheets.Add("By payment mode");
        Title(ws3, "Top-ups by payment mode", 3);
        Head(ws3, 5, ["Payment Mode", "Top-ups", "Amount"]);
        row = 6;
        foreach (var x in data.ByMode)
        {
            ws3.Cell(row, 1).Value = x.MethodName ?? "Not recorded";
            ws3.Cell(row, 2).Value = x.TopUpCount;
            ws3.Cell(row, 3).Value = x.Amount;
            ws3.Cell(row, 3).Style.NumberFormat.Format = "#,##0.00";
            row++;
        }
        ws3.Columns().AdjustToContents(5, row);

        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        return File(ms.ToArray(), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            $"Franchise_TopUps_{f:yyyy-MM-dd}_to_{t:yyyy-MM-dd}.xlsx");
    }

    // ── helpers ───────────────────────────────────────────────────────────────
    private async Task<FranchiseTopUpDashboard> LoadAsync(DateTime from, DateTime to, int? franchiseId, int? paymentMethodId, string? search)
    {
        using var con = db.CreateConnection();
        using var grid = await con.QueryMultipleAsync("dbo.usp_FranchiseTopUp_Dashboard", new
        {
            FromDate = from.Date,
            ToDate = to.Date,
            FranchiseId = franchiseId is > 0 ? franchiseId : null,
            PaymentMethodId = paymentMethodId is >= 0 ? paymentMethodId : null,
            Search = string.IsNullOrWhiteSpace(search) ? null : search.Trim()[..Math.Min(search.Trim().Length, 100)]
        }, commandType: CommandType.StoredProcedure);
        var data = new FranchiseTopUpDashboard
        {
            Summary = await grid.ReadFirstOrDefaultAsync<FranchiseTopUpSummary>() ?? new(),
            Franchises = (await grid.ReadAsync<FranchiseWalletRow>()).ToList(),
            TopUps = (await grid.ReadAsync<FranchiseTopUpRow>()).ToList(),
            ByMode = (await grid.ReadAsync<FranchiseTopUpModeRow>()).ToList(),
            Trend = (await grid.ReadAsync<FranchiseTopUpTrendRow>()).ToList()
        };
        foreach (var f in data.Franchises)
        {
            f.CreditFacilityName = FacilityName(f.CreditFacilityType);
            f.CanTopUp = f.IsActive && f.CreditFacilityType == PrepaidWallet;
            f.TopUpBlockReason = !f.IsActive ? "Inactive franchise"
                : f.CreditFacilityType != PrepaidWallet ? $"{f.CreditFacilityName} - top-up is only for Prepaid (Wallet)" : null;
        }
        return data;
    }

    private static string FacilityName(int type) => type switch
    {
        1 => "Prepaid (Wallet)",
        2 => "Postpaid (Credit)",
        3 => "Hybrid",
        _ => "Not set"
    };

    private static bool TryRange(string? fromDate, string? toDate, out DateTime from, out DateTime to, out string? error)
    {
        error = null;
        if (!DateTime.TryParse(fromDate, out from)) from = new DateTime(DateTime.Today.Year, DateTime.Today.Month, 1);
        if (!DateTime.TryParse(toDate, out to)) to = DateTime.Today;
        if (to < from) (from, to) = (to, from);
        if ((to - from).TotalDays > 366) { error = "Please select a date range of up to one year."; return false; }
        return true;
    }

    private static string? ApiMessage(string raw)
    {
        var i = raw.IndexOf('{');
        if (i < 0) return null;
        try
        {
            using var doc = JsonDocument.Parse(raw[i..]);
            return doc.RootElement.TryGetProperty("message", out var m) ? m.GetString() : null;
        }
        catch (JsonException) { return null; }
    }
}
