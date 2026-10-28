using EMR.Web.Data;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.EntityFrameworkCore;
using Dapper;
using EMR.Web.ApiClients;

namespace EMR.Web.Controllers;

[AllowAnonymous] // Allow anyone to access the login page
public class PatientPortalController(
    ApplicationDbContext dbContext,
    IPasswordHasherService passwordHasher,
    IPatientPortalApiClient portalApiClient,
    IHttpClientFactory httpClientFactory,
    IPatientProfileService profileService,
    ILabReportPdfService reportPdfService,
    ILabReportingApiClient labReportingApiClient,
    ILogger<PatientPortalController> logger) : Controller
{
    private static readonly HashSet<string> PortalParts = new(StringComparer.OrdinalIgnoreCase)
        { "dashboard", "dependents", "vitals", "bookings", "prescriptions" };

    // EMR.Api serves portal data only for the patient named in the call's token: tell the token handler who that is.
    public override void OnActionExecuting(ActionExecutingContext context)
    {
        var patientId = HttpContext.Session.GetInt32("PatientId") ?? HttpContext.Session.GetInt32("ChangePasswordPatientId");
        if (patientId is > 0) HttpContext.Items[EmrApiTokenHandler.PatientIdItem] = patientId.Value;
        base.OnActionExecuting(context);
    }

    // GET: /PatientPortal/Data/{part} - the dashboard's tabs, always for the signed-in patient (never an id from the page).
    [HttpGet("PatientPortal/Data/{part}")]
    public async Task<IActionResult> Data(string part)
    {
        var patientId = HttpContext.Session.GetInt32("PatientId");
        if (patientId is not > 0)
            return StatusCode(StatusCodes.Status401Unauthorized, new { success = false, message = "Your session has ended. Please sign in again." });
        if (!PortalParts.Contains(part)) return NotFound();

        try
        {
            var response = await httpClientFactory.CreateClient("EmrApi").GetAsync($"api/patientportal/{patientId}/{part.ToLowerInvariant()}");
            return new ContentResult
            {
                Content = await response.Content.ReadAsStringAsync(),
                ContentType = "application/json",
                StatusCode = (int)response.StatusCode
            };
        }
        catch (HttpRequestException)
        {
            return StatusCode(StatusCodes.Status503ServiceUnavailable, new { success = false, message = "The service is unavailable. Please try again." });
        }
    }

    // GET: /PatientPortal/Login
    [HttpGet]
    public IActionResult Login()
    {
        return View();
    }

    // POST: /PatientPortal/Login
    [HttpPost]
    [ValidateAntiForgeryToken]
    [Microsoft.AspNetCore.RateLimiting.EnableRateLimiting(AccountController.SignInRateLimit)]
    public async Task<IActionResult> Login(PatientLoginViewModel model)
    {
        if (!ModelState.IsValid)
            return View(model);

        // the Patient ID only (SQLScripts/2326): unique, so family members sharing an e-mail never open each other's records
        var patientCode = model.Username.Trim();
        var patient = await dbContext.PatientMasters
            .FirstOrDefaultAsync(p => p.PatientCode == patientCode && p.IsActive);

        if (patient == null)
        {
            ModelState.AddModelError(string.Empty, "Patient ID or password is not correct.");
            return View(model);
        }
        if (!patient.IsLoginGenerated)
        {
            ModelState.AddModelError(string.Empty, "No portal login has been created for this Patient ID yet. Please ask the hospital reception.");
            return View(model);
        }

        var con = dbContext.Database.GetDbConnection();
        var lockedUntil = await con.ExecuteScalarAsync<DateTime?>(
            "SELECT PortalLockoutUntil FROM PatientMaster WHERE PatientId = @Id AND PortalLockoutUntil > GETDATE()", new { Id = patient.PatientId });
        if (lockedUntil is not null)
        {
            ModelState.AddModelError(string.Empty, $"Too many wrong passwords. Try again after {lockedUntil:hh:mm tt}, or ask the hospital reception to reset your password.");
            return View(model);
        }

        // Use BCrypt to verify the password against the stored PasswordHash
        bool isPasswordCorrect = false;
        if (!string.IsNullOrEmpty(patient.PasswordHash))
        {
            isPasswordCorrect = passwordHasher.VerifyPassword(model.Password, patient.PasswordHash);
        }

        if (!isPasswordCorrect)
        {
            // 5 wrong passwords in a row lock the portal account for 10 minutes; a staff reset unlocks it
            var failure = await con.QuerySingleAsync<(DateTime? LockedUntil, int AttemptsLeft)>(
                "dbo.usp_PatientPortal_LoginFailure", new { PatientId = patient.PatientId }, commandType: System.Data.CommandType.StoredProcedure);
            ModelState.AddModelError(string.Empty, failure.LockedUntil is { } until
                ? $"Too many wrong passwords. Try again after {until:hh:mm tt}, or ask the hospital reception to reset your password."
                : failure.AttemptsLeft <= 2
                    ? $"Patient ID or password is not correct. {failure.AttemptsLeft} attempt(s) left before the account is locked for 10 minutes."
                    : "Patient ID or password is not correct.");
            return View(model);
        }

        await con.ExecuteAsync("dbo.usp_PatientPortal_LoginSuccess", new { PatientId = patient.PatientId },
            commandType: System.Data.CommandType.StoredProcedure);

        // Password is correct.
        // Check if it's the first login (IsPasswordchanged == false)
        if (!patient.IsPasswordchanged)
        {
            TempData["Success"] = "For your security, please change your password on your first login.";
            
            // Redirect to change password
            var changeViewModel = new PatientChangePasswordViewModel
            {
                PatientId = patient.PatientId
            };
            
            // Set session or use tempdata so we don't expose patientId openly for the change form
            HttpContext.Session.SetInt32("ChangePasswordPatientId", patient.PatientId);
            return RedirectToAction(nameof(ChangePassword));
        }

        // Authenticate the user (using session for this simple mockup)
        HttpContext.Session.SetInt32("PatientId", patient.PatientId);
        HttpContext.Session.SetString("PatientName", patient.FirstName + " " + patient.LastName);

        return RedirectToAction(nameof(Dashboard));
    }

    // GET: /PatientPortal/ChangePassword
    [HttpGet]
    public IActionResult ChangePassword()
    {
        var patientId = HttpContext.Session.GetInt32("ChangePasswordPatientId");
        if (patientId == null)
            return RedirectToAction(nameof(Login));

        var model = new PatientChangePasswordViewModel
        {
            PatientId = patientId.Value
        };

        return View(model);
    }

    // POST: /PatientPortal/ChangePassword
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ChangePassword(PatientChangePasswordViewModel model)
    {
        if (!ModelState.IsValid)
            return View(model);

        var patientId = HttpContext.Session.GetInt32("ChangePasswordPatientId");
        if (patientId == null || patientId != model.PatientId)
            return RedirectToAction(nameof(Login));

        var patient = await dbContext.PatientMasters.FirstOrDefaultAsync(p => p.PatientId == patientId);
        if (patient == null)
            return RedirectToAction(nameof(Login));

        // the password that was sent must be replaced, not kept
        if (!string.IsNullOrEmpty(patient.PasswordHash) && passwordHasher.VerifyPassword(model.NewPassword, patient.PasswordHash))
        {
            ModelState.AddModelError(nameof(model.NewPassword), "Choose a password different from the one you were sent.");
            return View(model);
        }

        // Hash the new password
        var (Hash, Salt) = passwordHasher.HashPassword(model.NewPassword);

        // Update DB: IsPasswordchanged = 1, Lastlogin = getdate(), new hash & salt
        await dbContext.Database.GetDbConnection().ExecuteAsync(
            @"UPDATE PatientMaster 
              SET PasswordHash = @Hash, 
                  Salt = @Salt, 
                  IsPasswordchanged = 1, 
                  Lastlogin = @Now 
              WHERE PatientId = @Id",
            new { Hash, Salt, Now = DateTime.Now, Id = patientId }
        );

        TempData["Success"] = "Password changed successfully! You are now logged in.";
        
        // Log them in
        HttpContext.Session.Remove("ChangePasswordPatientId");
        HttpContext.Session.SetInt32("PatientId", patient.PatientId);
        HttpContext.Session.SetString("PatientName", patient.FirstName + " " + patient.LastName);

        return RedirectToAction(nameof(Dashboard));
    }

    // GET: /PatientPortal/Dashboard
    [HttpGet]
    public async Task<IActionResult> Dashboard()
    {
        var patientId = HttpContext.Session.GetInt32("PatientId");
        if (patientId == null)
            return RedirectToAction(nameof(Login));

        // the same profile staff see on Master > Patient Master > View (Services/PatientProfileService)
        var model = await profileService.BuildAsync(patientId.Value);
        if (model == null || !model.Patient.IsActive)
            return RedirectToAction(nameof(Login));

        ViewData["HospitalName"] = await dbContext.HospitalSettings
            .Where(h => h.BranchId == model.Patient.BranchId && h.IsActive).Select(h => h.HospitalName).FirstOrDefaultAsync();
        return View(model);
    }

    // ── The signed-in patient's own documents: every link checks the bill belongs to the patient in the session ──

    // GET: /PatientPortal/Chart/vitals | visits - the dashboard graphs
    [HttpGet("PatientPortal/Chart/{kind}")]
    public async Task<IActionResult> Chart(string kind)
    {
        var patientId = HttpContext.Session.GetInt32("PatientId");
        if (patientId is not > 0) return Unauthorized();
        return kind.ToLowerInvariant() switch
        {
            "vitals" => Json(await profileService.VitalsChartAsync(patientId.Value)),
            "visits" => Json(await profileService.VisitsChartAsync(patientId.Value)),
            _ => NotFound()
        };
    }

    // GET: /PatientPortal/OpdBill/5 - an OPD bill of the patient
    [HttpGet]
    public async Task<IActionResult> OpdBill(int id)
    {
        if (!await OwnsAsync("SELECT COUNT(1) FROM PatientOPDService WHERE OPDServiceId = @Id AND PatientId = @P AND IsActive = 1", id))
            return NotFound();
        var secret = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes($"bill-{id}-emr"));
        return Redirect($"/OPD/PrintBillAnonymous?id={id}&secret={Uri.EscapeDataString(secret)}");
    }

    // GET: /PatientPortal/LabBill/5 - a LAB bill of the patient
    [HttpGet]
    public async Task<IActionResult> LabBill(int id)
    {
        if (!await OwnsAsync("SELECT COUNT(1) FROM LabOrder WHERE LabOrderId = @Id AND PatientId = @P AND IsActive = 1", id))
            return NotFound();
        var secret = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes($"bill-{id}-emr"));
        return Redirect($"/LabOrderBooking/PrintBillAnonymous?labOrderId={id}&secret={Uri.EscapeDataString(secret)}");
    }

    // GET: /PatientPortal/Prescription?opdServiceId=5&doctorId=2 - a prescription of the patient's visit
    [HttpGet]
    public async Task<IActionResult> Prescription(int opdServiceId, int doctorId)
    {
        if (!await OwnsAsync("SELECT COUNT(1) FROM PatientOPDService WHERE OPDServiceId = @Id AND PatientId = @P AND IsActive = 1", opdServiceId))
            return NotFound();
        var secret = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes($"prescription-{opdServiceId}-{doctorId}-emr"));
        return Redirect($"/OPD/PrintPrescriptionAnonymous?opdServiceId={opdServiceId}&doctorId={doctorId}&secret={Uri.EscapeDataString(secret)}");
    }

    // GET: /PatientPortal/Report/5 - the approved LAB report of the patient's bill (as the e-mailed copy: paid bills only)
    [HttpGet]
    public async Task<IActionResult> Report(int id, string? type = null)
    {
        var patientId = HttpContext.Session.GetInt32("PatientId");
        if (patientId is not > 0) return RedirectToAction(nameof(Login));
        if (!await OwnsAsync("SELECT COUNT(1) FROM LabOrder WHERE LabOrderId = @Id AND PatientId = @P AND IsActive = 1", id))
            return NotFound();

        try
        {
            var detail = await labReportingApiClient.GetDetailAsync(id);
            if (detail == null) return Content("The report is not available yet.");
            if (detail.BalanceDue > 0)
                return Content($"Your report will be available once the bill is paid (due Rs. {detail.BalanceDue:N2}).");

            var patient = await dbContext.PatientMasters.Where(p => p.PatientId == patientId).Select(p => new { p.CompanyId }).FirstOrDefaultAsync();
            var user = new System.Security.Claims.ClaimsPrincipal(new System.Security.Claims.ClaimsIdentity(new[]
            {
                new System.Security.Claims.Claim("DisplayName", "Patient Portal"),
                new System.Security.Claims.Claim("CompanyId", (patient?.CompanyId ?? 1).ToString())
            }, "PatientPortal"));

            // the Lab Report, or the Microbiology Report when the bill has only that (type picks one)
            var types = type is LabReportTypes.Numeric or LabReportTypes.Template
                ? new[] { type } : new[] { LabReportTypes.Numeric, LabReportTypes.Template };
            foreach (var t in types)
            {
                var rvm = await reportPdfService.BuildAsync(id, user, LabReportPrintBuilder.ScopeApproved, t);
                if (rvm == null || rvm.IncludedTestCount == 0) continue;
                rvm.ShowLetterhead = rvm.FranchiseHeaderRequired ?? true;
                rvm.PrintSequence = 1;
                var pdf = LabReportPdfDocument.Generate(rvm, reportPdfService.LoadLogo(rvm.HospitalLogoPath));
                var name = (detail.BillNo ?? $"Report-{id}").Replace('/', '-');
                return File(pdf, "application/pdf", $"{name}{(t == LabReportTypes.Template ? "-Micro" : "")}.pdf");
            }
            return Content("No test of this bill has been approved yet. Please check again later.");
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "[PORTAL] Report of LAB order {LabOrderId} for patient {PatientId} failed", id, patientId);
            return Content("The report could not be prepared right now. Please try again.");
        }
    }

    // GET: /PatientPortal/LabWorkflow?ids=5,6 - the live stage of the patient's LAB bills: the same workflow staff see in
    // the Audit History (LabReportingController.BuildOrderWorkflowAsync), without staff names; polled by the dashboard
    [HttpGet]
    public async Task<IActionResult> LabWorkflow(string? ids)
    {
        var patientId = HttpContext.Session.GetInt32("PatientId");
        if (patientId is not > 0) return Unauthorized();
        var wanted = (ids ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries)
            .Select(x => int.TryParse(x, out var v) ? v : 0).Where(v => v > 0).Distinct().Take(50).ToList();
        if (wanted.Count == 0) return Json(Array.Empty<object>());

        var con = dbContext.Database.GetDbConnection();
        var own = (await con.QueryAsync<int>("SELECT LabOrderId FROM LabOrder WHERE PatientId = @P AND LabOrderId IN @Ids",
            new { P = patientId.Value, Ids = wanted })).ToHashSet();

        var result = new List<object>();
        foreach (var id in wanted.Where(own.Contains))
        {
            var wf = System.Text.Json.JsonSerializer.SerializeToElement(await LabReportingController.BuildOrderWorkflowAsync(con, id));
            if (!wf.TryGetProperty("success", out var ok) || !ok.GetBoolean()) continue;
            var steps = wf.GetProperty("steps").EnumerateArray().Select(st => new
            {
                key = st.GetProperty("key").GetString(),
                label = st.GetProperty("label").GetString(),
                state = st.GetProperty("state").GetString(),
                detail = st.GetProperty("detail").GetString(),
                at = st.TryGetProperty("at", out var at) && at.ValueKind == System.Text.Json.JsonValueKind.String ? at.GetString() : null
            }).ToList();
            result.Add(new { id, cancelled = wf.GetProperty("cancelled").GetBoolean(), steps });
        }
        return Json(result);
    }

    private async Task<bool> OwnsAsync(string sql, int id)
    {
        var patientId = HttpContext.Session.GetInt32("PatientId");
        if (patientId is not > 0) return false;
        return await dbContext.Database.GetDbConnection().ExecuteScalarAsync<int>(sql, new { Id = id, P = patientId.Value }) > 0;
    }

    // POST: /PatientPortal/Logout
    [HttpPost]
    [ValidateAntiForgeryToken]
    public IActionResult Logout()
    {
        HttpContext.Session.Remove("PatientId");
        HttpContext.Session.Remove("PatientName");
        HttpContext.Session.Remove("ChangePasswordPatientId");
        
        return RedirectToAction(nameof(Login));
    }
}
