using System.Security.Claims;
using Dapper;
using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using EMR.Web.Services.Geography;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class OPDController(
    IPatientService patientService,
    IPatientApiClient patientApiClient,
    IServiceBookingApiClient serviceBookingApiClient,
    IPaymentSummaryApiClient paymentSummaryApiClient,
    IDoctorConsultingFeeService consultingFeeService,
    ICountryService countryService,
    IStateService stateService,
    IDistrictService districtService,
    ICityService cityService,
    IAreaService areaService,
    IAuditLogService auditLogService,
    IPaymentService paymentService,
    IDoctorScheduleApiClient scheduleApiClient,
    IDoctorSpecialityService specialityService,
    IRoomDoctorAssignmentService roomDoctorAssignmentService,
    ApplicationDbContext dbContext,
    IWebHostEnvironment env,
    IDoctorApiClient doctorApiClient,
    IEmrConsultationApiClient emrConsultationApiClient,
    IVitalApiClient vitalApiClient,
    IDbConnectionFactory db) : Controller
{
    // ─── OPD Dashboard ──────────────────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> Dashboard(string? date)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null)
        {
            TempData["Error"] = "Please select a branch first.";
            return RedirectToAction("SelectBranch", "Account");
        }

        var selectedDate = DateTime.TryParse(date, out var d) ? d : DateTime.Today;
        var dateStr = selectedDate.ToString("yyyy-MM-dd");

        var hospitalSettings = await dbContext.HospitalSettings
            .Where(x => x.BranchId == branchId.Value)
            .Select(x => new { x.HospitalName, x.LogoPath })
            .FirstOrDefaultAsync();

        var currentBranchName = User.FindFirstValue("BranchName") ?? "N/A";

        var opdData = await patientApiClient.GetOpdDashboardAsync(branchId.Value, dateStr) ?? new EMR.Web.ApiClients.Models.OpdDashboardData();

        var model = new OpdDashboardViewModel
        {
            UserDisplayName = User.FindFirstValue("DisplayName") ?? User.Identity?.Name ?? "User",
            CurrentBranchName = currentBranchName,
            CurrentHospitalName = string.IsNullOrWhiteSpace(hospitalSettings?.HospitalName)
                ? currentBranchName
                : hospitalSettings.HospitalName!,
            HospitalLogoPath = hospitalSettings?.LogoPath,
            SelectedDate = dateStr,
            Data = opdData
        };

        ViewData["Title"] = "OPD Dashboard";
        return View(model);
    }

    [HttpGet]
    public async Task<IActionResult> DoctorDashboard()
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId == null)
        {
            TempData["Error"] = "Please select a branch first.";
            return RedirectToAction("SelectBranch", "Account");
        }

        var userId = User.GetUserId();
        var userEmail = User.FindFirstValue(ClaimTypes.Email);
        var displayName = User.FindFirstValue("DisplayName");
        var isDoctorRole = string.Equals(User.GetActiveRole(), "Doctor", StringComparison.OrdinalIgnoreCase) || User.IsInRole("Doctor");

        dynamic? linkedDoctor = null;
        if (!string.IsNullOrEmpty(userEmail) || !string.IsNullOrEmpty(displayName))
        {
            linkedDoctor = await doctorApiClient.GetLinkedDoctorAsync(userId, userEmail, displayName);
        }

        if (isDoctorRole && linkedDoctor != null)
        {
            ViewBag.IsDoctor = true;
            ViewBag.DoctorName = (string)linkedDoctor!.FullName;
            ViewBag.DefaultDoctorId = (int)linkedDoctor!.DoctorId;

            ViewBag.Doctors = new List<(int DoctorId, string FullName, int? PrimarySpecialityId, string Gender)>
            {
                ((int)linkedDoctor!.DoctorId, (string)linkedDoctor!.FullName, (int?)linkedDoctor!.PrimarySpecialityId, (string)linkedDoctor!.Gender)
            };
        }
        else
        {
            ViewBag.IsDoctor = false;
            var doctors = await patientService.GetOpdDoctorsAsync(branchId.Value);
            ViewBag.Doctors = doctors;

            // Find the logged-in doctor mapping if email matches
            var defaultDoctorId = 0;
            if (!string.IsNullOrEmpty(userEmail))
            {
                var apiDoctors = await doctorApiClient.GetListAsync(branchId.Value);
                var doc = apiDoctors.Items.FirstOrDefault(d => string.Equals(d.EmailId, userEmail, StringComparison.OrdinalIgnoreCase) && d.IsActive);
                if (doc != null)
                {
                    defaultDoctorId = doc.DoctorId;
                }
            }
            ViewBag.DefaultDoctorId = defaultDoctorId;
        }

        // Doctor → Room mapping  (DoctorName -> "RoomName (FloorName)")
        var roomAssignments = await roomDoctorAssignmentService.GetRoomAssignmentsAsync(branchId.Value);
        var doctorRoomMap = new Dictionary<string, string>();
        foreach (var room in roomAssignments)
        {
            foreach (var doc in room.Doctors)
            {
                doctorRoomMap[doc.FullName] = $"{room.RoomName} ({room.FloorName})";
            }
        }
        ViewBag.DoctorRoomMap = doctorRoomMap;

        ViewData["Title"] = "Doctor Dashboard";
        return View();
    }

    [HttpGet]
    public async Task<IActionResult> GetDoctorConsultingQueue(int doctorId)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId == null)
        {
            return Json(new { isSuccess = false, message = "Please select a branch first." });
        }

        // Enforce doctor data isolation: override doctorId if active role is Doctor and linked DoctorMaster exists
        var isDoctorRole = string.Equals(User.GetActiveRole(), "Doctor", StringComparison.OrdinalIgnoreCase) || User.IsInRole("Doctor");
        if (isDoctorRole)
        {
            var userId = User.GetUserId();
            var userEmail = User.FindFirstValue(ClaimTypes.Email);
            var displayName = User.FindFirstValue("DisplayName");

            using (var conn = db.CreateConnection())
            {
                var linkedDoctor = await conn.QueryFirstOrDefaultAsync<dynamic>(
                    "SELECT DoctorId FROM DoctorMaster WHERE LinkedUserId = @userId AND IsActive = 1",
                    new { userId });

                if (linkedDoctor == null && !string.IsNullOrEmpty(userEmail))
                {
                    linkedDoctor = await conn.QueryFirstOrDefaultAsync<dynamic>(
                        "SELECT DoctorId FROM DoctorMaster WHERE EmailId = @userEmail AND IsActive = 1",
                        new { userEmail });
                    if (linkedDoctor != null)
                    {
                        await conn.ExecuteAsync(
                            "UPDATE DoctorMaster SET LinkedUserId = @userId WHERE DoctorId = @doctorId",
                            new { userId, doctorId = (int)linkedDoctor.DoctorId });
                    }
                }

                if (linkedDoctor == null && !string.IsNullOrEmpty(displayName))
                {
                    linkedDoctor = await conn.QueryFirstOrDefaultAsync<dynamic>(
                        "SELECT DoctorId FROM DoctorMaster WHERE FullName = @displayName AND IsActive = 1",
                        new { displayName });
                    if (linkedDoctor != null)
                    {
                        await conn.ExecuteAsync(
                            "UPDATE DoctorMaster SET LinkedUserId = @userId WHERE DoctorId = @doctorId",
                            new { userId, doctorId = (int)linkedDoctor.DoctorId });
                    }
                }

                if (linkedDoctor != null)
                {
                    doctorId = (int)linkedDoctor.DoctorId;
                }
            }
        }

        var today = DateOnly.FromDateTime(DateTime.Today);
        var result = await serviceBookingApiClient.GetDoctorQueueAsync(branchId.Value, doctorId > 0 ? doctorId : null, today);

        if (result == null)
        {
            return Json(new { isSuccess = false, message = "Failed to load queue from API." });
        }

        return Json(new { 
            isSuccess = true, 
            data = result.Data,
            totalWaiting = result.TotalWaiting,
            totalCompleted = result.TotalCompleted
        });
    }

    // ─── Index (patient list – server-side paged via EMR.Api) ────────────────────

    public async Task<IActionResult> Index(int page = 1, int pageSize = 10, string? search = null)
    {
        var branchId = User.GetCurrentBranchId();
        if (page < 1) page = 1;
        if (pageSize is < 5 or > 100) pageSize = 10;

        try
        {
            // Strictly via EMR.Api — no DB fallback
            var apiResult = await patientApiClient.GetByBranchAsync(branchId, page, pageSize, search?.Trim());

            var paged = new PatientPagedListViewModel
            {
                Items = apiResult.Items.Select(p => new PatientListItemViewModel
                {
                    PatientId            = p.PatientId,
                    PatientCode          = p.PatientCode,
                    FullName             = p.FullName,
                    PhoneNumber          = p.PhoneNumber ?? string.Empty,
                    Gender               = p.Gender,
                    BloodGroup           = p.BloodGroup,
                    DateOfBirth          = p.DateOfBirth,
                    CreatedDate          = p.CreatedDate,
                    IsActive             = p.IsActive,
                    ConsultingDoctorName = p.ConsultingDoctorName,
                    TotalCount           = apiResult.TotalCount
                }).ToList(),
                TotalCount = apiResult.TotalCount,
                Page       = page,
                PageSize   = pageSize,
                Search     = search?.Trim()
            };

            ViewData["Title"] = "Patient List";
            return View(paged);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "OPD Patient List";
            return View("ApiDown");
        }
    }

    // ─── Patient Registration (GET) ───────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> PatientRegistration(int? id, int? doctorId = null, string? date = null, int? scheduleId = null, string? time = null)
    {
        ViewData["Title"] = id.HasValue ? "Edit Patient" : "Patient Registration";
        PatientRegistrationViewModel model;

        if (id.HasValue)
        {
            var patient = await patientService.GetByIdAsync(id.Value);
            if (patient is null) return NotFound();
            model = MapPatientToViewModel(patient);
            // Direct-edit via list: demographics only — no OPD bill data loaded
            model.DemographicsOnly = true;
        }
        else
        {
            model = new PatientRegistrationViewModel
            {
                RelationId = 1,   // default: Self
                ConsultingDoctorId = doctorId,
                AppointmentDate = DateTime.TryParse(date, out var d) ? d : DateTime.Today,
                ScheduleId = scheduleId,
                AppointmentTime = TimeSpan.TryParse(time, out var t) ? t : null
            };
        }

        // Pass bill/token info for success modal after redirect
        model.OPDBillNo       = TempData["OPDBillNo"]       as string;
        model.TokenNo         = TempData["TokenNo"]         as string;
        model.TokenPending    = TempData["TokenPending"] is bool tp && tp;
        model.NewOPDServiceId = int.TryParse(TempData["NewOPDServiceId"] as string, out var sid) ? sid : null;

        await PopulateSelectLists(model);
        return View(model);
    }

    // ─── Patient Registration (POST – Create / Update) ────────────────────────

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> PatientRegistration(PatientRegistrationViewModel model, IFormFile? identificationFile, IFormFile? profilePictureFile)
    {
        Console.WriteLine($"[DEBUG] PatientRegistration POST: model.PatientId={model.PatientId}, model.PhoneNumber={model.PhoneNumber}, model.RelationId={model.RelationId}");
        var branchId = User.GetCurrentBranchId();
        if (branchId is null)
        {
            TempData["Error"] = "Please select a branch first.";
            return RedirectToAction("SelectBranch", "Account");
        }

        if (!model.DemographicsOnly)
        {
            List<OPDServiceLineItem>? lineItems = null;
            try
            {
                var serializeOptions = new System.Text.Json.JsonSerializerOptions
                {
                    PropertyNameCaseInsensitive = true
                };
                lineItems = string.IsNullOrWhiteSpace(model.LineItemsJson)
                    ? null
                    : System.Text.Json.JsonSerializer.Deserialize<List<OPDServiceLineItem>>(model.LineItemsJson, serializeOptions);
            }
            catch { }

            if (lineItems == null || !lineItems.Any())
            {
                ModelState.AddModelError(nameof(model.LineItemsJson), "At least one service or consultation fee item is required.");
            }
            else if (lineItems.Any(item => string.IsNullOrEmpty(item.ServiceType) || !item.ServiceId.HasValue || item.ServiceId <= 0))
            {
                ModelState.AddModelError(nameof(model.LineItemsJson), "Please select a Type and Item/Service Name for all rows.");
            }
        }

        if (!ModelState.IsValid)
        {
            await PopulateSelectLists(model);
            return View(model);
        }

        // Handle file upload
        if (identificationFile is { Length: > 0 })
        {
            var allowed = new[] { ".pdf", ".jpg", ".jpeg", ".png" };
            var ext = Path.GetExtension(identificationFile.FileName).ToLowerInvariant();
            if (!allowed.Contains(ext))
            {
                ModelState.AddModelError("IdentificationFilePath", "Only PDF, JPG, JPEG and PNG files are allowed.");
                await PopulateSelectLists(model);
                return View(model);
            }

            var uploadsDir = Path.Combine(env.WebRootPath, "uploads", "patients");
            Directory.CreateDirectory(uploadsDir);
            var fileName = $"{Guid.NewGuid()}{ext}";
            var fullPath = Path.Combine(uploadsDir, fileName);
            await using (var stream = new FileStream(fullPath, FileMode.Create))
            {
                await identificationFile.CopyToAsync(stream);
            }
            model.IdentificationFilePath = $"/uploads/patients/{fileName}";
        }

        // Handle profile picture upload
        if (profilePictureFile is { Length: > 0 })
        {
            var allowed = new[] { ".jpg", ".jpeg", ".png", ".gif" };
            var ext = Path.GetExtension(profilePictureFile.FileName).ToLowerInvariant();
            if (!allowed.Contains(ext))
            {
                ModelState.AddModelError("PhotoPath", "Only JPG, JPEG, PNG and GIF files are allowed for Profile Picture.");
                await PopulateSelectLists(model);
                return View(model);
            }

            var uploadsDir = Path.Combine(env.WebRootPath, "uploads", "patients");
            Directory.CreateDirectory(uploadsDir);
            var fileName = $"{Guid.NewGuid()}{ext}";
            var fullPath = Path.Combine(uploadsDir, fileName);
            await using (var stream = new FileStream(fullPath, FileMode.Create))
            {
                await profilePictureFile.CopyToAsync(stream);
            }
            model.PhotoPath = $"/uploads/patients/{fileName}";
        }

        // ── Uniqueness: Phone Number + Relation must be unique per active patient ──
        if (model.RelationId.HasValue)
        {
            var dupExists = await dbContext.PatientMasters.AnyAsync(p =>
                p.PhoneNumber == model.PhoneNumber.Trim() &&
                p.RelationId  == model.RelationId &&
                p.IsActive    &&
                (model.PatientId == 0 || p.PatientId != model.PatientId));

            if (dupExists)
            {
                var relName = await dbContext.RelationMasters
                    .Where(r => r.RelationId == model.RelationId)
                    .Select(r => r.RelationName)
                    .FirstOrDefaultAsync() ?? "selected relation";
                ModelState.AddModelError("RelationId",
                    $"A patient with relation \"{relName}\" is already registered for phone {model.PhoneNumber}.");
                await PopulateSelectLists(model);
                return View(model);
            }
        }

        // ── Uniqueness: Email ID + Relation must be unique per active patient ──
        if (!string.IsNullOrWhiteSpace(model.EmailId) && model.RelationId.HasValue)
        {
            var dupEmailExists = await dbContext.PatientMasters.AnyAsync(p =>
                p.EmailId == model.EmailId.Trim() &&
                p.RelationId == model.RelationId &&
                p.IsActive &&
                p.PatientId != model.PatientId);

            if (dupEmailExists)
            {
                var relName = await dbContext.RelationMasters
                    .Where(r => r.RelationId == model.RelationId)
                    .Select(r => r.RelationName)
                    .FirstOrDefaultAsync() ?? "selected relation";
                ModelState.AddModelError("EmailId", $"A patient with relation \"{relName}\" is already registered with Email {model.EmailId}.");
                await PopulateSelectLists(model);
                return View(model);
            }
        }

        var patient = MapViewModelToPatient(model);
        patient.BranchId = branchId;

        if (model.PatientId == 0)   // CREATE — new patient + first OPD visit
        {
            var opdBill = MapViewModelToOPDBill(model);
            opdBill.BranchId = branchId;
            var (patientCode, billNo, tokenNo, newPatientId, newSvcId) = await patientService.CreateAsync(
                patient, opdBill, model.LineItemsJson, User.GetUserId());
            await auditLogService.LogAsync("OPD", "Patient.Create",
                $"Registered patient: {patient.FirstName} {patient.LastName} ({patientCode}) Bill:{billNo}");

            TriggerBookingEmail(branchId, newSvcId, $"{Request.Scheme}://{Request.Host}");

            // ── Trigger Patient Login Generation ──
            await TryGeneratePatientLoginAsync(newPatientId, patientCode, patient.PhoneNumber, patient.EmailId, patient.FirstName + " " + patient.LastName, branchId.Value);

            TempData["NewPatientCode"]  = patientCode;
            TempData["NewPatientName"]  = ((patient.Salutation ?? "") + " " + patient.FirstName + " " + patient.LastName).Trim();
            TempData["OPDBillNo"]       = billNo;
            TempData["TokenNo"]         = tokenNo;                          // null unless ₹0 bill
            TempData["TokenPending"]    = string.IsNullOrEmpty(tokenNo);    // true = needs payment
            TempData["NewOPDServiceId"] = newSvcId.ToString();
            return RedirectToAction(nameof(PatientRegistration), new { registered = true });
        }
        else   // UPDATE — existing patient
        {
            var existing = await patientService.GetByIdAsync(model.PatientId);
            if (string.IsNullOrWhiteSpace(model.IdentificationFilePath))
            {
                patient.IdentificationFilePath = existing?.IdentificationFilePath;
            }
            if (string.IsNullOrWhiteSpace(model.PhotoPath))
            {
                patient.PhotoPath = existing?.PhotoPath;
            }

            if (model.DemographicsOnly)
            {
                // Edit via Patient List — update demographics only, no OPD bill touched
                await patientService.UpdateDemographicsAsync(patient, User.GetUserId());
                await auditLogService.LogAsync("OPD", "Patient.UpdateDemographics",
                    $"Updated demographics: {patient.PatientId} - {patient.FirstName} {patient.LastName}");
                TempData["Success"] = $"Patient {patient.PatientCode} updated successfully.";
                
                // ── Trigger Patient Login Generation ──
                await TryGeneratePatientLoginAsync(patient.PatientId, patient.PatientCode, patient.PhoneNumber, patient.EmailId, patient.FirstName + " " + patient.LastName, branchId.Value);
                
                return RedirectToAction(nameof(Index));
            }

            // Search-loaded patient (new visit booking)
            var opdBill = MapViewModelToOPDBill(model);
            opdBill.BranchId  = branchId;
            opdBill.PatientId = model.PatientId;
            var (billNo, tokenNo, newSvcId) = await patientService.UpdateAsync(
                patient, opdBill, model.LineItemsJson, User.GetUserId());

            var action = model.OPDServiceId == 0 ? "Patient.NewVisit" : "Patient.Update";
            await auditLogService.LogAsync("OPD", action,
                $"{(model.OPDServiceId == 0 ? "New visit" : "Updated")} patient: {patient.PatientId} Bill:{billNo}");

            if (model.OPDServiceId == 0)   // new visit for returning patient
            {
                TriggerBookingEmail(branchId, newSvcId, $"{Request.Scheme}://{Request.Host}");

                // ── Trigger Patient Login Generation ──
                await TryGeneratePatientLoginAsync(patient.PatientId, patient.PatientCode, patient.PhoneNumber, patient.EmailId, patient.FirstName + " " + patient.LastName, branchId.Value);

                TempData["NewPatientCode"]  = patient.PatientCode;
                TempData["NewPatientName"]  = ((patient.Salutation ?? "") + " " + patient.FirstName + " " + patient.LastName).Trim();
                TempData["OPDBillNo"]       = billNo;
                TempData["TokenNo"]         = tokenNo;                          // null unless ₹0 bill
                TempData["TokenPending"]    = string.IsNullOrEmpty(tokenNo);    // true = needs payment
                TempData["IsBooking"]       = true;
                TempData["NewOPDServiceId"] = newSvcId.ToString();
                return RedirectToAction(nameof(PatientRegistration), new { registered = true });
            }

            TempData["Success"] = "Patient record updated successfully.";
            return RedirectToAction(nameof(Index));
        }
    }

    // ─── Delete (POST) ────────────────────────────────────────────────────────

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> DeletePatient(int id)
    {
        await patientService.DeleteAsync(id, User.GetUserId());
        await auditLogService.LogAsync("OPD", "Patient.Delete", $"Deleted patient ID: {id}");
        TempData["Success"] = "Patient record deleted.";
        return RedirectToAction(nameof(Index));
    }

    // ─── Token Management ───────────────────────────────────────────────────────
    
    [HttpGet]
    public async Task<IActionResult> TokenManagement()
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId == null)
        {
            return RedirectToAction("SelectBranch", "Account");
        }

        var doctors = await patientService.GetOpdDoctorsAsync(branchId.Value);
        ViewBag.Doctors = doctors;

        var specialities = await specialityService.GetActiveAsync();
        ViewBag.Specialities = specialities;

        // Doctor → Room mapping  (DoctorName -> "RoomName (FloorName)")
        var roomAssignments = await roomDoctorAssignmentService.GetRoomAssignmentsAsync(branchId.Value);
        var doctorRoomMap = new Dictionary<string, string>();
        foreach (var room in roomAssignments)
        {
            foreach (var doc in room.Doctors)
            {
                doctorRoomMap[doc.FullName] = $"{room.RoomName} ({room.FloorName})";
            }
        }
        ViewBag.DoctorRoomMap = doctorRoomMap;

        return View();
    }

    [HttpGet]
    public async Task<IActionResult> MonitorDisplay()
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId == null)
        {
            return RedirectToAction("SelectBranch", "Account");
        }

        var doctors = await patientService.GetOpdDoctorsAsync(branchId.Value);
        ViewBag.Doctors = doctors;

        var specialities = await specialityService.GetActiveAsync();
        ViewBag.Specialities = specialities;

        // Doctor → Room mapping  (DoctorName -> "RoomName (FloorName)")
        var roomAssignments = await roomDoctorAssignmentService.GetRoomAssignmentsAsync(branchId.Value);
        var doctorRoomMap = new Dictionary<string, string>();
        foreach (var room in roomAssignments)
        {
            foreach (var doc in room.Doctors)
            {
                doctorRoomMap[doc.FullName] = $"{room.RoomName} ({room.FloorName})";
            }
        }
        ViewBag.DoctorRoomMap = doctorRoomMap;

        return View();
    }

    [HttpGet]
    public async Task<IActionResult> GetTodayTokens()
    {
        var branchId = User.GetCurrentBranchId();
        var today = DateOnly.FromDateTime(DateTime.UtcNow.Date);
        var result = await serviceBookingApiClient.GetPagedAsync(branchId, today, today, 1, 200, null);

        // ── Exclude Video consulting patients: they bypass Token Management
        //    and appear directly in Doctor Dashboard ──────────────────────────────
        var videoOpdIds = new HashSet<int>(
            await db.CreateConnection().QueryAsync<int>(@"
                SELECT DISTINCT i.OPDServiceId
                FROM PatientOPDServiceItem i
                JOIN ServiceMaster s ON s.ServiceId = i.ServiceId
                WHERE s.ConsultingType = 'Video' AND i.IsActive = 1
                  AND CAST((SELECT VisitDate FROM PatientOPDService WHERE OPDServiceId = i.OPDServiceId) AS DATE) = CAST(GETDATE() AS DATE)"));

        var filtered = result.Items
            .Where(item => !videoOpdIds.Contains(item.OPDServiceId))
            .ToList();

        return Json(new { isSuccess = true, data = new { result.TotalCount, result.TotalFeesAll, result.RegisteredCount, result.CompletedCount, Items = filtered } });
    }

    [HttpPost]
    public async Task<IActionResult> UpdateTokenStatus([FromBody] UpdateStatusRequest req)
    {
        if (req == null || string.IsNullOrWhiteSpace(req.Status) || req.Id <= 0)
            return Json(new { isSuccess = false, message = "Invalid request." });

        var userId = User.GetUserId();
        var success = await serviceBookingApiClient.UpdateStatusAsync(req.Id, req.Status, userId);

        if (success && req.Status.Equals("Completed", StringComparison.OrdinalIgnoreCase))
        {
            // Send Prescription Email
            var scopeFactory = HttpContext.RequestServices.GetRequiredService<IServiceScopeFactory>();
            var reqId = req.Id;
            var branchIdVal = User.GetCurrentBranchId() ?? 1;
            var hostUrl = $"{Request.Scheme}://{Request.Host}";

            _ = Task.Run(async () =>
            {
                try
                {
                    using var scope = scopeFactory.CreateScope();
                    var db = scope.ServiceProvider.GetRequiredService<ApplicationDbContext>();

                    // Check if email notification is enabled for this branch
                    var settings = await db.HospitalSettings.AsNoTracking().FirstOrDefaultAsync(h => h.BranchId == branchIdVal);
                    if (settings != null && !settings.EmailNotificationRequired)
                    {
                        Console.WriteLine($"[DEBUG-PRESCRIPTION-EMAIL] Email notifications disabled for Branch {branchIdVal}, skipping.");
                        return;
                    }

                    var emailSvc = scope.ServiceProvider.GetRequiredService<IEmailService>();
                    var bookingApi = scope.ServiceProvider.GetRequiredService<IServiceBookingApiClient>();

                    var bookingDetail = await bookingApi.GetByIdAsync(reqId);
                    if (bookingDetail != null)
                    {
                        var branchId = branchIdVal;

                        var template = await db.EmailTemplates
                            .FirstOrDefaultAsync(t => t.BranchId == branchId && t.TemplateName == "Prescription Delivery" && t.IsActive);

                        var doctorId = await db.Database.GetDbConnection().QueryFirstOrDefaultAsync<int?>(
                            "SELECT ConsultingDoctorId FROM PatientOPDService WHERE OPDServiceId = @Id", new { Id = req.Id });

                        // Try to get patient email
                        var patientId = await db.Database.GetDbConnection().QueryFirstOrDefaultAsync<int>(
                            "SELECT PatientId FROM PatientOPDService WHERE OPDServiceId = @Id", new { Id = req.Id });
                        var patient = await db.Database.GetDbConnection().QueryFirstOrDefaultAsync<dynamic>(
                            "SELECT EmailId, FirstName, LastName, PatientCode FROM PatientMaster WHERE PatientId = @Id", new { Id = patientId });

                        if (template != null && patient != null && !string.IsNullOrWhiteSpace(patient.EmailId))
                        {
                            var doctor = doctorId.HasValue ? await db.Database.GetDbConnection().QueryFirstOrDefaultAsync<string>(
                                "SELECT FullName FROM DoctorMaster WHERE DoctorId = @DocId", new { DocId = doctorId.Value }) : null;
                            var hospital = await db.HospitalSettings.FirstOrDefaultAsync(h => h.BranchId == branchId);
                            var hospitalName = hospital?.HospitalName ?? "Our Hospital";

                            var subject = template.Subject.Replace("{{HospitalName}}", hospitalName);

                            var htmlBody = template.HtmlBody
                                .Replace("{{PatientName}}", $"{patient.FirstName} {patient.LastName}")
                                .Replace("{{DoctorName}}", doctor ?? "")
                                .Replace("{{TokenNo}}", bookingDetail.TokenNo ?? "N/A")
                                .Replace("{{VisitDate}}", bookingDetail.VisitDate.ToString("dd-MMM-yyyy"))
                                .Replace("{{HospitalName}}", hospitalName);

                            List<System.Net.Mail.Attachment> attachments = new();
                            string? tempPdfPath = null;

                            try
                            {
                                var docIdVal = doctorId ?? 0;
                                var secret = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes($"prescription-{reqId}-{docIdVal}-emr"));
                                var prescriptionUrl = $"{hostUrl}/OPD/PrintPrescriptionAnonymous?opdServiceId={reqId}&doctorId={docIdVal}&secret={Uri.EscapeDataString(secret)}";
                                
                                var safePatientCode = (string)(patient.PatientCode ?? reqId.ToString());
                                tempPdfPath = Path.Combine(Path.GetTempPath(), $"Prescription_{safePatientCode}.pdf");

                                Console.WriteLine($"[DEBUG-PRESCRIPTION-EMAIL] Generating PDF. URL: {prescriptionUrl}, Output: {tempPdfPath}");

                                var chromeArgs = $"--headless --disable-gpu --ignore-certificate-errors --print-to-pdf=\"{tempPdfPath}\" \"{prescriptionUrl}\"";
                                var processInfo = new System.Diagnostics.ProcessStartInfo("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", chromeArgs)
                                {
                                    CreateNoWindow = true,
                                    UseShellExecute = false
                                };
                                using var process = System.Diagnostics.Process.Start(processInfo);
                                if (process != null)
                                {
                                    await process.WaitForExitAsync();
                                }

                                if (System.IO.File.Exists(tempPdfPath))
                                {
                                    var attachment = new System.Net.Mail.Attachment(tempPdfPath, "application/pdf");
                                    attachments.Add(attachment);
                                    Console.WriteLine($"[DEBUG-PRESCRIPTION-EMAIL] PDF generated and attached successfully: {tempPdfPath}");
                                }
                                else
                                {
                                    Console.WriteLine($"[DEBUG-PRESCRIPTION-EMAIL] PDF generation failed, file does not exist: {tempPdfPath}");
                                }
                            }
                            catch (Exception pdfEx)
                            {
                                Console.WriteLine($"[DEBUG-PRESCRIPTION-EMAIL] Error generating PDF prescription: {pdfEx}");
                            }

                            await emailSvc.SendEmailAsync(branchId, (string)patient.EmailId, subject, htmlBody, attachments.Any() ? attachments : null);
                            Console.WriteLine($"[DEBUG-PRESCRIPTION-EMAIL] Prescription email sent to {patient.EmailId} successfully.");

                            // Cleanup
                            if (!string.IsNullOrEmpty(tempPdfPath) && System.IO.File.Exists(tempPdfPath))
                            {
                                try
                                {
                                    foreach (var att in attachments)
                                    {
                                        att.Dispose();
                                    }
                                    System.IO.File.Delete(tempPdfPath);
                                    Console.WriteLine($"[DEBUG-PRESCRIPTION-EMAIL] Temporary PDF deleted: {tempPdfPath}");
                                }
                                catch (Exception deleteEx)
                                {
                                    Console.WriteLine($"[DEBUG-PRESCRIPTION-EMAIL] Failed to delete temporary PDF file: {deleteEx}");
                                }
                            }
                        }
                    }
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"Error sending prescription email: {ex.Message}");
                }
            });
        }

        return Json(new { isSuccess = success, message = success ? "Success" : "Failed to update." });
    }

    public class UpdateStatusRequest
    {
        public int Id { get; set; }
        public string Status { get; set; } = string.Empty;
    }

    [HttpGet]
    public async Task<IActionResult> ServiceBooking(
        string? fromDate, string? toDate,
        int page = 1, int pageSize = 10, string? search = null)
    {
        var branchId = User.GetCurrentBranchId();
        if (page < 1) page = 1;
        if (pageSize is < 5 or > 100) pageSize = 10;

        DateOnly? from = DateOnly.TryParse(fromDate, out var fd) ? fd : null;
        DateOnly? to   = DateOnly.TryParse(toDate,   out var td) ? td : null;

        // Default: today
        if (from is null && to is null)
            from = to = DateOnly.FromDateTime(DateTime.Today);

        // Strictly via EMR.Api — no DB fallback
        try
        {
            var apiResult = await serviceBookingApiClient.GetPagedAsync(
                branchId, from, to, page, pageSize, search?.Trim());

            var paged = new ServiceBookingPagedListViewModel
            {
                Items = apiResult.Items.Select(b => new ServiceBookingListItem
                {
                    OPDServiceId         = b.OPDServiceId,
                    VisitDate            = b.VisitDate,
                    OPDBillNo            = b.OPDBillNo,
                    TokenNo              = b.TokenNo,
                    PatientCode          = b.PatientCode,
                    PatientId            = b.PatientId,
                    PatientName          = b.PatientName,
                    Gender               = b.Gender,
                    Age                  = b.Age,
                    ConsultingDoctorName = b.ConsultingDoctorName,
                    TotalAmount          = b.TotalAmount,
                    Status               = b.Status,
                    PaymentStatus        = b.PaymentStatus,
                    ServiceTypesSummary  = b.ServiceTypesSummary,
                    TotalCount           = apiResult.TotalCount,
                    TotalFeesAll         = apiResult.TotalFeesAll,
                    RegisteredCount      = apiResult.RegisteredCount,
                    CompletedCount       = apiResult.CompletedCount
                }).ToList(),
                TotalCount      = apiResult.TotalCount,
                TotalFeesAll    = apiResult.TotalFeesAll,
                RegisteredCount = apiResult.RegisteredCount,
                CompletedCount  = apiResult.CompletedCount,
                Page            = page,
                PageSize        = pageSize,
                Search          = search?.Trim(),
                FromDate        = from?.ToString("yyyy-MM-dd"),
                ToDate          = to?.ToString("yyyy-MM-dd")
            };

            ViewData["Title"] = "Service Booking";
            return View(paged);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Service Booking";
            return View("ApiDown");
        }
    }

    // ─── Service Booking Detail AJAX (via EMR.Api) ───────────────────────────

    [HttpGet]
    public async Task<IActionResult> GetServiceBookingDetail(int id)
    {
        try
        {
            var detail = await serviceBookingApiClient.GetByIdAsync(id);
            if (detail is null) return NotFound();

            // Map to existing ViewModel shape so the Razor view + JS are unchanged
            return Json(new
            {
                detail.OPDServiceId,
                detail.OPDBillNo,
                detail.TokenNo,
                detail.PatientCode,
                detail.PatientName,
                detail.PhoneNumber,
                detail.Gender,
                detail.DateOfBirth,
                detail.Age,
                detail.ConsultingDoctorName,
                detail.VisitDate,
                detail.TotalAmount,
                detail.Status,
                detail.CreatedByUser,
                Items = detail.Items.Select(i => new
                {
                    i.ServiceType,
                    i.ItemName,
                    i.ServiceCharges
                })
            });
        }
        catch (HttpRequestException)
        {
            return StatusCode(503, new { error = "API service unavailable." });
        }
    }

    // ─── New Service Booking (GET) ────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> NewServiceBooking(int? doctorId = null, string? date = null, int? scheduleId = null, string? time = null)
    {
        ViewData["Title"] = "New Service Booking";
        var model = new PatientRegistrationViewModel 
        { 
            DemographicsOnly = false,
            ConsultingDoctorId = doctorId,
            AppointmentDate = DateTime.TryParse(date, out var d) ? d : DateTime.Today,
            ScheduleId = scheduleId,
            AppointmentTime = TimeSpan.TryParse(time, out var t) ? t : null
        };
        await PopulateSelectLists(model);
        return View(model);
    }

    // ─── New Service Booking (POST) ───────────────────────────────────────────
    // Reuses the same POST handler as PatientRegistration but always routes back
    // to ServiceBooking list on success.

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> NewServiceBooking(PatientRegistrationViewModel model, IFormFile? identificationFile)
    {
        // Must be an existing patient — demographics are NEVER modified from this screen
        if (model.PatientId <= 0)
        {
            ModelState.AddModelError(string.Empty, "Please search and load an existing patient before booking.");
            await PopulateSelectLists(model);
            return View(model);
        }

        // Strip all demographic field validation — this screen only submits bill data
        var keepFields = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            { nameof(model.ConsultingDoctorId), nameof(model.LineItemsJson) };
        foreach (var key in ModelState.Keys.Where(k => !keepFields.Contains(k)).ToList())
            ModelState.Remove(key);

        if (!ModelState.IsValid)
        {
            await PopulateSelectLists(model);
            return View(model);
        }

        var branchId = User.GetCurrentBranchId();
        var userId   = User.GetUserId();

        var bill      = MapViewModelToOPDBill(model);
        bill.BranchId = branchId;

        var (billNo, tokenNo, newSvcId) = await patientService.CreateServiceBookingOnlyAsync(
            bill, model.LineItemsJson ?? "[]", userId);

        TempData["OPDBillNo"]      = billNo;
        TempData["TokenNo"]        = tokenNo;                          // null unless ₹0 bill
        TempData["TokenPending"]   = string.IsNullOrEmpty(tokenNo);    // true = needs payment
        TempData["NewPatientCode"] = model.PatientCode;
        TempData["NewPatientName"] = $"{model.FirstName} {model.LastName}".Trim();
        TempData["IsBooking"]      = true;
        TempData["NewOPDServiceId"] = newSvcId.ToString();

        await auditLogService.LogAsync("OPD", "ServiceBooking.New",
            $"New booking for patient {model.PatientCode} — Bill {billNo}, Token {(string.IsNullOrEmpty(tokenNo) ? "(pending payment)" : tokenNo)}");

        TriggerBookingEmail(branchId, newSvcId, $"{Request.Scheme}://{Request.Host}");

        return RedirectToAction(nameof(ServiceBooking));
    }

    // ─── AJAX APIs ────────────────────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> SearchPatientByPhone(string phone)
    {
        if (string.IsNullOrWhiteSpace(phone) || phone.Length < 3)
            return Json(Array.Empty<object>());
        
        var branchId = User.GetCurrentBranchId();
        var settings = await dbContext.HospitalSettings.FirstOrDefaultAsync(s => s.BranchId == branchId);
        int? searchBranchId = settings?.GlobalPatientSearchRequired == true ? null : branchId;

        var results = await patientService.SearchByPhoneAsync(phone.Trim(), searchBranchId);
        return Json(results);
    }

    [HttpGet]
    public async Task<IActionResult> SearchPatientByCode(string code)
    {
        if (string.IsNullOrWhiteSpace(code) || code.Length < 2)
            return Json(Array.Empty<object>());
        
        var branchId = User.GetCurrentBranchId();
        var settings = await dbContext.HospitalSettings.FirstOrDefaultAsync(s => s.BranchId == branchId);
        int? searchBranchId = settings?.GlobalPatientSearchRequired == true ? null : branchId;

        var results = await patientService.SearchByCodeAsync(code.Trim(), searchBranchId);
        return Json(results);
    }

    [HttpGet]
    public async Task<IActionResult> SearchPatientByName(string name)
    {
        if (string.IsNullOrWhiteSpace(name) || name.Length < 2)
            return Json(Array.Empty<object>());
        
        var branchId = User.GetCurrentBranchId();
        var settings = await dbContext.HospitalSettings.FirstOrDefaultAsync(s => s.BranchId == branchId);
        int? searchBranchId = settings?.GlobalPatientSearchRequired == true ? null : branchId;

        var results = await patientService.SearchByNameAsync(name.Trim(), searchBranchId);
        return Json(results);
    }

    [HttpGet]
    public async Task<IActionResult> SearchBookingSuggestions(
        string? q, string? fromDate, string? toDate)
    {
        if (string.IsNullOrWhiteSpace(q) || q.Trim().Length < 2)
            return Json(Array.Empty<object>());

        var branchId = User.GetCurrentBranchId();
        DateOnly? from = DateOnly.TryParse(fromDate, out var fd) ? fd : null;
        DateOnly? to   = DateOnly.TryParse(toDate,   out var td) ? td : null;
        if (from is null && to is null)
            from = to = DateOnly.FromDateTime(DateTime.Today);

        try
        {
            // Strictly via EMR.Api — no DB fallback
            var apiResult = await serviceBookingApiClient.GetPagedAsync(
                branchId, from, to, 1, 8, q.Trim());

            var suggestions = apiResult.Items.Select(b => new
            {
                b.OPDServiceId,
                b.PatientCode,
                b.PatientName,
                b.OPDBillNo,
                b.TokenNo,
                b.Gender,
                b.Age,
                b.ConsultingDoctorName,
                b.Status,
                TotalAmount = b.TotalAmount.ToString("N2")
            });
            return Json(suggestions);
        }
        catch (HttpRequestException)
        {
            return Json(Array.Empty<object>());
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var patient = await patientService.GetByIdAsync(id);
        if (patient is null) return NotFound();

        var names = await patientService.GetDemographicNamesAsync(id);
        string? idTypeName = patient.IdentificationTypeId.HasValue
            ? await patientService.GetIdentificationTypeNameAsync(patient.IdentificationTypeId.Value)
            : null;

        List<EMR.Web.ApiClients.Models.VitalRow> vitals = [];
        try
        {
            var vitalsResult = await vitalApiClient.GetHistoryAsync(id, 1, 50);
            vitals = vitalsResult?.Rows ?? [];
        }
        catch (Exception)
        {
            // Silently fallback if Api is down
        }

        List<PatientVisitHistoryItem> visits = [];
        try
        {
            using var con = db.CreateConnection();
            visits = (await con.QueryAsync<PatientVisitHistoryItem>(@"
                SELECT 
                    s.OPDServiceId, 
                    s.VisitDate, 
                    s.OPDBillNo, 
                    s.TokenNo, 
                    s.TotalAmount, 
                    s.Status, 
                    ISNULL((SELECT TOP 1 ph.PaymentStatus FROM PaymentHeader ph 
                            WHERE ph.ModuleCode = 'OPD' AND ph.ModuleRefId = s.OPDServiceId AND ph.IsActive = 1), 'U') AS PaymentStatus,
                    ISNULL(d.NamePrefix + ' ', '') + d.FullName AS ConsultingDoctorName,
                    ISNULL(
                        STUFF((
                            SELECT DISTINCT ', ' + ISNULL(si.ServiceType, '')
                            FROM PatientOPDServiceItem si
                            WHERE si.OPDServiceId = s.OPDServiceId AND si.IsActive = 1
                            FOR XML PATH(''), TYPE
                        ).value('.','NVARCHAR(MAX)'), 1, 2, ''), ''
                    ) AS ServiceTypesSummary
                FROM PatientOPDService s
                LEFT JOIN DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
                WHERE s.PatientId = @PatientId AND s.IsActive = 1
                ORDER BY s.OPDServiceId DESC",
                new { PatientId = id })).ToList();
        }
        catch (Exception)
        {
            // Silently fallback
        }

        var model = new PatientDetailsViewModel
        {
            Patient = patient,
            ReligionName = names.ReligionName,
            MaritalStatusName = names.MaritalStatusName,
            OccupationName = names.OccupationName,
            AreaName = names.AreaName,
            CityName = names.CityName,
            DistrictName = names.DistrictName,
            StateName = names.StateName,
            CountryName = names.CountryName,
            IdentificationTypeName = idTypeName,
            VisitHistory = visits,
            VitalHistory = vitals
        };

        return View(model);
    }

    [HttpGet]
    public async Task<IActionResult> GetPatientVitalsChartData(int id)
    {
        try
        {
            var vitalsResult = await vitalApiClient.GetHistoryAsync(id, 1, 100);
            var rows = vitalsResult?.Rows ?? new List<EMR.Web.ApiClients.Models.VitalRow>();
            var chartData = rows
                .OrderBy(v => v.RecordedOn)
                .Select(v => new
                {
                    RecordedOn = v.RecordedOn.ToString("dd MMM yyyy, HH:mm"),
                    v.Height,
                    v.Weight,
                    v.BPSystolic,
                    v.BPDiastolic,
                    v.PulseRate,
                    v.SpO2,
                    v.Temperature,
                    v.BloodGlucose
                }).ToList();

            return Json(chartData);
        }
        catch (Exception)
        {
            return Json(Array.Empty<object>());
        }
    }

    [HttpGet]
    public async Task<IActionResult> GetPatientVisitsChartData(int id)
    {
        try
        {
            using var con = db.CreateConnection();
            var visitsByDate = await con.QueryAsync(@"
                SELECT 
                    CAST(s.VisitDate AS DATE) AS VisitDate, 
                    SUM(ISNULL(s.TotalAmount, 0)) AS TotalAmount
                FROM PatientOPDService s
                WHERE s.PatientId = @PatientId AND s.IsActive = 1
                GROUP BY CAST(s.VisitDate AS DATE)
                ORDER BY CAST(s.VisitDate AS DATE) ASC",
                new { PatientId = id });

            var consultingByDoctor = await con.QueryAsync(@"
                SELECT 
                    ISNULL(d.NamePrefix + ' ', '') + d.FullName AS DoctorName,
                    COUNT(s.OPDServiceId) AS ConsultingCount
                FROM PatientOPDService s
                INNER JOIN DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
                WHERE s.PatientId = @PatientId AND s.IsActive = 1
                GROUP BY d.NamePrefix, d.FullName
                ORDER BY ConsultingCount DESC",
                new { PatientId = id });

            var chartData = new
            {
                billData = visitsByDate.Select(v => new
                {
                    visitDate = ((DateTime)v.VisitDate).ToString("dd MMM yyyy"),
                    totalAmount = (decimal)v.TotalAmount
                }).ToList(),
                consultingData = consultingByDoctor.Select(c => new
                {
                    doctorName = (string)c.DoctorName,
                    consultingCount = (int)c.ConsultingCount
                }).ToList()
            };

            return Json(chartData);
        }
        catch (Exception)
        {
            return Json(Array.Empty<object>());
        }
    }

    [HttpGet]
    public async Task<IActionResult> GetPatientDetails(int id)
    {
        var patient = await patientService.GetByIdAsync(id);
        if (patient is null) return NotFound();
        var svc = await patientService.GetLatestOPDServiceAsync(id);

        string? idTypeName = patient.IdentificationTypeId.HasValue
            ? await patientService.GetIdentificationTypeNameAsync(patient.IdentificationTypeId.Value)
            : null;

        var names = await patientService.GetDemographicNamesAsync(id);

        return Json(new
        {
            // Patient demographics
            patient.PatientId, patient.PatientCode, patient.PhoneNumber, patient.SecondaryPhoneNumber,
            patient.Salutation, patient.FirstName, patient.MiddleName, patient.LastName,
            patient.Gender, patient.EmailId, patient.GuardianName,
            patient.IdentificationTypeId, patient.IdentificationNumber, patient.IdentificationFilePath,
            patient.PhotoPath,
            IdentificationTypeName = idTypeName,
            patient.BloodGroup, patient.KnownAllergies, patient.Remarks, patient.DateOfBirth,
            // Resolved display names (replace raw IDs)
            ReligionName      = names.ReligionName,
            MaritalStatusName = names.MaritalStatusName,
            OccupationName    = names.OccupationName,
            AreaName          = names.AreaName,
            CityName          = names.CityName,
            DistrictName      = names.DistrictName,
            StateName         = names.StateName,
            CountryName       = names.CountryName,
            // Raw IDs still needed for form pre-fill
            patient.ReligionId, patient.MaritalStatusId, patient.OccupationId,
            patient.CountryId, patient.StateId, patient.DistrictId, patient.CityId, patient.AreaId,
            patient.Address,
            patient.RelationId,
            // Latest OPD bill header (null-safe) — only doctor needed for pre-fill
            OPDServiceId       = svc?.OPDServiceId ?? 0,
            ConsultingDoctorId = svc?.ConsultingDoctorId
        });
    }

    [HttpGet]
    public async Task<IActionResult> GetServicesByType(string type)
    {
        if (string.IsNullOrWhiteSpace(type)) return Json(Array.Empty<object>());
        var branchId = User.GetCurrentBranchId();
        var services = await patientService.GetServicesByTypeAsync(type, branchId);
        return Json(services.Select(s => new { s.ServiceId, s.ItemName, s.ItemCharges, s.IsRegistration }));
    }

    [HttpGet]
    public async Task<IActionResult> GetRegistrationValidity(int patientId)
    {

        var branchId = User.GetCurrentBranchId();
        var settings = await dbContext.HospitalSettings
            .FirstOrDefaultAsync(s => s.BranchId == branchId);
        int? validityDays = settings?.OpdRegistrationValidityDays;

        if (validityDays == null || validityDays <= 0)
            return Json(new { validityConfigured = false });

        var lastRegDate = await patientService.GetLastRegistrationDateAsync(patientId);
        if (lastRegDate == null)
            return Json(new
            {
                validityConfigured      = true,
                isRegistrationValid     = false,
                remainingDays           = (int?)null,
                lastRegistrationDate    = (string?)null,
                validityDays
            });

        // CreatedDate is stored as UTC
        var daysSince = (DateTime.UtcNow - lastRegDate.Value).TotalDays;
        bool isValid  = daysSince < validityDays.Value;
        int  remaining = isValid ? (int)Math.Ceiling(validityDays.Value - daysSince) : 0;

        return Json(new
        {
            validityConfigured      = true,
            isRegistrationValid     = isValid,
            remainingDays           = isValid ? remaining : (int?)null,
            lastRegistrationDate    = lastRegDate.Value.ToString("dd MMM yyyy"),
            validityDays
        });
    }

    [HttpGet]
    public async Task<IActionResult> GetConsultingFeesByDoctor(int doctorId)
    {
        if (doctorId <= 0) return Json(Array.Empty<object>());
        var branchId = User.GetCurrentBranchId() ?? 0;
        var fees = await consultingFeeService.GetByDoctorAsync(doctorId, branchId);
        return Json(fees.Select(f => new { ServiceId = f.ServiceId, ItemName = f.ItemName, ItemCharges = f.ItemCharges }));
    }

    [HttpGet]
    public async Task<IActionResult> GetStatesByCountry(int countryId)
    {
        var states = await stateService.GetByCountryAsync(countryId);
        return Json(states.Where(s => s.IsActive).Select(s => new { s.StateId, s.StateName }));
    }

    [HttpGet]
    public async Task<IActionResult> GetDistrictsByState(int stateId)
    {
        var districts = await districtService.GetByStateAsync(stateId);
        return Json(districts.Where(d => d.IsActive).Select(d => new { d.DistrictId, d.DistrictName }));
    }

    [HttpGet]
    public async Task<IActionResult> GetCitiesByDistrict(int districtId)
    {
        var cities = await cityService.GetByDistrictAsync(districtId);
        return Json(cities.Where(c => c.IsActive).Select(c => new { c.CityId, c.CityName }));
    }

    [HttpGet]
    public async Task<IActionResult> GetAreasByCity(int cityId)
    {
        var areas = await areaService.GetByCityAsync(cityId);
        return Json(areas.Where(a => a.IsActive).Select(a => new { a.AreaId, a.AreaName }));
    }

    [HttpGet]
    public async Task<IActionResult> GetAvailableSlots(int doctorId, string date)
    {
        if (doctorId <= 0 || !DateTime.TryParse(date, out var dt))
            return Json(new { hasException = false, slots = Array.Empty<object>() });

        var branchId = User.GetCurrentBranchId() ?? 0;
        try
        {
            var result = await scheduleApiClient.GetAvailableSlotsAsync(doctorId, branchId, dt);
            return Json(result);
        }
        catch (Exception ex)
        {
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // ─── Print Bill (via EMR.Api) ─────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> PrintBill(int id)
    {
        try
        {
            var apiDetail = await serviceBookingApiClient.GetByIdAsync(id);
            if (apiDetail is null) return NotFound();

            // Map API model → existing ServiceBookingDetailViewModel (view is unchanged)
            var detail = new ServiceBookingDetailViewModel
            {
                OPDServiceId         = apiDetail.OPDServiceId,
                OPDBillNo            = apiDetail.OPDBillNo,
                TokenNo              = apiDetail.TokenNo,
                PatientCode          = apiDetail.PatientCode,
                PatientName          = apiDetail.PatientName,
                PhoneNumber          = apiDetail.PhoneNumber,
                Gender               = apiDetail.Gender,
                DateOfBirth          = apiDetail.DateOfBirth,
                ConsultingDoctorName = apiDetail.ConsultingDoctorName,
                VisitDate            = apiDetail.VisitDate,
                AppointmentTime      = apiDetail.AppointmentTime,
                CreatedDate          = apiDetail.CreatedDate,
                CreatedByUser        = apiDetail.CreatedByUser,
                TotalAmount          = apiDetail.TotalAmount,
                Status               = apiDetail.Status,
                Items                = apiDetail.Items.Select(i => new ServiceBookingDetailItem
                {
                    ItemId         = i.ItemId,
                    ServiceType    = i.ServiceType,
                    ItemName       = i.ItemName,
                    ServiceCharges = i.ServiceCharges,
                    IsGstRequired  = i.IsGstRequired,
                    GstPercentage  = i.GstPercentage
                }).ToList()
            };

            var branchId = User.GetCurrentBranchId();
            var settings = branchId.HasValue
                ? await dbContext.HospitalSettings.FirstOrDefaultAsync(s => s.BranchId == branchId.Value)
                : null;
            var branch = branchId.HasValue
                ? await dbContext.BranchMasters.FindAsync(branchId.Value)
                : null;

            var payment = await paymentService.GetPaymentForBillAsync("OPD", id);

            ViewBag.Settings   = settings;
            ViewBag.BranchName = branch?.BranchName ?? string.Empty;
            ViewBag.Payment    = payment;
            return View(detail);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Print Bill";
            return View("ApiDown");
        }
    }

    [HttpGet, AllowAnonymous]
    public async Task<IActionResult> PrintBillAnonymous(int id, string secret)
    {
        var expectedSecret = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes($"bill-{id}-emr"));
        if (secret != expectedSecret)
        {
            return Unauthorized("Invalid secret token.");
        }

        try
        {
            var apiDetail = await serviceBookingApiClient.GetByIdAsync(id);
            if (apiDetail is null) return NotFound();

            var detail = new ServiceBookingDetailViewModel
            {
                OPDServiceId         = apiDetail.OPDServiceId,
                OPDBillNo            = apiDetail.OPDBillNo,
                TokenNo              = apiDetail.TokenNo,
                PatientCode          = apiDetail.PatientCode,
                PatientName          = apiDetail.PatientName,
                PhoneNumber          = apiDetail.PhoneNumber,
                Gender               = apiDetail.Gender,
                DateOfBirth          = apiDetail.DateOfBirth,
                ConsultingDoctorName = apiDetail.ConsultingDoctorName,
                VisitDate            = apiDetail.VisitDate,
                AppointmentTime      = apiDetail.AppointmentTime,
                CreatedDate          = apiDetail.CreatedDate,
                CreatedByUser        = apiDetail.CreatedByUser,
                TotalAmount          = apiDetail.TotalAmount,
                Status               = apiDetail.Status,
                Items                = apiDetail.Items.Select(i => new ServiceBookingDetailItem
                {
                    ItemId         = i.ItemId,
                    ServiceType    = i.ServiceType,
                    ItemName       = i.ItemName,
                    ServiceCharges = i.ServiceCharges,
                    IsGstRequired  = i.IsGstRequired,
                    GstPercentage  = i.GstPercentage
                }).ToList()
            };

            var booking = await dbContext.PatientOPDServices.FirstOrDefaultAsync(b => b.OPDServiceId == id);
            var branchId = booking?.BranchId ?? 1;
            var settings = await dbContext.HospitalSettings.FirstOrDefaultAsync(s => s.BranchId == branchId);
            var branch = await dbContext.BranchMasters.FindAsync(branchId);

            var payment = await paymentService.GetPaymentForBillAsync("OPD", id);

            ViewBag.Settings   = settings;
            ViewBag.BranchName = branch?.BranchName ?? string.Empty;
            ViewBag.Payment    = payment;
            return View("PrintBill", detail);
        }
        catch (HttpRequestException)
        {
            return StatusCode(503, "API Down");
        }
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    private async Task PopulateSelectLists(PatientRegistrationViewModel model)
    {
        var branchId = User.GetCurrentBranchId();
        var countries = await countryService.GetActiveAsync();
        model.CountryOptions = countries
            .Select(c => new SelectListItem(c.CountryName, c.CountryId.ToString()))
            .ToList();

        var india = countries.FirstOrDefault(c => c.CountryName.Equals("India", StringComparison.OrdinalIgnoreCase));
        int defaultCountryId = india?.CountryId ?? (countries.FirstOrDefault()?.CountryId ?? 0);
        if (!model.CountryId.HasValue && defaultCountryId > 0)
            model.CountryId = defaultCountryId;

        if (model.CountryId.HasValue)
        {
            var states = await stateService.GetByCountryAsync(model.CountryId.Value);
            model.StateOptions = states
                .Where(s => s.IsActive)
                .Select(s => new SelectListItem(s.StateName, s.StateId.ToString()))
                .ToList();
            var wb = states.FirstOrDefault(s => s.StateName.Contains("West Bengal", StringComparison.OrdinalIgnoreCase));
            if (!model.StateId.HasValue && wb is not null)
                model.StateId = wb.StateId;
        }

        if (model.StateId.HasValue)
        {
            var districts = await districtService.GetByStateAsync(model.StateId.Value);
            model.DistrictOptions = districts
                .Where(d => d.IsActive)
                .Select(d => new SelectListItem(d.DistrictName, d.DistrictId.ToString()))
                .ToList();
        }

        if (model.DistrictId.HasValue)
        {
            var cities = await cityService.GetByDistrictAsync(model.DistrictId.Value);
            model.CityOptions = cities
                .Where(c => c.IsActive)
                .Select(c => new SelectListItem(c.CityName, c.CityId.ToString()))
                .ToList();
        }

        if (model.CityId.HasValue)
        {
            var areas = await areaService.GetByCityAsync(model.CityId.Value);
            model.AreaOptions = areas
                .Where(a => a.IsActive)
                .Select(a => new SelectListItem(a.AreaName, a.AreaId.ToString()))
                .ToList();
        }

        model.ReligionOptions = await dbContext.ReligionMasters
            .Where(r => r.IsActive)
            .OrderBy(r => r.ReligionName)
            .Select(r => new SelectListItem(r.ReligionName, r.ReligionId.ToString()))
            .ToListAsync();

        model.RelationOptions = await dbContext.RelationMasters
            .Where(r => r.IsActive)
            .OrderBy(r => r.SortOrder).ThenBy(r => r.RelationName)
            .Select(r => new SelectListItem(r.RelationName, r.RelationId.ToString()))
            .ToListAsync();

        model.IdentificationTypeOptions = await dbContext.IdentificationTypeMasters
            .Where(i => i.IsActive)
            .OrderBy(i => i.IdentificationTypeName)
            .Select(i => new SelectListItem(i.IdentificationTypeName, i.IdentificationTypeId.ToString()))
            .ToListAsync();

        model.OccupationOptions = await dbContext.OccupationMasters
            .Where(o => o.IsActive)
            .OrderBy(o => o.OccupationName)
            .Select(o => new SelectListItem(o.OccupationName, o.OccupationId.ToString()))
            .ToListAsync();

        model.MaritalStatusOptions = await dbContext.MaritalStatusMasters
            .Where(m => m.IsActive)
            .OrderBy(m => m.StatusName)
            .Select(m => new SelectListItem(m.StatusName, m.MaritalStatusId.ToString()))
            .ToListAsync();

        var doctors = await patientService.GetOpdDoctorsAsync(branchId);
        model.DoctorOptions = doctors
            .Select(d => new SelectListItem(d.FullName, d.DoctorId.ToString()))
            .ToList();

        model.ReferralDoctorOptions = await dbContext.ReferralDoctorMasters
            .Where(r => r.IsActive)
            .OrderBy(r => r.DoctorName)
            .Select(r => new SelectListItem(r.DoctorName, r.ReferralDoctorId.ToString()))
            .ToListAsync();
    }

    [HttpPost]
    public async Task<IActionResult> CreateReferralDoctorQuick([FromForm] string name, [FromForm] string phone)
    {
        if (string.IsNullOrWhiteSpace(name))
            return Json(new { success = false, message = "Doctor name is required." });

        var doc = new ReferralDoctorMaster
        {
            DoctorName = name.Trim(),
            PhoneNumber = phone?.Trim(),
            IsActive = true,
            CreatedBy = User.GetUserId(),
            CreatedDate = DateTime.Now
        };
        
        dbContext.ReferralDoctorMasters.Add(doc);
        await dbContext.SaveChangesAsync();
        
        return Json(new { success = true, id = doc.ReferralDoctorId, name = doc.DoctorName });
    }

    private static string? CapitalizeName(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return name;
        return System.Globalization.CultureInfo.CurrentCulture.TextInfo.ToTitleCase(name.Trim().ToLower());
    }

    private static PatientMaster MapViewModelToPatient(PatientRegistrationViewModel m) => new()
    {
        PatientId             = m.PatientId,
        PatientCode           = m.PatientCode ?? string.Empty,
        PhoneNumber           = m.PhoneNumber.Trim(),
        SecondaryPhoneNumber  = m.SecondaryPhoneNumber?.Trim(),
        Salutation            = m.Salutation,
        FirstName             = CapitalizeName(m.FirstName) ?? "",
        MiddleName            = CapitalizeName(m.MiddleName),
        LastName              = CapitalizeName(m.LastName) ?? "",
        Gender                = m.Gender,
        DateOfBirth           = m.DateOfBirth,
        ReligionId            = m.ReligionId,
        EmailId               = m.EmailId?.Trim(),
        GuardianName          = m.GuardianName?.Trim(),
        CountryId             = m.CountryId,
        StateId               = m.StateId,
        DistrictId            = m.DistrictId,
        CityId                = m.CityId,
        AreaId                = m.AreaId,
        Address               = m.Address?.Trim(),
        RelationId            = m.RelationId,
        IdentificationTypeId  = m.IdentificationTypeId,
        IdentificationNumber  = m.IdentificationNumber?.Trim(),
        IdentificationFilePath= m.IdentificationFilePath,
        PhotoPath             = m.PhotoPath,
        OccupationId          = m.OccupationId,
        MaritalStatusId       = m.MaritalStatusId,
        BloodGroup            = m.BloodGroup,
        KnownAllergies        = m.KnownAllergies?.Trim(),
        Remarks               = m.Remarks?.Trim(),
        ReferralDoctorId      = m.ReferralDoctorId,
    };

    private static PatientOPDService MapViewModelToOPDBill(PatientRegistrationViewModel m) => new()
    {
        OPDServiceId       = m.OPDServiceId,
        PatientId          = m.PatientId,
        ConsultingDoctorId = m.ConsultingDoctorId,
        ScheduleId         = m.ScheduleId,
        VisitDate          = m.AppointmentDate ?? DateTime.Now,
        AppointmentTime    = m.AppointmentTime
    };

    private static PatientRegistrationViewModel MapPatientToViewModel(PatientMaster p) => new()
    {
        PatientId             = p.PatientId,
        PatientCode           = p.PatientCode,
        PhoneNumber           = p.PhoneNumber,
        SecondaryPhoneNumber  = p.SecondaryPhoneNumber,
        Salutation            = p.Salutation,
        FirstName             = p.FirstName,
        MiddleName            = p.MiddleName,
        LastName              = p.LastName,
        Gender                = p.Gender,
        DateOfBirth           = p.DateOfBirth,
        ReligionId            = p.ReligionId,
        EmailId               = p.EmailId,
        GuardianName          = p.GuardianName,
        CountryId             = p.CountryId,
        StateId               = p.StateId,
        DistrictId            = p.DistrictId,
        CityId                = p.CityId,
        AreaId                = p.AreaId,
        Address               = p.Address,
        RelationId            = p.RelationId,
        IdentificationTypeId  = p.IdentificationTypeId,
        IdentificationNumber  = p.IdentificationNumber,
        IdentificationFilePath= p.IdentificationFilePath,
        PhotoPath             = p.PhotoPath,
        OccupationId          = p.OccupationId,
        MaritalStatusId       = p.MaritalStatusId,
        BloodGroup            = p.BloodGroup,
        KnownAllergies        = p.KnownAllergies,
        Remarks               = p.Remarks,
        ReferralDoctorId      = p.ReferralDoctorId,
    };

    private static void MapOPDBillToViewModel(PatientOPDService svc, PatientRegistrationViewModel m)
    {
        m.OPDServiceId       = svc.OPDServiceId;
        m.ConsultingDoctorId = svc.ConsultingDoctorId;
    }

    // ─── Payment endpoints ────────────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> GetPaymentMethods()
    {
        var methods = await paymentService.GetActiveMethodsAsync();
        return Json(methods);
    }

    [HttpGet]
    public async Task<IActionResult> GetPaymentSummary(string moduleCode, int moduleRefId)
    {
        try
        {
            var summary = await paymentSummaryApiClient.GetAsync(moduleCode, moduleRefId);
            if (summary is null)
                return Json(new { success = false, error = "Bill not found." });
            return Json(new { success = true, data = summary });
        }
        catch (HttpRequestException)
        {
            return StatusCode(503, new { success = false, error = "Payment summary API unavailable. Please try again later." });
        }
    }

    [HttpPost]
    public async Task<IActionResult> SavePayment([FromBody] SavePaymentRequest request)
    {
        if (!ModelState.IsValid)
            return Json(new SavePaymentResult { Success = false, Error = "Invalid request." });

        var userId = User.GetUserId();
        var result = await paymentService.SavePaymentAsync(request, userId);

        // ── Video Consultation: trigger ONLY when payment becomes fully paid ──
        if (result.Success && result.PaymentStatus == "P" && (request.OPDServiceId ?? 0) > 0)
        {
            TriggerVideoOnFullPayment(User.GetCurrentBranchId(), request.OPDServiceId!.Value);
        }

        return Json(result);
    }

    // ─── EMR Patient Consultation Endpoints ───────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> GetPatientConsultationData(int opdServiceId, int doctorId)
    {
        var booking = await serviceBookingApiClient.GetByIdAsync(opdServiceId);
        if (booking == null)
        {
            return Json(new { success = false, message = "OPD service booking not found." });
        }

        var data = await emrConsultationApiClient.GetConsultationDataAsync(opdServiceId, doctorId);
        
        if (data == null)
        {
            return Json(new { success = false, message = "Consultation setup data not found. Ensure doctor has a template mapped to their primary speciality." });
        }

        return Json(new {
            success = true,
            booking = data.Booking,
            template = data.Template,
            savedConsultation = data.SavedConsultation
        });
    }

    [HttpGet]
    public async Task<IActionResult> PrintPrescription(int opdServiceId, int doctorId)
    {
        var booking = await serviceBookingApiClient.GetByIdAsync(opdServiceId);
        if (booking == null) return NotFound("Booking not found");

        var doctor = await doctorApiClient.GetByIdAsync(doctorId);
        if (doctor == null) return NotFound("Doctor not found");

        // Use Dapper to get PatientId from ServiceBooking header isn't straightforward because PatientId isn't in ServiceBookingDetail but PatientCode is.
        // Wait, ServiceBookingDetail doesn't have PatientId directly?
        // Let me query PatientId from db.
        var patientId = await db.CreateConnection().ExecuteScalarAsync<int>(
            "SELECT PatientId FROM PatientOPDService WHERE OPDServiceId = @OPDServiceId", new { OPDServiceId = opdServiceId });

        var vitals = await vitalApiClient.GetLatestAsync(patientId);
        var emrData = await emrConsultationApiClient.GetConsultationDataAsync(opdServiceId, doctorId);

        var vm = new EMR.Web.Models.PrintPrescriptionViewModel
        {
            Booking = booking,
            Doctor = doctor,
            Vitals = vitals,
            EmrData = emrData
        };

        return View(vm);
    }

    [HttpGet, AllowAnonymous]
    public async Task<IActionResult> PrintPrescriptionAnonymous(int opdServiceId, int doctorId, string secret)
    {
        var expectedSecret = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes($"prescription-{opdServiceId}-{doctorId}-emr"));
        if (secret != expectedSecret)
        {
            return Unauthorized("Invalid secret token.");
        }

        var booking = await serviceBookingApiClient.GetByIdAsync(opdServiceId);
        if (booking == null) return NotFound("Booking not found");

        var doctor = await doctorApiClient.GetByIdAsync(doctorId);
        if (doctor == null) return NotFound("Doctor not found");

        var patientId = await db.CreateConnection().ExecuteScalarAsync<int>(
            "SELECT PatientId FROM PatientOPDService WHERE OPDServiceId = @OPDServiceId", new { OPDServiceId = opdServiceId });

        var vitals = await vitalApiClient.GetLatestAsync(patientId);
        var emrData = await emrConsultationApiClient.GetConsultationDataAsync(opdServiceId, doctorId);

        var vm = new EMR.Web.Models.PrintPrescriptionViewModel
        {
            Booking = booking,
            Doctor = doctor,
            Vitals = vitals,
            EmrData = emrData
        };

        return View("PrintPrescription", vm);
    }

    [HttpPost]
    public async Task<IActionResult> SavePatientConsultation([FromBody] SaveConsultationRequest req)
    {
        if (req == null || req.OPDServiceId <= 0)
            return Json(new { success = false, message = "Invalid request payload." });

        var userId = User.GetUserId();
        
        // Pass userId into the request so the API knows who created/modified it
        req.RequestedByUserId = userId;

        var success = await emrConsultationApiClient.SaveConsultationAsync(req);

        if (!success)
        {
            return Json(new { success = false, message = "Failed to save EMR consultation." });
        }

        // Removed: Automatically marking consultation as Completed. 
        // The status should only be changed via the explicit "Complete" button on the queue list.

        await auditLogService.LogAsync("OPD", "EMR.SaveConsultation", 
            $"Saved consultation EMR for patient {req.PatientCode} (Service ID: {req.OPDServiceId})");

        return Json(new { success = true, message = "EMR consultation record saved successfully." });
    }

    // ─── Video Consultation: Create room on Full Payment ────────────────────────
    private void TriggerVideoOnFullPayment(int? branchId, int opdServiceId)
    {
        var scopeFactory = HttpContext.RequestServices.GetRequiredService<IServiceScopeFactory>();
        var activeBranchId = branchId ?? 1;

        _ = Task.Run(async () =>
        {
            try
            {
                using var scope = scopeFactory.CreateScope();
                var db = scope.ServiceProvider.GetRequiredService<ApplicationDbContext>();

                // Skip if a meeting was already created for this booking
                var alreadyExists = await db.VideoConsultations
                    .AnyAsync(v => v.OPDServiceId == opdServiceId && v.Status == "Scheduled");
                if (alreadyExists)
                {
                    Console.WriteLine($"[VIDEO-TRIGGER] Room already exists for OPDServiceId={opdServiceId}, skipping.");
                    return;
                }

                // Check if there is a Video consulting line item
                var videoServiceItem = await db.Database.GetDbConnection()
                    .QueryFirstOrDefaultAsync<(int ServiceId, string? ConsultingType)>(
                        @"SELECT i.ServiceId, s.ConsultingType
                          FROM PatientOPDServiceItem i
                          JOIN ServiceMaster s ON s.ServiceId = i.ServiceId
                          WHERE i.OPDServiceId = @OpdId AND s.ConsultingType = 'Video' AND i.IsActive = 1",
                        new { OpdId = opdServiceId });

                if (videoServiceItem.ServiceId <= 0)
                {
                    Console.WriteLine($"[VIDEO-TRIGGER] OPDServiceId={opdServiceId} has no Video line item, skipping.");
                    return;
                }

                var booking = await db.PatientOPDServices.AsNoTracking()
                    .FirstOrDefaultAsync(b => b.OPDServiceId == opdServiceId);

                if (booking == null)
                {
                    Console.WriteLine($"[VIDEO-TRIGGER] Booking {opdServiceId} not found.");
                    return;
                }

                Console.WriteLine($"[VIDEO-TRIGGER] Full payment confirmed for OPDServiceId={opdServiceId}. Creating Whereby room...");

                // Mark as 'Consulting' immediately so it appears on the Doctor Dashboard
                await db.Database.GetDbConnection().ExecuteAsync(
                    "UPDATE PatientOPDService SET Status = 'Consulting', ModifiedDate = GETDATE(), ModifiedBy = 'System (Video)' WHERE OPDServiceId = @OpdId", 
                    new { OpdId = opdServiceId });

                // Get slot end time from DoctorScheduleMaster, default +15 min if missing
                TimeSpan slotStartTime = booking.AppointmentTime ?? TimeSpan.Zero;
                TimeSpan slotEndTime = slotStartTime.Add(TimeSpan.FromMinutes(15));

                if (booking.ScheduleId.HasValue)
                {
                    var slotDuration = await db.Database.GetDbConnection()
                        .QueryFirstOrDefaultAsync<int?>(
                            "SELECT SlotDurationMinutes FROM DoctorScheduleMaster WHERE ScheduleId = @Id",
                            new { Id = booking.ScheduleId.Value });
                    if (slotDuration.HasValue && slotDuration.Value > 0)
                        slotEndTime = slotStartTime.Add(TimeSpan.FromMinutes(slotDuration.Value));
                }

                // Get grace time from DoctorConsultingFeeMap, fallback to config
                var graceTime = await db.Database.GetDbConnection()
                    .QueryFirstOrDefaultAsync<int?>(
                        @"SELECT TOP 1 GraceTime FROM DoctorConsultingFeeMap
                          WHERE DoctorId = @DoctorId AND ServiceId = @ServiceId AND IsActive = 1",
                        new { DoctorId = booking.ConsultingDoctorId ?? 0, ServiceId = videoServiceItem.ServiceId });

                if (!graceTime.HasValue || graceTime.Value <= 0)
                {
                    var cfgGrace = await db.VideoSystemConfigs
                        .Where(c => c.ConfigKey == "DefaultGraceMinutes" && c.IsActive)
                        .Select(c => c.ConfigValue)
                        .FirstOrDefaultAsync();
                    graceTime = int.TryParse(cfgGrace, out var g) ? g : 15;
                }

                var videoSvc = scope.ServiceProvider.GetRequiredService<IVideoConsultationService>();
                await videoSvc.CreateAndDispatchAsync(
                    opdServiceId     : opdServiceId,
                    doctorId         : booking.ConsultingDoctorId ?? 0,
                    patientId        : booking.PatientId,
                    appointmentDate  : booking.VisitDate.Date,
                    slotStartTime    : slotStartTime,
                    slotEndTime      : slotEndTime,
                    graceTimeMinutes : graceTime ?? 15,
                    branchId         : activeBranchId,
                    createdBy        : "System");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[VIDEO-TRIGGER] Error in TriggerVideoOnFullPayment: {ex}");
            }
        });
    }

    // ─── Email: Booking Confirmation ────────────────────────────────────────────
    private void TriggerBookingEmail(int? branchId, int opdServiceId, string hostUrl)
    {
        try
        {
            var scopeFactory = HttpContext.RequestServices.GetRequiredService<IServiceScopeFactory>();
            var activeBranchId = branchId ?? 1;

            _ = Task.Run(async () =>
            {
                try
                {
                    using var scope = scopeFactory.CreateScope();
                    var db = scope.ServiceProvider.GetRequiredService<ApplicationDbContext>();
                    
                    // Check if email notification is enabled for this branch
                    var settings = await db.HospitalSettings.AsNoTracking().FirstOrDefaultAsync(h => h.BranchId == activeBranchId);
                    if (settings != null && !settings.EmailNotificationRequired)
                    {
                        Console.WriteLine($"[DEBUG-EMAIL-TRIGGER] Email notifications disabled for Branch {activeBranchId}, skipping.");
                        return;
                    }
                    
                    // Fetch booking details (poll if token is not generated yet)
                    PatientOPDService? booking = null;
                    for (int i = 0; i < 6; i++)
                    {
                        booking = await db.PatientOPDServices
                            .AsNoTracking()
                            .FirstOrDefaultAsync(b => b.OPDServiceId == opdServiceId);

                        if (booking != null && !string.IsNullOrEmpty(booking.TokenNo))
                        {
                            Console.WriteLine($"[DEBUG-EMAIL-TRIGGER] Found TokenNo: '{booking.TokenNo}' at attempt {i + 1}");
                            break;
                        }

                        if (booking != null && booking.TotalAmount == 0)
                        {
                            // If total amount is 0, SP might not assign a token or it's processed. 
                            // Either way, if it's 0 and we waited once, we can proceed.
                            break;
                        }

                        Console.WriteLine($"[DEBUG-EMAIL-TRIGGER] TokenNo is null/empty at attempt {i + 1}. Waiting 3 seconds...");
                        await Task.Delay(3000);
                    }

                    if (booking == null)
                    {
                        Console.WriteLine($"[DEBUG-EMAIL-TRIGGER] Booking ID {opdServiceId} not found, skipping.");
                        return;
                    }

                    // Fetch patient details
                    var patient = await db.PatientMasters
                        .FirstOrDefaultAsync(p => p.PatientId == booking.PatientId);

                    if (patient == null)
                    {
                        Console.WriteLine($"[DEBUG-EMAIL-TRIGGER] Patient ID {booking.PatientId} not found, skipping.");
                        return;
                    }

                    var patientEmail = patient.EmailId;
                    var firstName = patient.FirstName;
                    var lastName = patient.LastName;

                    Console.WriteLine($"[DEBUG-EMAIL-TRIGGER] PatientId: {booking.PatientId}, Email: '{patientEmail}'");

                    // Note: Video Consultation room is created on FULL PAYMENT,
                    //       not at booking time. See TriggerVideoOnFullPayment().

                    if (string.IsNullOrWhiteSpace(patientEmail))
                    {
                        Console.WriteLine($"[DEBUG-EMAIL-TRIGGER] No email for PatientId: {booking.PatientId}, skipping booking confirmation email.");
                        return;
                    }

                    var template = await db.EmailTemplates
                        .FirstOrDefaultAsync(t => t.BranchId == activeBranchId && t.TemplateName == "Booking Confirmation" && t.IsActive);
                    
                    Console.WriteLine($"[DEBUG-EMAIL-TRIGGER] Template found for Branch {activeBranchId}: {template != null}");

                    if (template != null)
                    {
                        var doctorName = await db.Database.GetDbConnection().QueryFirstOrDefaultAsync<string>(
                            "SELECT FullName FROM DoctorMaster WHERE DoctorId = @Id", new { Id = booking.ConsultingDoctorId });
                        var hospital = await db.HospitalSettings.FirstOrDefaultAsync(h => h.BranchId == activeBranchId);
                        var hospitalName = hospital?.HospitalName ?? "Our Hospital";

                        var subject = template.Subject.Replace("{{HospitalName}}", hospitalName);
                        
                        var slotTimeStr = booking.AppointmentTime.HasValue 
                            ? DateTime.Today.Add(booking.AppointmentTime.Value).ToString("hh:mm tt") 
                            : "N/A";

                        var htmlBody = template.HtmlBody
                            .Replace("{{PatientName}}", $"{firstName} {lastName}")
                            .Replace("{{DoctorName}}", doctorName ?? "")
                            .Replace("{{TokenNo}}", booking.TokenNo ?? "Pending")
                            .Replace("{{TotalAmount}}", booking.TotalAmount?.ToString("0.00") ?? "0.00")
                            .Replace("{{VisitDate}}", booking.VisitDate.ToString("dd-MMM-yyyy"))
                            .Replace("{{SlotTime}}", slotTimeStr)
                            .Replace("{{HospitalName}}", hospitalName);

                        List<System.Net.Mail.Attachment> attachments = new();
                        string? tempPdfPath = null;

                        // Check if booking is fully paid (meaning TokenNo is generated/assigned)
                        if (!string.IsNullOrEmpty(booking.TokenNo))
                        {
                            try
                            {
                                var secret = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes($"bill-{opdServiceId}-emr"));
                                var billUrl = $"{hostUrl}/OPD/PrintBillAnonymous?id={opdServiceId}&secret={Uri.EscapeDataString(secret)}";
                                
                                var safeBillNo = booking.OPDBillNo ?? opdServiceId.ToString();
                                tempPdfPath = Path.Combine(Path.GetTempPath(), $"OPD_Bill_{safeBillNo}.pdf");

                                Console.WriteLine($"[DEBUG-EMAIL-TRIGGER] Generating PDF for fully paid bill. URL: {billUrl}, Output: {tempPdfPath}");

                                var chromeArgs = $"--headless --disable-gpu --ignore-certificate-errors --print-to-pdf=\"{tempPdfPath}\" \"{billUrl}\"";
                                var processInfo = new System.Diagnostics.ProcessStartInfo("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", chromeArgs)
                                {
                                    CreateNoWindow = true,
                                    UseShellExecute = false
                                };
                                using var process = System.Diagnostics.Process.Start(processInfo);
                                if (process != null)
                                {
                                    await process.WaitForExitAsync();
                                }

                                if (System.IO.File.Exists(tempPdfPath))
                                {
                                    var attachment = new System.Net.Mail.Attachment(tempPdfPath, "application/pdf");
                                    attachments.Add(attachment);
                                    Console.WriteLine($"[DEBUG-EMAIL-TRIGGER] PDF generated and attached successfully: {tempPdfPath}");
                                }
                                else
                                {
                                    Console.WriteLine($"[DEBUG-EMAIL-TRIGGER] PDF generation failed, file does not exist: {tempPdfPath}");
                                }
                            }
                            catch (Exception pdfEx)
                            {
                                Console.WriteLine($"[DEBUG-EMAIL-TRIGGER] Error generating PDF attachment: {pdfEx}");
                            }
                        }

                        var emailSvc = scope.ServiceProvider.GetRequiredService<IEmailService>();
                        await emailSvc.SendEmailAsync(activeBranchId, patientEmail, subject, htmlBody, attachments.Any() ? attachments : null);
                        Console.WriteLine($"[DEBUG-EMAIL-TRIGGER] Email sent to {patientEmail} successfully.");

                        // Clean up temporary PDF file after email is sent
                        if (!string.IsNullOrEmpty(tempPdfPath) && System.IO.File.Exists(tempPdfPath))
                        {
                            try
                            {
                                foreach (var att in attachments)
                                {
                                    att.Dispose();
                                }
                                System.IO.File.Delete(tempPdfPath);
                                Console.WriteLine($"[DEBUG-EMAIL-TRIGGER] Temporary PDF deleted: {tempPdfPath}");
                            }
                            catch (Exception deleteEx)
                            {
                                Console.WriteLine($"[DEBUG-EMAIL-TRIGGER] Failed to delete temporary PDF file: {deleteEx}");
                            }
                        }
                    }
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"Error sending booking email: {ex}");
                }
            });
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error scheduling booking email: {ex}");
        }
    }
    private async Task TryGeneratePatientLoginAsync(int patientId, string patientCode, string phone, string email, string name, int branchId)
    {
        if (string.IsNullOrWhiteSpace(phone) || string.IsNullOrWhiteSpace(email))
            return;

        var isAlreadyGenerated = await dbContext.PatientMasters
            .Where(p => p.PatientId == patientId)
            .Select(p => p.IsLoginGenerated)
            .FirstOrDefaultAsync();

        if (isAlreadyGenerated)
            return;


        TriggerPatientLoginEmail(branchId, patientId, patientCode, name, email);
    }

    // ─── Email: Patient Login Credential ────────────────────────────────────────────
    private void TriggerPatientLoginEmail(int activeBranchId, int patientId, string patientCode, string patientName, string patientEmail)
    {
        try
        {
            var scopeFactory = HttpContext.RequestServices.GetRequiredService<IServiceScopeFactory>();

            _ = Task.Run(async () =>
            {
                try
                {
                    using var scope = scopeFactory.CreateScope();
                    var db = scope.ServiceProvider.GetRequiredService<ApplicationDbContext>();
                    var emailSvc = scope.ServiceProvider.GetRequiredService<IEmailService>();
                    var passwordHasher = scope.ServiceProvider.GetRequiredService<IPasswordHasherService>();

                    // Generate Password
                    var password = $"{patientCode}{DateTime.Now.Year}";
                    var (Hash, Salt) = passwordHasher.HashPassword(password);

                    // Update DB directly
                    var rowsAffected = await db.Database.GetDbConnection().ExecuteAsync(
                        @"UPDATE PatientMaster 
                          SET IsLoginGenerated = 1, PasswordHash = @Hash, Salt = @Salt, IsPasswordchanged = 0 
                          WHERE PatientId = @Id AND IsLoginGenerated = 0",
                        new { Hash, Salt, Id = patientId }
                    );

                    if (rowsAffected > 0)
                    {
                        var hospital = await db.HospitalSettings.FirstOrDefaultAsync(h => h.BranchId == activeBranchId);
                        var hospitalName = hospital?.HospitalName ?? "Our Hospital";

                        var subject = $"Welcome to {hospitalName} - Your Login Credentials";
                        var htmlBody = $@"
                        <div style='font-family: ""Helvetica Neue"", Helvetica, Arial, sans-serif; max-width: 600px; margin: 40px auto; background-color: #ffffff; border: 1px solid #e0e0e0; border-radius: 8px; overflow: hidden; box-shadow: 0 4px 10px rgba(0,0,0,0.05);'>
                            
                            <!-- Header -->
                            <div style='background-color: #0056b3; padding: 30px; text-align: center;'>
                                <h1 style='color: #ffffff; margin: 0; font-size: 24px; font-weight: 600; letter-spacing: 0.5px;'>Welcome to {hospitalName}</h1>
                            </div>
                            
                            <!-- Body -->
                            <div style='padding: 40px 30px;'>
                                <h2 style='color: #333333; font-size: 20px; margin-top: 0;'>Dear {patientName},</h2>
                                <p style='color: #555555; font-size: 16px; line-height: 1.6; margin-bottom: 25px;'>
                                    Thank you for registering with us! We have successfully created a secure patient portal account for you. You can use this account to book appointments, view your health records, and stay connected with our care team.
                                </p>
                                
                                <div style='background-color: #f4f7f6; border-left: 4px solid #0056b3; padding: 20px; border-radius: 4px; margin: 30px 0;'>
                                    <h3 style='color: #333333; margin-top: 0; margin-bottom: 15px; font-size: 16px; text-transform: uppercase; letter-spacing: 1px;'>Your Login Credentials</h3>
                                    <table style='width: 100%; border-collapse: collapse;'>
                                        <tr>
                                            <td style='padding: 8px 0; color: #555555; width: 100px;'><strong>Username:</strong></td>
                                            <td style='padding: 8px 0; color: #333333; font-size: 16px; font-weight: 600;'>{patientEmail}</td>
                                        </tr>
                                        <tr>
                                            <td style='padding: 8px 0; color: #555555;'><strong>Password:</strong></td>
                                            <td style='padding: 8px 0; color: #333333; font-size: 16px; font-weight: 600;'>{password}</td>
                                        </tr>
                                    </table>
                                </div>
                                
                                <p style='color: #555555; font-size: 15px; line-height: 1.5; margin-bottom: 0;'>
                                    <em>For security purposes, we strongly recommend changing your password immediately after your first login.</em>
                                </p>
                            </div>
                            
                            <!-- Footer -->
                            <div style='background-color: #f9f9f9; padding: 20px 30px; text-align: center; border-top: 1px solid #eeeeee;'>
                                <p style='color: #999999; font-size: 12px; margin: 0; line-height: 1.5;'>
                                    This is an automated message generated by {hospitalName}.<br>
                                    Please do not reply directly to this email.
                                </p>
                            </div>
                        </div>";

                        await emailSvc.SendEmailAsync(activeBranchId, patientEmail, subject, htmlBody);
                        Console.WriteLine($"[DEBUG-LOGIN-EMAIL] Sent login credentials to PatientId: {patientId}, Email: {patientEmail}");
                    }
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"[DEBUG-LOGIN-EMAIL] Error generating/sending login credentials: {ex}");
                }
            });
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[DEBUG-LOGIN-EMAIL] Error in TriggerPatientLoginEmail setup: {ex}");
        }
    }
}

public class SaveConsultationRequest
{
    public int OPDServiceId { get; set; }
    public int PatientId { get; set; }
    public int DoctorId { get; set; }
    public int TemplateId { get; set; }
    public string OPDBillNo { get; set; } = string.Empty;
    public string PatientCode { get; set; } = string.Empty;
    public string PatientName { get; set; } = string.Empty;
    public string? Gender { get; set; }
    public string? Age { get; set; }
    public string? MobileNumber { get; set; }
    public string VisitType { get; set; } = "New";
    public string ConsultationType { get; set; } = string.Empty;
    public string EmrDataJson { get; set; } = string.Empty;
    public int RequestedByUserId { get; set; }
}
