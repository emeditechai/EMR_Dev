using System.Text.Json;
using System.Text.RegularExpressions;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using EMR.Web.Services.Geography;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// IPD > New Admission, Admission List and the IPD Patient workspace (SQLScripts/2422-2424).
/// The patient is found / registered through the Patient Master service exactly as OPD and LAB do (phone first);
/// everything of the admission goes Web -> EMR.Api api/ipd -> stored procedures.
/// </summary>
[Authorize]
public class IpdAdmissionController(
    IpdApiClient api,
    IPatientService patientService,
    IStateService stateService,
    IDistrictService districtService,
    ICityService cityService,
    IAreaService areaService,
    IAuditLogService auditLogService,
    IActionPermissionGuard permissionGuard,
    IPrintTemplateRuntime printRuntime,
    IWebHostEnvironment env,
    ILogger<IpdAdmissionController> logger) : Controller
{
    public const string AdmissionPage = "IPD.ADMISSION";
    public const string PatientPage = "IPD.PATIENT";
    private static readonly string[] LookupNames =
    [
        "doctors", "referralDoctors", "departments", "tariffCategories", "insurances", "corporates", "schemes", "packages", "consents",
        "paymentModes", "settings", "bedCategories", "relations", "idTypes", "religions", "occupations", "maritalStatuses", "languages", "countries"
    ];

    private IActionResult Fail(string message) => Json(new { success = false, error = message });

    private async Task<IActionResult> ApiJson(Func<Task<object>> call)
    {
        try { return Json(new { success = true, data = await call() }); }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex)
        {
            logger.LogWarning(ex, "IPD API unreachable");
            return Fail("The EMR API is not reachable. Try again in a moment.");
        }
    }

    /// <summary>A write procedure's row: { Success, Error, ... } -> the page's { success, error, data }.</summary>
    private static (bool Ok, string? Error, JsonElement Row) Outcome(JsonElement row) =>
        row.ValueKind == JsonValueKind.Object && row.B("Success") ? (true, null, row)
            : (false, row.ValueKind == JsonValueKind.Object && row.S("Error") is { Length: > 0 } e ? e : "The request could not be completed.", row);

    private async Task<IActionResult> WriteJson(Func<Task<JsonElement>> call, Func<JsonElement, Task>? onSuccess = null)
    {
        try
        {
            var (ok, error, row) = Outcome(await call());
            if (!ok) return Fail(error!);
            if (onSuccess != null) await onSuccess(row);
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex)
        {
            logger.LogWarning(ex, "IPD API unreachable");
            return Fail("The EMR API is not reachable. Nothing was saved; try again in a moment.");
        }
    }

    private static object NamedSets(List<JsonElement> sets, string[] names) =>
        names.Select((n, i) => (n, i)).ToDictionary(x => x.n, x => x.i < sets.Count ? (object)sets[x.i] : Array.Empty<object>());

    // ═════════════════════════════════════════════════════════════════════════════════════════════════════════
    //  New Admission
    // ═════════════════════════════════════════════════════════════════════════════════════════════════════════
    [HttpGet]
    public async Task<IActionResult> New(int? patientId, int? opdServiceId, int? estimateId, int? bedId, int? adviceId)
    {
        if (User.GetCurrentBranchId() is null) return RedirectToAction("SelectBranch", "Account");
        // admission advised from OPD (SQLScripts/2438): the form is filled from the advice
        if (adviceId is > 0)
        {
            try
            {
                var adv = (await api.GetAsync("/advice" + IpdApiClient.Q(("status", "PENDING")))).Items().FirstOrDefault(x => x.I("AdviceId") == adviceId);
                if (adv.ValueKind == System.Text.Json.JsonValueKind.Object)
                {
                    patientId = adv.I("PatientId"); opdServiceId = adv.NI("OpdServiceId");
                    ViewBag.Advice = new { AdviceId = adv.I("AdviceId"), DoctorId = adv.NI("DoctorId"), DepartmentId = adv.NI("DepartmentId"), Reason = adv.S("Reason"),
                                           Diagnosis = adv.S("Diagnosis"), DiagnosisCode = adv.S("DiagnosisCode"), Urgency = adv.S("Urgency") };
                }
                else TempData["Error"] = "The admission advice is no longer pending.";
            }
            catch (HttpRequestException) { /* the form opens empty */ }
        }
        ViewBag.PatientId = patientId is > 0 && await patientService.GetByIdAsync(patientId.Value) != null ? patientId : null;
        ViewBag.OpdServiceId = opdServiceId;
        ViewBag.BedId = bedId;   // "Admit to this bed" from the Bed Board
        ViewBag.EstimateId = estimateId;
        ViewBag.CanBackdate = await permissionGuard.AllowsAsync(HttpContext, AdmissionPage, "BACKDATE");
        ViewBag.CanWaiveAdvance = await permissionGuard.AllowsAsync(HttpContext, AdmissionPage, "WAIVE_ADVANCE");
        ViewBag.Abha = (await HttpContext.RequestServices.GetRequiredService<IGovernmentIdFeatures>().GetAsync(HttpContext)).Abha;
        return View();
    }

    [HttpGet]
    public Task<IActionResult> Lookups() => ApiJson(async () => NamedSets(await api.SetsAsync("/lookups"), LookupNames));

    /// <summary>The same lookups for the workspace (edit admission), under the IPD Patient page.</summary>
    [HttpGet]
    public Task<IActionResult> PatientLookups() => Lookups();

    [HttpGet]
    public Task<IActionResult> Beds(int? tariffCategoryId) => ApiJson(async () => await api.GetAsync("/beds" + IpdApiClient.Q(("tariffCategoryId", tariffCategoryId))));

    [HttpGet]
    public Task<IActionResult> PatientStatus(int patientId) => ApiJson(async () =>
        NamedSets(await api.SetsAsync($"/patients/{patientId}/status"), ["open", "estimates", "previous"]));

    [HttpGet]
    public Task<IActionResult> PatientEstimates(int patientId) => PatientStatus(patientId);

    /// <summary>ICD-10 codes by code or words (SQLScripts/2433): provisional diagnosis on admission and edit.</summary>
    [HttpGet]
    public Task<IActionResult> IcdSearch(string? q) => ApiJson(async () => await api.GetAsync("/icd" + IpdApiClient.Q(("q", q))));

    [HttpGet]
    public Task<IActionResult> ConsentPreview(int consentId) => ApiJson(async () => await api.GetAsync($"/consent-templates/{consentId}"));

    [HttpGet]
    public Task<IActionResult> PatientConsentPreview(int consentId) => ConsentPreview(consentId);

    // ── patient search: the Patient Master searches of OPD / LAB (Global Patient Search setting honoured) ──
    private async Task<int?> SearchBranchAsync()
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return null;
        var settings = await printRuntime.SettingsAsync(branchId.Value);
        return settings?.GlobalPatientSearchRequired == true ? null : branchId;
    }

    [HttpGet]
    public async Task<IActionResult> SearchPatientByPhone(string phone) =>
        string.IsNullOrWhiteSpace(phone) || phone.Trim().Length < 3 ? Json(Array.Empty<object>())
            : Json(await patientService.SearchByPhoneAsync(phone.Trim(), await SearchBranchAsync()));

    [HttpGet]
    public async Task<IActionResult> SearchPatientByCode(string code) =>
        string.IsNullOrWhiteSpace(code) || code.Trim().Length < 2 ? Json(Array.Empty<object>())
            : Json(await patientService.SearchByCodeAsync(code.Trim(), await SearchBranchAsync()));

    [HttpGet]
    public async Task<IActionResult> SearchPatientByName(string name) =>
        string.IsNullOrWhiteSpace(name) || name.Trim().Length < 2 ? Json(Array.Empty<object>())
            : Json(await patientService.SearchByNameAsync(name.Trim(), await SearchBranchAsync()));

    [HttpGet]
    public async Task<IActionResult> GetPatientDetails(int id)
    {
        var p = await patientService.GetByIdAsync(id);
        if (p is null) return NotFound();
        var (y, m, d) = p.DateOfBirth.HasValue ? EMR.Web.Utils.AgeCalculator.FromDateOfBirth(p.DateOfBirth.Value) : (0, 0, 0);
        var split = PatientAddress.Split(p.Address);
        return Json(new
        {
            p.PatientId, p.PatientCode, p.PhoneNumber, p.SecondaryPhoneNumber, p.Salutation, p.FirstName, p.MiddleName, p.LastName, p.Gender,
            p.EmailId, p.GuardianName, p.IdentificationTypeId, p.IdentificationNumber, p.IdentificationFilePath, p.AbhaNumber, p.AbhaAddress,
            p.PhotoPath, p.BloodGroup, p.KnownAllergies, p.Remarks, p.DateOfBirth,
            AgeYears = p.DateOfBirth.HasValue ? y : (int?)null, AgeMonths = p.DateOfBirth.HasValue ? m : (int?)null, AgeDays = p.DateOfBirth.HasValue ? d : (int?)null,
            p.ReligionId, p.MaritalStatusId, p.OccupationId, p.LanguageId, p.CountryId, p.StateId, p.DistrictId, p.CityId, p.AreaId,
            Address = split.Address, Pincode = p.Pincode ?? split.Pincode, p.RelationId
        });
    }

    [HttpGet]
    public async Task<IActionResult> GetStatesByCountry(int countryId) =>
        Json((await stateService.GetByCountryAsync(countryId)).Where(s => s.IsActive).Select(s => new { s.StateId, s.StateName }));

    [HttpGet]
    public async Task<IActionResult> GetDistrictsByState(int stateId) =>
        Json((await districtService.GetByStateAsync(stateId)).Where(d => d.IsActive).Select(d => new { d.DistrictId, d.DistrictName }));

    [HttpGet]
    public async Task<IActionResult> GetCitiesByDistrict(int districtId) =>
        Json((await cityService.GetByDistrictAsync(districtId)).Where(c => c.IsActive).Select(c => new { c.CityId, c.CityName }));

    [HttpGet]
    public async Task<IActionResult> GetAreasByCity(int cityId) =>
        Json((await areaService.GetByCityAsync(cityId)).Where(a => a.IsActive).Select(a => new { a.AreaId, a.AreaName }));

    // ── save ────────────────────────────────────────────────────────────────────────────────────────────────
    private async Task<string?> SaveUploadAsync(IFormFile? file, string folder, string[] allowed)
    {
        if (file is null || file.Length == 0) return null;
        var ext = Path.GetExtension(file.FileName).ToLowerInvariant();
        if (!allowed.Contains(ext)) throw new InvalidOperationException($"{file.FileName}: only {string.Join(", ", allowed)} files can be uploaded.");
        if (file.Length > 10 * 1024 * 1024) throw new InvalidOperationException($"{file.FileName} is larger than 10 MB.");
        var dir = Path.Combine(env.WebRootPath, "uploads", folder);
        Directory.CreateDirectory(dir);
        var name = $"{Guid.NewGuid()}{ext}";
        await using (var stream = new FileStream(Path.Combine(dir, name), FileMode.Create)) await file.CopyToAsync(stream);
        return $"/uploads/{folder}/{name}";
    }

    /// <summary>A signature drawn on the pad (PNG data URL) saved as a file; null when none was drawn.</summary>
    private async Task<string?> SaveSignatureAsync(string? dataUrl)
    {
        if (string.IsNullOrWhiteSpace(dataUrl)) return null;
        var m = Regex.Match(dataUrl, "^data:image/png;base64,(?<b>[A-Za-z0-9+/=]+)$");
        if (!m.Success) return null;
        var bytes = Convert.FromBase64String(m.Groups["b"].Value);
        if (bytes.Length == 0 || bytes.Length > 2 * 1024 * 1024) return null;
        var dir = Path.Combine(env.WebRootPath, "uploads", "ipd", "signatures");
        Directory.CreateDirectory(dir);
        var name = $"{Guid.NewGuid()}.png";
        await System.IO.File.WriteAllBytesAsync(Path.Combine(dir, name), bytes);
        return $"/uploads/ipd/signatures/{name}";
    }

    private static string? Validate(IpdAdmissionForm m)
    {
        var phone = Regex.Replace(m.PhoneNumber ?? "", "\\D", "");
        if (phone.Length != 10) return "Enter the patient's 10-digit mobile number.";
        if (string.IsNullOrWhiteSpace(m.FirstName)) return "Enter the patient's first name.";
        if (string.IsNullOrWhiteSpace(m.LastName)) return "Enter the patient's last name.";
        if (string.IsNullOrWhiteSpace(m.Gender)) return "Choose the patient's gender.";
        if (m.RelationId is null or <= 0) return "Choose the relation (who owns the mobile number).";
        if (m.AgeMonths is > 12) return "Month cannot exceed 12.";
        if (m.AgeDays is > 30) return "Days cannot exceed 30.";
        if (m.AgeYears is < 0 or > 150) return "Years must be between 0 and 150.";
        if (!m.DateOfBirth.HasValue && (m.AgeYears ?? 0) + (m.AgeMonths ?? 0) + (m.AgeDays ?? 0) <= 0) return "Enter the patient's age or date of birth.";
        if (!string.IsNullOrWhiteSpace(m.AbhaNumber) && Regex.Replace(m.AbhaNumber, "\\D", "").Length != 14) return "ABHA Number must have 14 digits.";
        if (m.AdmittingDoctorId <= 0) return "Choose the admitting doctor.";
        if (m.ConsultantDoctorId <= 0) return "Choose the consultant (treating doctor).";
        if (m.TariffCategoryId <= 0) return "Choose the tariff category.";
        if (m.BedId <= 0) return "Choose a bed.";
        return null;
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [RequestSizeLimit(40 * 1024 * 1024)]
    public async Task<IActionResult> Save([FromForm] IpdAdmissionForm model, IFormFile? profilePictureFile, IFormFile? identificationFile, IFormFile? payerCardFile)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return Fail("Please select a branch first.");
        if (Validate(model) is { } invalid) return Fail(invalid);

        bool canBackdate = await permissionGuard.AllowsAsync(HttpContext, AdmissionPage, "BACKDATE");
        bool canWaive = await permissionGuard.AllowsAsync(HttpContext, AdmissionPage, "WAIVE_ADVANCE");

        string? cardPath, sigPath, witnessSigPath;
        try
        {
            if (await SaveUploadAsync(identificationFile, "identifications", [".pdf", ".jpg", ".jpeg", ".png"]) is { } idPath) model.IdentificationFilePath = idPath;
            if (await SaveUploadAsync(profilePictureFile, "patients", [".jpg", ".jpeg", ".png", ".gif"]) is { } photo) model.PhotoPath = photo;
            cardPath = await SaveUploadAsync(payerCardFile, "ipd/payer", [".pdf", ".jpg", ".jpeg", ".png"]);
            sigPath = await SaveSignatureAsync(model.ConsentSignature);
            witnessSigPath = await SaveSignatureAsync(model.WitnessSignature);
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }

        // age / date of birth, as OPD / LAB registration
        if ((model.AgeYears ?? 0) + (model.AgeMonths ?? 0) + (model.AgeDays ?? 0) > 0)
            model.DateOfBirth = EMR.Web.Utils.AgeCalculator.ToDateOfBirth(model.AgeYears ?? 0, model.AgeMonths ?? 0, model.AgeDays ?? 0);

        // ── the patient: Patient Master, exactly like OPD / LAB (an existing patient's phone is changed only in Patient Master) ──
        PatientMaster? existing = null;
        if (model.PatientId > 0)
        {
            existing = await patientService.GetByIdAsync(model.PatientId);
            if (existing is null) return Fail("The selected patient does not belong to this company. Search the patient again.");
            if (!string.IsNullOrWhiteSpace(existing.PhoneNumber)) model.PhoneNumber = existing.PhoneNumber;
        }
        var patient = new PatientMaster
        {
            PatientId = model.PatientId, FirstName = model.FirstName!.Trim(), MiddleName = model.MiddleName?.Trim(), LastName = model.LastName!.Trim(),
            PhoneNumber = Regex.Replace(model.PhoneNumber ?? "", "\\D", ""), SecondaryPhoneNumber = model.SecondaryPhoneNumber, EmailId = model.EmailId,
            Gender = model.Gender, DateOfBirth = model.DateOfBirth, RelationId = model.RelationId, Salutation = model.Salutation,
            PhotoPath = string.IsNullOrWhiteSpace(model.PhotoPath) ? existing?.PhotoPath : model.PhotoPath,
            IdentificationFilePath = string.IsNullOrWhiteSpace(model.IdentificationFilePath) ? existing?.IdentificationFilePath : model.IdentificationFilePath,
            IdentificationTypeId = model.IdentificationTypeId, IdentificationNumber = model.IdentificationNumber,
            AbhaNumber = string.IsNullOrWhiteSpace(model.AbhaNumber) ? null : Regex.Replace(model.AbhaNumber, "\\D", ""), AbhaAddress = model.AbhaAddress,
            ReligionId = model.ReligionId, GuardianName = model.GuardianName, CountryId = model.CountryId, StateId = model.StateId,
            DistrictId = model.DistrictId, CityId = model.CityId, AreaId = model.AreaId, Address = model.Address,
            Pincode = string.IsNullOrWhiteSpace(model.Pincode) ? null : model.Pincode.Trim(),
            HomeCollectionAddress = existing?.HomeCollectionAddress, Latitude = existing?.Latitude, Longitude = existing?.Longitude,
            OccupationId = model.OccupationId, MaritalStatusId = model.MaritalStatusId, LanguageId = model.LanguageId, BloodGroup = model.BloodGroup,
            KnownAllergies = model.KnownAllergies, Remarks = model.PatientRemarks, BranchId = branchId, CompanyId = User.GetCompanyId(), IsActive = true
        };

        int patientId;
        try
        {
            if (model.PatientId <= 0)
            {
                patientId = await patientService.CreateDemographicsOnlyAsync(patient, User.GetUserId());
                await auditLogService.LogAsync("IPD", "Patient.Create", $"Registered patient {patient.FirstName} {patient.LastName} for IPD admission.");
            }
            else
            {
                patientId = model.PatientId;
                await patientService.UpdateDemographicsAsync(patient, User.GetUserId());
            }
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "IPD admission: patient save failed");
            return Fail("The patient could not be saved: " + ex.Message);
        }

        // payer card upload goes on the primary payer
        var payers = model.PayersJson;
        if (cardPath != null && !string.IsNullOrWhiteSpace(payers))
        {
            try
            {
                var list = JsonSerializer.Deserialize<List<Dictionary<string, object?>>>(payers) ?? [];
                if (list.Count > 0) { list[0]["CardFilePath"] = cardPath; payers = JsonSerializer.Serialize(list); }
            }
            catch (JsonException) { return Fail("The payer details are not valid. Reload the page and try again."); }
        }

        string? consent = model.ConsentId is > 0
            ? JsonSerializer.Serialize(new
            {
                ConsentId = model.ConsentId, SignedByName = model.ConsentSignedByName, SignedByRelation = model.ConsentSignedByRelation,
                WitnessName = model.ConsentWitnessName, SignaturePath = sigPath, WitnessSignaturePath = witnessSigPath
            })
            : null;

        try
        {
            var row = await api.PostAsync("/admissions", new
            {
                model.RequestKey, PatientId = patientId, model.AdmissionAt, model.AdmissionType, model.AdmissionSource, model.OpdServiceId,
                model.ReferralDoctorId, model.AdmittingDoctorId, model.ConsultantDoctorId, model.DepartmentId, model.ProvisionalDiagnosis, model.DiagnosisCode,
                model.ReasonForAdmission, model.ExpectedDischargeAt, model.BedId, model.TariffCategoryId, model.PayerType, model.PackageId, model.EstimateId,
                model.Remarks, Payers = payers, Attendants = model.AttendantsJson, model.IsMlc, Mlc = model.MlcJson, Consent = consent,
                Payments = model.PaymentsJson, CanWaiveAdvance = canWaive, model.AdvanceWaiveReason, CanBackdate = canBackdate
            });
            var (ok, error, r) = Outcome(row);
            if (!ok) return Json(new { success = false, error, patientId });   // the patient stays saved: a retry reuses it
            var admissionId = r.I("AdmissionId");
            if (!r.B("Existing"))
                await auditLogService.LogActivityAsync(eventType: "IPD Admission", actionName: "IPD.Admit",
                    description: $"Admitted {patient.FirstName} {patient.LastName}, {r.S("IpNo")}" + (r.S("ReceiptNo") is { Length: > 0 } rn ? $", advance receipt {rn}" : ""),
                    userId: User.GetUserId(), branchId: branchId, moduleCode: "IPD", referenceNo: r.S("IpNo"), referenceId: admissionId,
                    patientCode: existing?.PatientCode);
            return Json(new
            {
                success = true, admissionId, ipNo = r.S("IpNo"), receiptNo = r.S("ReceiptNo"), advanceId = r.NI("AdvanceId"), patientId,
                url = Url.Action(nameof(Patient), new { id = admissionId })
            });
        }
        catch (InvalidOperationException ex) { return Json(new { success = false, error = ex.Message, patientId }); }
        catch (HttpRequestException ex)
        {
            logger.LogWarning(ex, "IPD API unreachable on admission save");
            return Json(new { success = false, error = "The EMR API is not reachable. The admission was not saved; try again in a moment.", patientId });
        }
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════════════════════
    //  Admission List
    // ═════════════════════════════════════════════════════════════════════════════════════════════════════════
    [HttpGet]
    public IActionResult Index() => User.GetCurrentBranchId() is null ? RedirectToAction("SelectBranch", "Account") : View();

    [HttpGet]
    public Task<IActionResult> ListData(string? status, DateTime? fromDate, DateTime? toDate, string? search, int? wardId, string? payerType, int page = 1, int pageSize = 25) =>
        ApiJson(async () => NamedSets(await api.SetsAsync("/admissions" + IpdApiClient.Q(("status", status), ("fromDate", fromDate), ("toDate", toDate),
            ("search", search), ("wardId", wardId), ("payerType", payerType), ("page", page), ("pageSize", pageSize))), ["rows", "total"]));

    // ═════════════════════════════════════════════════════════════════════════════════════════════════════════
    //  IPD Patient workspace
    // ═════════════════════════════════════════════════════════════════════════════════════════════════════════
    private async Task<IpdPatientView?> LoadPatientAsync(int id)
    {
        var sets = await api.SetsAsync($"/admissions/{id}");
        var header = sets.First(0);
        if (!header.Has() || header.I("BranchId") != (User.GetCurrentBranchId() ?? 0)) return null;
        return new IpdPatientView
        {
            Header = header, Payers = sets.ElementAtOrDefault(1).Items(), Attendants = sets.ElementAtOrDefault(2).Items(), Mlc = sets.First(3),
            Consents = sets.ElementAtOrDefault(4).Items(), Movements = sets.ElementAtOrDefault(5).Items(), Advances = sets.ElementAtOrDefault(6).Items(),
            Documents = sets.ElementAtOrDefault(7).Items(), Log = sets.ElementAtOrDefault(8).Items()
        };
    }

    [HttpGet]
    public async Task<IActionResult> Patient(int id, string? tab)
    {
        if (User.GetCurrentBranchId() is null) return RedirectToAction("SelectBranch", "Account");
        try
        {
            var model = await LoadPatientAsync(id);
            if (model is null) return NotFound();
            model.Tab = string.IsNullOrWhiteSpace(tab) ? "overview" : tab;
            foreach (var c in new[] { "EDIT", "CHANGE_TARIFF", "ADVANCE", "REFUND", "CONSENT", "DOCUMENT", "DOCUMENT_DELETE", "CANCEL", "TRANSFER", "CHARGE", "CHARGE_CANCEL", "RATE_EDIT", "DISCOUNT", "PACKAGE", "FINAL_BILL", "BILL_BACKDATE", "BILL_CANCEL", "LAB_ORDER", "LAB_CANCEL", "PH_ISSUE", "PH_RETURN" })
                ViewData["Can" + c] = await permissionGuard.AllowsAsync(HttpContext, PatientPage, c);
            ViewData["CanEstimate"] = await permissionGuard.AllowsAsync(HttpContext, IpdEstimationController.EstimationPage, "VIEW");
            return View(model);
        }
        catch (HttpRequestException) { ViewData["PageName"] = "IPD Patient"; return View("ApiDown"); }
        catch (InvalidOperationException ex) { TempData["Error"] = ex.Message; return RedirectToAction(nameof(Index)); }
    }

    [HttpGet]
    public Task<IActionResult> PatientData(int id) => ApiJson(async () =>
        NamedSets(await api.SetsAsync($"/admissions/{id}"), ["header", "payers", "attendants", "mlc", "consents", "movements", "advances", "documents", "log"]));

    public sealed class UpdateBody
    {
        public string AdmissionType { get; set; } = "ELECTIVE";
        public string AdmissionSource { get; set; } = "DIRECT";
        public int? ReferralDoctorId { get; set; }
        public int AdmittingDoctorId { get; set; }
        public int ConsultantDoctorId { get; set; }
        public int? DepartmentId { get; set; }
        public string? ProvisionalDiagnosis { get; set; }
        public string? DiagnosisCode { get; set; }
        public string? ReasonForAdmission { get; set; }
        public DateTime? ExpectedDischargeAt { get; set; }
        public int TariffCategoryId { get; set; }
        public string PayerType { get; set; } = "CASH";
        public int? PackageId { get; set; }
        public string? Remarks { get; set; }
        public string? Payers { get; set; }
        public string? Attendants { get; set; }
        public bool IsMlc { get; set; }
        public string? Mlc { get; set; }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Update(int id, [FromBody] UpdateBody b)
    {
        var canTariff = await permissionGuard.AllowsAsync(HttpContext, PatientPage, "CHANGE_TARIFF");
        return await WriteJson(() => api.PostAsync($"/admissions/{id}/update", new
        {
            b.AdmissionType, b.AdmissionSource, b.ReferralDoctorId, b.AdmittingDoctorId, b.ConsultantDoctorId, b.DepartmentId, b.ProvisionalDiagnosis,
            b.DiagnosisCode, b.ReasonForAdmission, b.ExpectedDischargeAt, b.TariffCategoryId, b.PayerType, b.PackageId, b.Remarks, b.Payers, b.Attendants,
            b.IsMlc, b.Mlc, CanChangeTariff = canTariff
        }), _ => auditLogService.LogActivityAsync(eventType: "IPD Admission", actionName: "IPD.Edit", description: $"Admission {id} details updated.",
            userId: User.GetUserId(), branchId: User.GetCurrentBranchId(), moduleCode: "IPD", referenceId: id));
    }

    public sealed class CancelBody { public string? Reason { get; set; } public string? RefundMethod { get; set; } public string? RefundRefNo { get; set; } }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Cancel(int id, [FromBody] CancelBody b)
    {
        // an advance still held is paid back in the same step: that needs the Refund permission too
        if (!string.IsNullOrWhiteSpace(b.RefundMethod) && !await permissionGuard.AllowsAsync(HttpContext, PatientPage, "REFUND"))
            return Fail("An advance is held on this admission and you are not allowed to refund it. Ask a user with the Refund permission.");
        return await WriteJson(() => api.PostAsync($"/admissions/{id}/cancel", new { b.Reason, b.RefundMethod, b.RefundRefNo }),
            _ => auditLogService.LogActivityAsync(eventType: "IPD Admission", actionName: "IPD.Cancel", description: $"Admission {id} cancelled: {b.Reason}",
                userId: User.GetUserId(), branchId: User.GetCurrentBranchId(), moduleCode: "IPD", referenceId: id));
    }

    public sealed class AdvanceBody { public string? Payments { get; set; } public string? Remarks { get; set; } }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> AddAdvance(int id, [FromBody] AdvanceBody b) =>
        WriteJson(() => api.PostAsync($"/admissions/{id}/advance", new { Payments = b.Payments ?? "[]", b.Remarks }),
            r => auditLogService.LogActivityAsync(eventType: "IPD Billing", actionName: "IPD.Advance", description: $"Advance receipt {r.S("ReceiptNo")} on admission {id}.",
                userId: User.GetUserId(), branchId: User.GetCurrentBranchId(), moduleCode: "IPD", referenceNo: r.S("ReceiptNo"), referenceId: id));

    public sealed class RefundBody { public decimal Amount { get; set; } public string? Method { get; set; } public string? RefNo { get; set; } public string? Reason { get; set; } }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> RefundAdvance(int id, [FromBody] RefundBody b) =>
        WriteJson(() => api.PostAsync($"/admissions/{id}/refund", new { b.Amount, Method = b.Method ?? "", b.RefNo, b.Reason }),
            r => auditLogService.LogActivityAsync(eventType: "IPD Billing", actionName: "IPD.Refund", description: $"Advance refund {r.S("DocNo")} ₹{b.Amount:N2} on admission {id}: {b.Reason}",
                userId: User.GetUserId(), branchId: User.GetCurrentBranchId(), moduleCode: "IPD", referenceNo: r.S("DocNo"), referenceId: id));

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveConsent(int id, [FromForm] int consentId, [FromForm] string? signedByName, [FromForm] string? signedByRelation,
        [FromForm] string? witnessName, [FromForm] string? signature, [FromForm] string? witnessSignature)
    {
        var sig = await SaveSignatureAsync(signature);
        var wsig = await SaveSignatureAsync(witnessSignature);
        return await WriteJson(() => api.PostAsync($"/admissions/{id}/consents", new
        {
            ConsentId = consentId, SignedByName = signedByName, SignedByRelation = signedByRelation, WitnessName = witnessName, SignaturePath = sig, WitnessSignaturePath = wsig
        }));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> UploadDocument(int id, IFormFile? file, [FromForm] string? docType, [FromForm] string? title, [FromForm] string? remarks)
    {
        string? path;
        try { path = await SaveUploadAsync(file, "ipd/documents", [".pdf", ".jpg", ".jpeg", ".png", ".doc", ".docx"]); }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        if (path is null) return Fail("Choose the file to upload.");
        return await WriteJson(() => api.PostAsync($"/admissions/{id}/documents", new { DocType = docType, Title = title, FilePath = path, Remarks = remarks }));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> RemoveDocument(int documentId) => WriteJson(() => api.PostAsync($"/documents/{documentId}/remove", new { }));

    // ═════════════════════════════════════════════════════════════════════════════════════════════════════════
    //  Prints
    // ═════════════════════════════════════════════════════════════════════════════════════════════════════════
    private Task PreparePrintAsync(string? docNo, string? docDate) =>
        IpdPrint.PrepareAsync(this, printRuntime, logger, User.GetCurrentBranchId() ?? 0,
            new PrintDocInfo { DocNo = docNo, DocDate = docDate, CopyLabel = "Original", PrintedBy = this.PrintedBy() });

    [HttpGet]
    public async Task<IActionResult> PrintFaceSheet(int id)
    {
        try
        {
            var model = await LoadPatientAsync(id);
            if (model is null) return NotFound();
            await PreparePrintAsync(model.Header.S("IpNo"), model.Header.Dt("AdmissionAt"));
            return View(model);
        }
        catch (HttpRequestException) { ViewData["PageName"] = "Admission Form"; return View("ApiDown"); }
    }

    [HttpGet]
    public async Task<IActionResult> PrintWristband(int id)
    {
        try
        {
            var model = await LoadPatientAsync(id);
            if (model is null) return NotFound();
            await PreparePrintAsync(model.Header.S("IpNo"), model.Header.Dt("AdmissionAt"));
            return View(model);
        }
        catch (HttpRequestException) { ViewData["PageName"] = "Wristband"; return View("ApiDown"); }
    }

    [HttpGet]
    public async Task<IActionResult> PrintConsent(int id)
    {
        try
        {
            var sets = await api.SetsAsync($"/consents/{id}");
            var doc = sets.First(0); var header = sets.First(1);
            if (!doc.Has() || !header.Has() || header.I("BranchId") != (User.GetCurrentBranchId() ?? 0)) return NotFound();
            await PreparePrintAsync(header.S("IpNo"), doc.Dt("SignedAt"));
            return View(new IpdPrintView { Title = doc.S("ConsentType"), DocNo = header.S("IpNo"), Header = header, Doc = doc });
        }
        catch (HttpRequestException) { ViewData["PageName"] = "Consent"; return View("ApiDown"); }
    }

    [HttpGet]
    public async Task<IActionResult> PrintReceipt(int id)
    {
        try
        {
            var sets = await api.SetsAsync($"/advances/{id}");
            var doc = sets.First(0); var header = sets.First(1);
            if (!doc.Has() || !header.Has() || header.I("BranchId") != (User.GetCurrentBranchId() ?? 0)) return NotFound();
            var refund = doc.S("Kind") == "REFUND";
            await PreparePrintAsync(doc.S("DocNo"), doc.Dt("CreatedDate"));
            return View(new IpdPrintView
            {
                Title = refund ? "Advance Refund Voucher" : "Advance Receipt", DocNo = doc.S("DocNo"), Header = header, Doc = doc,
                Rows = sets.ElementAtOrDefault(2).Items(), PrintedBy = this.PrintedBy()
            });
        }
        catch (HttpRequestException) { ViewData["PageName"] = "Receipt"; return View("ApiDown"); }
    }
}
