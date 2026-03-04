using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class VitalsController(
    IPatientVitalService vitalService,
    IPatientService patientService) : Controller
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

        if (editId.HasValue)
        {
            var existing = await vitalService.GetByIdAsync(editId.Value);
            if (existing is null) return NotFound();

            model = MapEntityToViewModel(existing);
            patientId = existing.PatientId;
        }

        if (patientId.HasValue && patientId.Value > 0)
        {
            var patient = await patientService.GetByIdAsync(patientId.Value);
            if (patient is not null)
                PopulatePatientContext(model, patient);
        }

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

        if (!ModelState.IsValid)
        {
            // Re-populate patient context
            if (model.PatientId > 0)
            {
                var patient = await patientService.GetByIdAsync(model.PatientId);
                if (patient is not null) PopulatePatientContext(model, patient);
            }
            ViewData["Title"] = model.PatientVitalId > 0 ? "Edit Vital Record" : "Record New Vitals";
            return View(model);
        }

        var userId = User.GetUserId();

        if (model.PatientVitalId > 0)
            await vitalService.UpdateVitalAsync(model, userId);
        else
            await vitalService.AddVitalAsync(model, userId);

        TempData["VitalSuccess"] = model.PatientVitalId > 0 ? "Vital record updated." : "Vital recorded successfully.";

        // "Save & Add Another" goes back to blank form for same patient
        if (returnAction == "another")
            return RedirectToAction(nameof(RecordVital), new { patientId = model.PatientId });

        return RedirectToAction(nameof(History), new { patientId = model.PatientId });
    }

    // ─── History ──────────────────────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> History(int patientId, int page = 1, int pageSize = 10)
    {
        var patient = await patientService.GetByIdAsync(patientId);
        if (patient is null) return NotFound();

        var (rows, total) = await vitalService.GetHistoryAsync(patientId, page, pageSize);

        var vm = new VitalIndexViewModel
        {
            PatientId        = patient.PatientId,
            PatientCode      = patient.PatientCode,
            PatientFullName  = BuildFullName(patient),
            PatientAge       = CalcAge(patient.DateOfBirth),
            PatientGender    = patient.Gender,
            PatientBloodGroup = patient.BloodGroup,
            PatientPhone     = patient.PhoneNumber,
            Vitals           = rows,
            TotalCount       = total,
            Page             = page,
            PageSize         = pageSize
        };

        ViewData["Title"] = $"Vital History — {vm.PatientFullName}";
        return View(vm);
    }

    // ─── GetLatest — JSON for inline dashboard/OPD card ──────────────────────

    [HttpGet]
    public async Task<IActionResult> GetLatest(int patientId)
    {
        var v = await vitalService.GetLatestAsync(patientId);
        if (v is null) return Json(new { found = false });

        return Json(new
        {
            found          = true,
            recordedOn     = v.RecordedOn.ToString("dd MMM yyyy HH:mm"),
            height         = v.Height,
            weight         = v.Weight,
            bmi            = v.BMI,
            bmiCategory    = v.BMICategory,
            bpSystolic     = v.BPSystolic,
            bpDiastolic    = v.BPDiastolic,
            pulseRate      = v.PulseRate,
            spO2           = v.SpO2,
            temperature    = v.Temperature,
            respiratoryRate = v.RespiratoryRate,
            bloodGlucose   = v.BloodGlucose,
            glucoseType    = v.GlucoseType,
            painScore      = v.PainScore
        });
    }

    // ─── Delete (AJAX) ────────────────────────────────────────────────────────

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int vitalId, int patientId)
    {
        await vitalService.DeleteAsync(vitalId, User.GetUserId());
        TempData["VitalSuccess"] = "Record deleted.";
        return RedirectToAction(nameof(History), new { patientId });
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    private static void PopulatePatientContext(VitalEntryViewModel m, EMR.Web.Models.Entities.PatientMaster p)
    {
        m.PatientId        = p.PatientId;
        m.PatientCode      = p.PatientCode;
        m.PatientFullName  = BuildFullName(p);
        m.PatientAge       = CalcAge(p.DateOfBirth);
        m.PatientGender    = p.Gender;
        m.PatientBloodGroup = p.BloodGroup;
        m.PatientPhone     = p.PhoneNumber;
        m.PatientAddress   = p.Address;
    }

    private static VitalEntryViewModel MapEntityToViewModel(EMR.Web.Models.Entities.PatientVital v) => new()
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

    private static bool HasAnyVital(VitalEntryViewModel m) =>
        m.Height.HasValue || m.Weight.HasValue ||
        m.BPSystolic.HasValue || m.BPDiastolic.HasValue || m.PulseRate.HasValue ||
        m.SpO2.HasValue || m.Temperature.HasValue || m.RespiratoryRate.HasValue ||
        m.BloodGlucose.HasValue || m.PainScore.HasValue;

    private static string BuildFullName(EMR.Web.Models.Entities.PatientMaster p)
    {
        var parts = new[] { p.Salutation, p.FirstName, p.MiddleName, p.LastName }
            .Where(s => !string.IsNullOrWhiteSpace(s));
        return string.Join(" ", parts).Trim();
    }

    private static string CalcAge(DateTime? dob)
    {
        if (dob is null) return "";
        var today = DateTime.Today;
        var age = today.Year - dob.Value.Year;
        if (dob.Value.Date > today.AddYears(-age)) age--;
        return $"{age} yrs";
    }
}
