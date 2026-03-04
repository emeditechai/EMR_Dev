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
    IDoctorConsultingFeeService consultingFeeService,
    ICountryService countryService,
    IStateService stateService,
    IDistrictService districtService,
    ICityService cityService,
    IAreaService areaService,
    IAuditLogService auditLogService,
    IPaymentService paymentService,
    ApplicationDbContext dbContext,
    IWebHostEnvironment env) : Controller
{
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
    public async Task<IActionResult> PatientRegistration(int? id)
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
                RelationId = 1   // default: Self
            };
        }

        // Pass bill/token info for success modal after redirect
        model.OPDBillNo       = TempData["OPDBillNo"]       as string;
        model.TokenNo         = TempData["TokenNo"]         as string;
        model.NewOPDServiceId = int.TryParse(TempData["NewOPDServiceId"] as string, out var sid) ? sid : null;

        await PopulateSelectLists(model);
        return View(model);
    }

    // ─── Patient Registration (POST – Create / Update) ────────────────────────

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> PatientRegistration(PatientRegistrationViewModel model, IFormFile? identificationFile)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null)
        {
            TempData["Error"] = "Please select a branch first.";
            return RedirectToAction("SelectBranch", "Account");
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

        var patient = MapViewModelToPatient(model);
        patient.BranchId = branchId;

        if (model.PatientId == 0)   // CREATE — new patient + first OPD visit
        {
            var opdBill = MapViewModelToOPDBill(model);
            opdBill.BranchId = branchId;
            var (patientCode, billNo, tokenNo, _, newSvcId) = await patientService.CreateAsync(
                patient, opdBill, model.LineItemsJson, User.GetUserId());
            await auditLogService.LogAsync("OPD", "Patient.Create",
                $"Registered patient: {patient.FirstName} {patient.LastName} ({patientCode}) Bill:{billNo}");

            TempData["NewPatientCode"]  = patientCode;
            TempData["NewPatientName"]  = ((patient.Salutation ?? "") + " " + patient.FirstName + " " + patient.LastName).Trim();
            TempData["OPDBillNo"]       = billNo;
            TempData["TokenNo"]         = tokenNo;
            TempData["NewOPDServiceId"] = newSvcId.ToString();
            return RedirectToAction(nameof(PatientRegistration), new { registered = true });
        }
        else   // UPDATE — existing patient
        {
            if (string.IsNullOrWhiteSpace(model.IdentificationFilePath))
            {
                var existing = await patientService.GetByIdAsync(model.PatientId);
                patient.IdentificationFilePath = existing?.IdentificationFilePath;
            }

            if (model.DemographicsOnly)
            {
                // Edit via Patient List — update demographics only, no OPD bill touched
                await patientService.UpdateDemographicsAsync(patient, User.GetUserId());
                await auditLogService.LogAsync("OPD", "Patient.UpdateDemographics",
                    $"Updated demographics: {patient.PatientId} - {patient.FirstName} {patient.LastName}");
                TempData["Success"] = $"Patient {patient.PatientCode} updated successfully.";
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
                TempData["NewPatientCode"]  = patient.PatientCode;
                TempData["NewPatientName"]  = ((patient.Salutation ?? "") + " " + patient.FirstName + " " + patient.LastName).Trim();
                TempData["OPDBillNo"]       = billNo;
                TempData["TokenNo"]         = tokenNo;
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

    // ─── Service Booking List ──────────────────────────────────────────────────

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
    public async Task<IActionResult> NewServiceBooking()
    {
        ViewData["Title"] = "New Service Booking";
        var model = new PatientRegistrationViewModel { DemographicsOnly = false };
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
        TempData["TokenNo"]        = tokenNo;
        TempData["NewPatientCode"] = model.PatientCode;
        TempData["NewPatientName"] = $"{model.FirstName} {model.LastName}".Trim();
        TempData["IsBooking"]      = true;
        TempData["NewOPDServiceId"] = newSvcId.ToString();

        await auditLogService.LogAsync("OPD", "ServiceBooking.New",
            $"New booking for patient {model.PatientCode} — Bill {billNo}, Token {tokenNo}");

        return RedirectToAction(nameof(ServiceBooking));
    }

    // ─── AJAX APIs ────────────────────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> SearchPatientByPhone(string phone)
    {
        if (string.IsNullOrWhiteSpace(phone) || phone.Length < 3)
            return Json(Array.Empty<object>());
        var branchId = User.GetCurrentBranchId();
        var results = await patientService.SearchByPhoneAsync(phone.Trim(), branchId);
        return Json(results);
    }

    [HttpGet]
    public async Task<IActionResult> SearchPatientByCode(string code)
    {
        if (string.IsNullOrWhiteSpace(code) || code.Length < 2)
            return Json(Array.Empty<object>());
        var branchId = User.GetCurrentBranchId();
        var results = await patientService.SearchByCodeAsync(code.Trim(), branchId);
        return Json(results);
    }

    [HttpGet]
    public async Task<IActionResult> SearchPatientByName(string name)
    {
        if (string.IsNullOrWhiteSpace(name) || name.Length < 2)
            return Json(Array.Empty<object>());
        var branchId = User.GetCurrentBranchId();
        var results = await patientService.SearchByNameAsync(name.Trim(), branchId);
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
        return Json(services.Select(s => new { s.ServiceId, s.ItemName, s.ItemCharges }));
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
                TotalAmount          = apiDetail.TotalAmount,
                Status               = apiDetail.Status,
                Items                = apiDetail.Items.Select(i => new ServiceBookingDetailItem
                {
                    ServiceType    = i.ServiceType,
                    ItemName       = i.ItemName,
                    ServiceCharges = i.ServiceCharges
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
    }

    private static PatientMaster MapViewModelToPatient(PatientRegistrationViewModel m) => new()
    {
        PatientId             = m.PatientId,
        PatientCode           = m.PatientCode ?? string.Empty,
        PhoneNumber           = m.PhoneNumber.Trim(),
        SecondaryPhoneNumber  = m.SecondaryPhoneNumber?.Trim(),
        Salutation            = m.Salutation,
        FirstName             = m.FirstName.Trim(),
        MiddleName            = m.MiddleName?.Trim(),
        LastName              = m.LastName.Trim(),
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
        OccupationId          = m.OccupationId,
        MaritalStatusId       = m.MaritalStatusId,
        BloodGroup            = m.BloodGroup,
        KnownAllergies        = m.KnownAllergies?.Trim(),
        Remarks               = m.Remarks?.Trim(),
    };

    private static PatientOPDService MapViewModelToOPDBill(PatientRegistrationViewModel m) => new()
    {
        OPDServiceId       = m.OPDServiceId,
        PatientId          = m.PatientId,
        ConsultingDoctorId = m.ConsultingDoctorId,
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
        OccupationId          = p.OccupationId,
        MaritalStatusId       = p.MaritalStatusId,
        BloodGroup            = p.BloodGroup,
        KnownAllergies        = p.KnownAllergies,
        Remarks               = p.Remarks,
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
        var summary = await paymentService.GetPaymentSummaryAsync(moduleCode, moduleRefId);
        if (summary is null)
            return Json(new { success = false, error = "Bill not found." });
        return Json(new { success = true, data = summary });
    }

    [HttpPost]
    public async Task<IActionResult> SavePayment([FromBody] SavePaymentRequest request)
    {
        if (!ModelState.IsValid)
            return Json(new SavePaymentResult { Success = false, Error = "Invalid request." });

        var userId = User.GetUserId();
        var result = await paymentService.SavePaymentAsync(request, userId);
        return Json(result);
    }
}
