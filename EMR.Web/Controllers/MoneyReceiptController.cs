using System.Data;
using Dapper;
using EMR.Shared.Security;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

/// <summary>
/// Money Receipt (A5) for a payment collected against an OPD / LAB bill that was saved with a balance due
/// (SQLScripts/2204). Offered by the payment modal after a due collection; the first payment at billing keeps its
/// bill print and a B2B settlement keeps LabOrderBooking/PrintSettlementReceipt. Allowed by the VIEW of any page that
/// collects a due; the receipt must belong to the login branch unless Super Admin.
/// </summary>
[Authorize]
public class MoneyReceiptController(
    IDbConnectionFactory db,
    ApplicationDbContext dbContext,
    ILogger<MoneyReceiptController> logger) : Controller
{
    [HttpGet]
    [RequiresPermission("OPD.DASHBOARD", "VIEW")]
    [RequiresPermission("OPD.SERVICEBOOKING", "VIEW")]
    [RequiresPermission("OPD.PATIENTREGISTRATION", "VIEW")]
    [RequiresPermission("LAB.LABORDERBOOKING.B2CORDERLIST", "VIEW")]
    [RequiresPermission("LAB.LABORDERBOOKING.B2CBOOKING", "VIEW")]
    [RequiresPermission("LAB.LABORDERBOOKING.B2BBOOKING", "VIEW")]
    [RequiresPermission("LAB.LABORDERBOOKING.B2BREGISTRATION", "VIEW")]
    public async Task<IActionResult> Print(string receiptNo)
    {
        receiptNo = (receiptNo ?? string.Empty).Trim();
        if (receiptNo.Length == 0 || receiptNo.Length > 50)
            return View(new MoneyReceiptViewModel { Message = "Receipt number is required." });

        int? branchId = User.IsSuperAdmin() ? null : (User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId"));
        if (branchId == null && !User.IsSuperAdmin())
            return View(new MoneyReceiptViewModel { ReceiptNo = receiptNo, Message = "Please select a branch first." });

        MoneyReceiptViewModel? vm;
        List<MoneyReceiptLine> lines;
        bool isDue, branchAllowed;
        int receiptBranchId;
        try
        {
            using var con = db.CreateConnection();
            using var grid = await con.QueryMultipleAsync("dbo.usp_MoneyReceipt_Get",
                new { ReceiptNo = receiptNo, BranchId = branchId }, commandType: CommandType.StoredProcedure);
            var head = await grid.ReadFirstOrDefaultAsync();
            if (head == null || head.ReceiptNo == null)
                return View(new MoneyReceiptViewModel { ReceiptNo = receiptNo, Message = $"Receipt {receiptNo} was not found." });
            lines = (await grid.ReadAsync<MoneyReceiptLine>()).ToList();

            isDue          = (bool)head.IsDueCollection;
            branchAllowed  = (bool)head.BranchAllowed;
            receiptBranchId = (int)(head.BranchId ?? 0);
            vm = new MoneyReceiptViewModel
            {
                ReceiptNo      = (string)head.ReceiptNo,
                ReceiptOn      = (DateTime)head.ReceiptOn,
                ModuleCode     = (string?)head.ModuleCode ?? string.Empty,
                BranchName     = (string?)head.BranchName,
                BillNo         = (string?)head.BillNo,
                BillDate       = (DateTime?)head.BillDate,
                TokenNo        = (string?)head.TokenNo,
                PatientCode    = (string?)head.PatientCode,
                PatientName    = (string?)head.PatientName,
                PatientPhone   = (string?)head.PatientPhone,
                NetAmount      = (decimal)head.NetAmount,
                PaidBefore     = (decimal)head.PaidBefore,
                Amount         = (decimal)head.Amount,
                BalanceAfter   = (decimal)head.BalanceAfter,
                ReceivedByName = (string?)head.ReceivedByName,
                Lines          = lines
            };
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Money receipt {ReceiptNo} could not be loaded", receiptNo);
            return View(new MoneyReceiptViewModel { ReceiptNo = receiptNo, Message = "The receipt could not be loaded. Please try again." });
        }

        if (!branchAllowed)
            return View(new MoneyReceiptViewModel { ReceiptNo = receiptNo, Message = $"Receipt {receiptNo} belongs to another branch." });
        if (!isDue)
            return View(new MoneyReceiptViewModel { ReceiptNo = receiptNo,
                Message = $"Receipt {receiptNo} is not a due collection. A Money Receipt is printed only for a payment collected against a bill's balance due; print the bill instead." });

        var settings = await dbContext.HospitalSettings.Where(s => s.BranchId == receiptBranchId && s.IsActive).FirstOrDefaultAsync()
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
}
