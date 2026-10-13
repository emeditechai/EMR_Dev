using EMR.Shared.Security;
using EMR.Web.Services;
using EMR.Web.Services.Notifications;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// OPD > OPD Day Closing and OPD Day Closing Verification (SQLScripts/2275) - see DayClosingControllerBase.
/// OPD.DAYCLOSING:       VIEW, CREATE (submit a closing), PRINT (hand-over slip).
/// OPD.DAYCLOSINGVERIFY: VIEW, VERIFY (verify / send back; checked again in the procedure from the role / user permissions).
/// </summary>
public class OpdDayClosingController(IDayClosingService closings, INotificationService notifications, IAuditLogService audit,
    ILogger<OpdDayClosingController> logger) : DayClosingControllerBase(closings, notifications, audit, logger)
{
    public const string Page = "OPD.DAYCLOSING";
    public const string VerifyPage = "OPD.DAYCLOSINGVERIFY";
    public const string VerifyControl = "VERIFY";
    protected override string Module => "OPD";

    [HttpGet, RequiresPermission(Page, PermissionControls.View)]
    public IActionResult Index() => IndexView();

    [HttpGet, RequiresPermission(Page, PermissionControls.View)]
    public Task<IActionResult> Summary(DateTime? date, int? id, bool includePetty = true) => SummaryCore(date, id, includePetty);

    [HttpGet, RequiresPermission(Page, PermissionControls.View)]
    public Task<IActionResult> Receivers() => ReceiversCore();

    [HttpPost, ValidateAntiForgeryToken, RequiresPermission(Page, PermissionControls.Create)]
    public Task<IActionResult> Submit([FromForm] DayClosingSubmitForm form) => SubmitCore(form);

    [HttpGet, RequiresPermission(Page, PermissionControls.Print)]
    public Task<IActionResult> Slip(int id) => SlipCore(id, own: true);

    [HttpGet, RequiresPermission(VerifyPage, PermissionControls.View)]
    public IActionResult Verify() => VerifyView();

    [HttpGet, RequiresPermission(VerifyPage, PermissionControls.View)]
    public Task<IActionResult> Board(DateTime? date) => BoardCore(date);

    [HttpGet, RequiresPermission(VerifyPage, PermissionControls.View)]
    public Task<IActionResult> Detail(int id) => DetailCore(id);

    [HttpGet, RequiresPermission(VerifyPage, PermissionControls.View)]
    public Task<IActionResult> VerifySlip(int id) => SlipCore(id, own: false);

    [HttpPost, ValidateAntiForgeryToken, RequiresPermission(VerifyPage, VerifyControl)]
    public Task<IActionResult> VerifyAction(int id, string action, string? remarks) => VerifyActionCore(id, action, remarks);
}
