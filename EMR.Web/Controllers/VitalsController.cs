using EMR.Web.ApiClients;
using EMR.Web.ApiClients.Models;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class VitalsController(
    IVitalApiClient   vitalApiClient,
    IPatientApiClient patientApiClient) : Controller
{
    // ─── Index: patient search landing page ───────────────────────────────────

    public IActionResult Index()
    {
        ViewData["Title"] = "Patient Vitals";
        return View();
    }

    // ─── RecordVital GET — search + entry form ────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> RecordVital(int? patientId, int? editId)
    {
        ViewData["Title"] = editId.HasValue ? "Edit Vital Record" : "Record New Vitals";
        var model = new VitalEntryViewModel();

        try
        {
            if (editId.HasValue)
            {
                var existing = await vitalApiClient.GetByIdAsync(editId.Value);
                if (existing is null) return NotFound();

                model     = MapRowToViewModel(existing);
                patientId = existing.PatientId;
            }

            if (patientId.HasValue && patientId.Value > 0)
            {
                var patient = await patientApiClient.GetByIdAsync(patientId.Value);
                if (patient is not null)
                    PopulatePatientContext(model, patient);
            }
        }
        catch (HttpRequestException) { return ApiDown(Request.Path); }

        return View(model);
    }

    // ─── RecordVital POST — save ──────────────────────────────────────────────

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> RecordVital(VitalEntryViewModel model, string? returnAction)
    {
        // At least one vital must be entered
        if (!HasAnyVital(model))
            ModelState.AddModelError(string.Empty, "Please enter at least one vital measurement.");

        // BP cross-field validation
        if (model.BPSystolic.HasValue && model.BPDiastolic.HasValue
            && model.BPSystolic <= model.BPDiastolic)
            ModelState.AddModelError("BPDiastolic", "Diastolic must be less than Systolic BP.");

        var userId = User.GetUserId();

        if (!ModelState.IsValid)
        {
            try
            {
                if (model.PatientId > 0)
                {
                    var patient = await patientApiClient.GetByIdAsync(model.PatientId);
                    if (patient is not null) PopulatePatientContext(model, patient);
                }
            }
            catch (HttpRequestException) { return ApiDown(Request.Path); }
            ViewData["Title"] = model.PatientVitalId > 0 ? "Edit Vital Record" : "Record New Vitals";
            return View(model);
        }

        try
        {
            if (model.PatientVitalId > 0)
            {
                await vitalApiClient.UpdateAsync(new VitalUpdateRequest
                {
                    PatientVitalId  = model.PatientVitalId,
                    Height          = model.Height,
                    Weight          = model.Weight,
                    BPSystolic      = model.BPSystolic,
                    BPDiastolic     = model.BPDiastolic,
                    PulseRate       = model.PulseRate,
                    SpO2            = model.SpO2,
                    Temperature     = model.Temperature,
                    RespiratoryRate = model.RespiratoryRate,
                    BloodGlucose    = model.BloodGlucose,
                    GlucoseType     = model.GlucoseType,
                    PainScore       = model.PainScore,
                    Notes           = model.Notes,
                    UpdatedByUserId = userId
                });
            }
            else
            {
                await vitalApiClient.CreateAsync(new VitalCreateRequest
                {
                    PatientId        = model.PatientId,
                    Height           = model.Height,
                    Weight           = model.Weight,
                    BPSystolic       = model.BPSystolic,
                    BPDiastolic      = model.BPDiastolic,
                    PulseRate        = model.PulseRate,
                    SpO2             = model.SpO2,
                    Temperature      = model.Temperature,
                    RespiratoryRate  = model.RespiratoryRate,
                    BloodGlucose     = model.BloodGlucose,
                    GlucoseType      = model.GlucoseType,
                    PainScore        = model.PainScore,
                    Notes            = model.Notes,
                    RecordedByUserId = userId
                });
            }
        }
        catch (HttpRequestException) { return ApiDown(Request.Path); }

        TempData["VitalSuccess"] = model.PatientVitalId > 0
            ? "Vital record updated."
            : "Vital recorded successfully.";

        if (returnAction == "another")
            return RedirectToAction(nameof(RecordVital), new { patientId = model.PatientId });

        return RedirectToAction(nameof(History), new { patientId = model.PatientId });
    }

    // ─── History ──────────────────────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> History(int patientId, int page = 1, int pageSize = 10)
    {
        try
        {
            var patient = await patientApiClient.GetByIdAsync(patientId);
            if (patient is null) return NotFound();

            var result = await vitalApiClient.GetHistoryAsync(patientId, page, pageSize);

            var vm = new VitalIndexViewModel
            {
                PatientId         = patient.PatientId,
                PatientCode       = patient.PatientCode,
                PatientFullName   = patient.FullName,
                PatientAge        = CalcAge(patient.DateOfBirth),
                PatientGender     = patient.Gender,
                PatientBloodGroup = patient.BloodGroup,
                PatientPhone      = patient.PhoneNumber,
                Vitals            = result.Rows.Select(MapRowToHistoryRow).ToList(),
                TotalCount        = result.TotalCount,
                Page              = page,
                PageSize          = pageSize
            };

            ViewData["Title"] = $"Vital History — {vm.PatientFullName}";
            return View(vm);
        }
        catch (HttpRequestException) { return ApiDown(Request.Path); }
    }

    // ─── PrintVital — standalone print page ─────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> PrintVital(int patientId)
    {
        try
        {
        var branchId = User.GetCurrentBranchId();
        var data     = await vitalApiClient.GetPrintDataAsync(patientId, branchId);

        if (data?.Patient is null) return NotFound();

        var pt = data.Patient;
        var hs = data.Hospital;

        var phones = string.Join(" / ",
            new[] { hs?.ContactNumber1, hs?.ContactNumber2 }
                .Where(p => !string.IsNullOrWhiteSpace(p)));

        var vm = new VitalPrintViewModel
        {
            HospitalName      = hs?.HospitalName ?? "Hospital",
            HospitalAddress   = hs?.Address,
            HospitalPhone     = phones,
            HospitalEmail     = hs?.EmailAddress,
            HospitalWebsite   = hs?.Website,
            HospitalLogo      = hs?.LogoPath,
            PatientId         = pt.PatientId,
            PatientCode       = pt.PatientCode,
            PatientFullName   = pt.FullName,
            PatientAge        = CalcAge(pt.DateOfBirth),
            PatientGender     = pt.Gender,
            PatientBloodGroup = pt.BloodGroup,
            PatientAddress    = pt.Address,
            PatientPhone      = pt.PhoneNumber,
            LastOpdBillNo     = data.LastOpdBillNo,
            Vital             = data.LatestVital is not null
                                ? MapRowToHistoryRow(data.LatestVital)
                                : null
        };

        return View(vm);
        }
        catch (HttpRequestException) { return ApiDown(Request.Path); }
    }

    // ─── GetLatest — JSON for inline dashboard/OPD card ──────────────────────

    [HttpGet]
    public async Task<IActionResult> GetLatest(int patientId)
    {
        try
        {
            var v = await vitalApiClient.GetLatestAsync(patientId);
            if (v is null) return Json(new { found = false });

            return Json(new
            {
                found           = true,
                recordedOn      = v.RecordedOn.ToString("dd MMM yyyy HH:mm"),
                height          = v.Height,
                weight          = v.Weight,
                bmi             = v.BMI,
                bmiCategory     = v.BMICategory,
                bpSystolic      = v.BPSystolic,
                bpDiastolic     = v.BPDiastolic,
                pulseRate       = v.PulseRate,
                spO2            = v.SpO2,
                temperature     = v.Temperature,
                respiratoryRate = v.RespiratoryRate,
                bloodGlucose    = v.BloodGlucose,
                glucoseType     = v.GlucoseType,
                painScore       = v.PainScore
            });
        }
        catch (HttpRequestException) { return StatusCode(503, new { apiDown = true }); }
    }

    // ─── Delete ───────────────────────────────────────────────────────────────

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int vitalId, int patientId)
    {
        try
        {
            await vitalApiClient.DeleteAsync(vitalId, User.GetUserId());
            TempData["VitalSuccess"] = "Record deleted.";
        }
        catch (HttpRequestException) { return ApiDown(Request.Path); }
        return RedirectToAction(nameof(History), new { patientId });
    }

    // ─── Patient search JSON — all via API, no direct DB ─────────────────────

    [HttpGet]
    public async Task<IActionResult> SearchPatientByPhone(string phone)
    {
        if (string.IsNullOrWhiteSpace(phone) || phone.Length < 2)
            return Json(Array.Empty<object>());
        try
        {
            var branchId = User.GetCurrentBranchId();
            var result   = await patientApiClient.GetByBranchAsync(branchId, 1, 10, phone.Trim());
            return Json(result.Items);
        }
        catch (HttpRequestException) { return StatusCode(503, new { apiDown = true }); }
    }

    [HttpGet]
    public async Task<IActionResult> SearchPatientByCode(string code)
    {
        if (string.IsNullOrWhiteSpace(code) || code.Length < 2)
            return Json(Array.Empty<object>());
        try
        {
            var branchId = User.GetCurrentBranchId();
            var result   = await patientApiClient.GetByBranchAsync(branchId, 1, 10, code.Trim());
            return Json(result.Items);
        }
        catch (HttpRequestException) { return StatusCode(503, new { apiDown = true }); }
    }

    [HttpGet]
    public async Task<IActionResult> SearchPatientByName(string name)
    {
        if (string.IsNullOrWhiteSpace(name) || name.Length < 2)
            return Json(Array.Empty<object>());
        try
        {
            var branchId = User.GetCurrentBranchId();
            var result   = await patientApiClient.GetByBranchAsync(branchId, 1, 10, name.Trim());
            return Json(result.Items);
        }
        catch (HttpRequestException) { return StatusCode(503, new { apiDown = true }); }
    }

    [HttpGet]
    public async Task<IActionResult> GetPatientDetails(int id)
    {
        try
        {
            var p = await patientApiClient.GetByIdAsync(id);
            if (p is null) return NotFound();
            return Json(p);
        }
        catch (HttpRequestException) { return StatusCode(503, new { apiDown = true }); }
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    private static void PopulatePatientContext(VitalEntryViewModel m, PatientDetail p)
    {
        m.PatientId         = p.PatientId;
        m.PatientCode       = p.PatientCode;
        m.PatientFullName   = p.FullName;
        m.PatientAge        = CalcAge(p.DateOfBirth);
        m.PatientGender     = p.Gender;
        m.PatientBloodGroup = p.BloodGroup;
        m.PatientPhone      = p.PhoneNumber;
        m.PatientAddress    = p.Address;
    }

    private static VitalEntryViewModel MapRowToViewModel(VitalRow v) => new()
    {
        PatientVitalId  = v.PatientVitalId,
        PatientId       = v.PatientId,
        Height          = v.Height,
        Weight          = v.Weight,
        BMI             = v.BMI,
        BMICategory     = v.BMICategory,
        BPSystolic      = v.BPSystolic,
        BPDiastolic     = v.BPDiastolic,
        PulseRate       = v.PulseRate,
        SpO2            = v.SpO2,
        Temperature     = v.Temperature,
        RespiratoryRate = v.RespiratoryRate,
        BloodGlucose    = v.BloodGlucose,
        GlucoseType     = v.GlucoseType,
        PainScore       = v.PainScore,
        Notes           = v.Notes
    };

    private static VitalHistoryRow MapRowToHistoryRow(VitalRow v) => new()
    {
        PatientVitalId  = v.PatientVitalId,
        PatientId       = v.PatientId,
        Height          = v.Height,
        Weight          = v.Weight,
        BMI             = v.BMI,
        BMICategory     = v.BMICategory,
        BPSystolic      = v.BPSystolic,
        BPDiastolic     = v.BPDiastolic,
        PulseRate       = v.PulseRate,
        SpO2            = v.SpO2,
        Temperature     = v.Temperature,
        RespiratoryRate = v.RespiratoryRate,
        BloodGlucose    = v.BloodGlucose,
        GlucoseType     = v.GlucoseType,
        PainScore       = v.PainScore,
        Notes           = v.Notes,
        RecordedOn      = v.RecordedOn,
        RecordedByName  = v.RecordedByName,
        TotalCount      = v.TotalCount,
        CanModify       = v.CanModify
    };

    private static bool HasAnyVital(VitalEntryViewModel m) =>
        m.Height.HasValue || m.Weight.HasValue ||
        m.BPSystolic.HasValue || m.BPDiastolic.HasValue || m.PulseRate.HasValue ||
        m.SpO2.HasValue || m.Temperature.HasValue || m.RespiratoryRate.HasValue ||
        m.BloodGlucose.HasValue || m.PainScore.HasValue;

    private IActionResult ApiDown(string returnUrl) =>
        RedirectToAction("ApiUnavailable", "Home", new { returnUrl });

    private static string CalcAge(DateTime? dob)
    {
        if (dob is null) return "";
        var today = DateTime.Today;
        var age   = today.Year - dob.Value.Year;
        if (dob.Value.Date > today.AddYears(-age)) age--;
        return $"{age} yrs";
    }
}
