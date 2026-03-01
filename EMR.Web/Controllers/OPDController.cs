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
    IDoctorConsultingFeeService consultingFeeService,
    ICountryService countryService,
    IStateService stateService,
    IDistrictService districtService,
    ICityService cityService,
    IAreaService areaService,
    IAuditLogService auditLogService,
    ApplicationDbContext dbContext,
    IWebHostEnvironment env) : Controller
{
    // ─── Index (patient list) ─────────────────────────────────────────────────

    public async Task<IActionResult> Index()
    {
        var branchId = User.GetCurrentBranchId();
        var patients = await patientService.GetListForBranchAsync(branchId);
        ViewData["Title"] = "Patient List";
        return View(patients);
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
            // Direct-edit via list: demographics only — no OPD service data loaded
            model.DemographicsOnly = true;
        }
        else
        {
            model = new PatientRegistrationViewModel();
        }

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

        var patient = MapViewModelToPatient(model);
        patient.BranchId = branchId;

        if (model.PatientId == 0)   // CREATE — new patient + first OPD visit
        {
            var opdService = MapViewModelToOPDService(model);
            opdService.BranchId = branchId;
            var patientCode = await patientService.CreateAsync(patient, opdService, User.GetUserId());
            await auditLogService.LogAsync("OPD", "Patient.Create",
                $"Registered patient: {patient.FirstName} {patient.LastName} ({patientCode})");

            TempData["NewPatientCode"] = patientCode;
            TempData["NewPatientName"] = ((patient.Salutation ?? "") + " " + patient.FirstName + " " + patient.LastName).Trim();
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
                // Edit via Patient List — update demographics only, no OPD service touched
                await patientService.UpdateDemographicsAsync(patient, User.GetUserId());
                await auditLogService.LogAsync("OPD", "Patient.UpdateDemographics",
                    $"Updated demographics: {patient.PatientId} - {patient.FirstName} {patient.LastName}");
                TempData["Success"] = $"Patient {patient.PatientCode} updated successfully.";
                return RedirectToAction(nameof(Index));
            }

            // Search-loaded patient (new visit booking)
            var opdService = MapViewModelToOPDService(model);
            opdService.BranchId  = branchId;
            opdService.PatientId = model.PatientId;
            await patientService.UpdateAsync(patient, opdService, User.GetUserId());

            var action = model.OPDServiceId == 0 ? "Patient.NewVisit" : "Patient.Update";
            await auditLogService.LogAsync("OPD", action,
                $"{(model.OPDServiceId == 0 ? "New visit" : "Updated")} patient: {patient.PatientId} - {patient.FirstName} {patient.LastName}");

            if (model.OPDServiceId == 0)   // new visit for returning patient
            {
                TempData["NewPatientCode"] = patient.PatientCode;
                TempData["NewPatientName"] = ((patient.Salutation ?? "") + " " + patient.FirstName + " " + patient.LastName).Trim();
                TempData["IsBooking"]      = true;
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

    // ─── Service Booking (placeholder) ────────────────────────────────────────

    public IActionResult ServiceBooking()
    {
        ViewData["Title"] = "Service Booking";
        return View();
    }

    // ─── AJAX APIs ────────────────────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> SearchPatientByPhone(string phone)
    {
        if (string.IsNullOrWhiteSpace(phone) || phone.Length < 3)
            return Json(Array.Empty<object>());
        var results = await patientService.SearchByPhoneAsync(phone.Trim());
        return Json(results);
    }

    [HttpGet]
    public async Task<IActionResult> SearchPatientByCode(string code)
    {
        if (string.IsNullOrWhiteSpace(code) || code.Length < 2)
            return Json(Array.Empty<object>());
        var results = await patientService.SearchByCodeAsync(code.Trim());
        return Json(results);
    }

    [HttpGet]
    public async Task<IActionResult> GetPatientDetails(int id)
    {
        var patient = await patientService.GetByIdAsync(id);
        if (patient is null) return NotFound();
        var svc = await patientService.GetLatestOPDServiceAsync(id);
        return Json(new
        {
            // Patient demographics
            patient.PatientId, patient.PatientCode, patient.PhoneNumber, patient.SecondaryPhoneNumber,
            patient.Salutation, patient.FirstName, patient.MiddleName, patient.LastName,
            patient.Gender, patient.ReligionId, patient.EmailId, patient.GuardianName,
            patient.CountryId, patient.StateId, patient.DistrictId, patient.CityId, patient.AreaId,
            patient.IdentificationTypeId, patient.IdentificationNumber, patient.IdentificationFilePath,
            patient.OccupationId, patient.MaritalStatusId, patient.BloodGroup,
            patient.KnownAllergies, patient.Remarks,
            // Latest OPD service (null-safe)
            OPDServiceId       = svc?.OPDServiceId,
            ConsultingDoctorId = svc?.ConsultingDoctorId,
            ServiceType        = svc?.ServiceType,
            ServiceId          = svc?.ServiceId,
            ServiceCharges     = svc?.ServiceCharges
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
        ReligionId            = m.ReligionId,
        EmailId               = m.EmailId?.Trim(),
        GuardianName          = m.GuardianName?.Trim(),
        CountryId             = m.CountryId,
        StateId               = m.StateId,
        DistrictId            = m.DistrictId,
        CityId                = m.CityId,
        AreaId                = m.AreaId,
        IdentificationTypeId  = m.IdentificationTypeId,
        IdentificationNumber  = m.IdentificationNumber?.Trim(),
        IdentificationFilePath= m.IdentificationFilePath,
        OccupationId          = m.OccupationId,
        MaritalStatusId       = m.MaritalStatusId,
        BloodGroup            = m.BloodGroup,
        KnownAllergies        = m.KnownAllergies?.Trim(),
        Remarks               = m.Remarks?.Trim(),
    };

    private static PatientOPDService MapViewModelToOPDService(PatientRegistrationViewModel m) => new()
    {
        OPDServiceId       = m.OPDServiceId,
        PatientId          = m.PatientId,
        ConsultingDoctorId = m.ConsultingDoctorId,
        ServiceType        = m.ServiceType,
        ServiceId          = m.ServiceId,
        ServiceCharges     = m.ServiceCharges,
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
        ReligionId            = p.ReligionId,
        EmailId               = p.EmailId,
        GuardianName          = p.GuardianName,
        CountryId             = p.CountryId,
        StateId               = p.StateId,
        DistrictId            = p.DistrictId,
        CityId                = p.CityId,
        AreaId                = p.AreaId,
        IdentificationTypeId  = p.IdentificationTypeId,
        IdentificationNumber  = p.IdentificationNumber,
        IdentificationFilePath= p.IdentificationFilePath,
        OccupationId          = p.OccupationId,
        MaritalStatusId       = p.MaritalStatusId,
        BloodGroup            = p.BloodGroup,
        KnownAllergies        = p.KnownAllergies,
        Remarks               = p.Remarks,
    };

    private static void MapOPDServiceToViewModel(PatientOPDService svc, PatientRegistrationViewModel m)
    {
        m.OPDServiceId       = svc.OPDServiceId;
        m.ConsultingDoctorId = svc.ConsultingDoctorId;
        m.ServiceType        = svc.ServiceType;
        m.ServiceId          = svc.ServiceId;
        m.ServiceCharges     = svc.ServiceCharges;
    }
}
