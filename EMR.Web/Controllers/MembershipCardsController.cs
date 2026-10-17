using System.Text.Json;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using EMR.Web.Data;
using EMR.Web.Models.Entities;

namespace EMR.Web.Controllers;

/// <summary>
/// Master > General > Membership Cards: issue a card (fee + ledger posted by the API in one transaction),
/// print it, and send the soft copy by WhatsApp / email as switched on in Hospital Settings.
/// </summary>
[Authorize]
public class MembershipCardsController(
    IMembershipApiClient apiClient,
    IMembershipCardDeliveryService deliveryService,
    IPaymentService paymentService,
    IAuditLogService auditLogService,
    ApplicationDbContext dbContext,
    IPatientService patientService,
    EMR.Shared.Security.IActionPermissionGuard permissionGuard,
    IWebHostEnvironment env) : Controller
{
    public const string Page = "MASTER.MEMBERSHIPCARDS";
    public const string RegisterPatientControl = "REGISTER_PATIENT";
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    [HttpGet]
    public async Task<IActionResult> Index(int? planId = null, string? status = null, string? search = null, DateTime? fromDate = null, DateTime? toDate = null)
    {
        var model = new MembershipCardIndexViewModel { PlanId = planId, Status = status, Search = search, FromDate = fromDate, ToDate = toDate };
        try
        {
            var companyId = User.GetCompanyId();
            model.Plans = await apiClient.GetPlansAsync(companyId);
            model.Cards = await apiClient.GetCardsAsync(companyId, null, planId, status, search, fromDate, toDate);
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to load membership cards. " + ex.Message;
        }
        return View(model);
    }

    [HttpGet]
    public async Task<IActionResult> Issue()
    {
        var model = new MembershipCardIssueViewModel();
        await LoadIssuePageAsync(model);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Issue(MembershipCardIssueViewModel model)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null or <= 0)
            ModelState.AddModelError(string.Empty, "Select a working branch before issuing a card.");

        var members = ParseMembers(model.MembersJson);
        if (ModelState.IsValid)
        {
            try
            {
                var companyId = User.GetCompanyId();
                var result = await apiClient.IssueCardAsync(model, members, companyId, branchId!.Value, User.GetUserId());
                await auditLogService.LogAsync("Membership Cards", "Issue",
                    $"Issued membership card {result.CardNo} (fee ₹{result.FeeAmount:N2}, receipt {result.ReceiptNo ?? "-"})");

                var notes = new List<string> { $"Card {result.CardNo} issued." };
                if (!string.IsNullOrWhiteSpace(result.ReceiptNo)) notes.Add($"Receipt {result.ReceiptNo} for ₹{result.FeeAmount:N2}.");

                // Soft copy on issue, when Hospital Settings says so
                try
                {
                    var channels = await deliveryService.GetChannelsAsync(branchId.Value);
                    if (channels.AutoSendOnIssue && (channels.WhatsApp || channels.Email))
                    {
                        var card = await apiClient.GetCardAsync(result.CardId, companyId);
                        if (card != null)
                            notes.AddRange((await deliveryService.SendAsync(card, branchId.Value)).Select(Describe));
                    }
                }
                catch (Exception ex)
                {
                    notes.Add("The card could not be sent automatically: " + ex.Message);
                }

                TempData["Success"] = string.Join(" ", notes);
                return RedirectToAction(nameof(Details), new { id = result.CardId });
            }
            catch (MembershipApiException ex)
            {
                ModelState.AddModelError(string.Empty, ex.Message);
            }
            catch (Exception ex)
            {
                ModelState.AddModelError(string.Empty, "Failed to issue the card. " + ex.Message);
            }
        }

        await LoadIssuePageAsync(model);
        return View(model);
    }

    /// <summary>The family of a head: the other patients registered on the head's mobile number, with their relation.</summary>
    [HttpGet]
    public async Task<IActionResult> FamilyMembers(int patientId)
    {
        if (patientId <= 0) return Json(Array.Empty<object>());
        try
        {
            return Json(await apiClient.GetFamilyAsync(User.GetCompanyId(), patientId));
        }
        catch (Exception)
        {
            return Json(Array.Empty<object>());
        }
    }

    /// <summary>Head-of-family lookup for the issue form (code, name or mobile): patients registered with relation Self.</summary>
    [HttpGet]
    public async Task<IActionResult> PatientSearch(string? term)
    {
        if (string.IsNullOrWhiteSpace(term) || term.Trim().Length < 2) return Json(Array.Empty<object>());
        try
        {
            return Json(await apiClient.SearchPatientsAsync(User.GetCompanyId(), term.Trim()));
        }
        catch (Exception)
        {
            return Json(Array.Empty<object>());
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        try
        {
            var card = await apiClient.GetCardAsync(id, User.GetCompanyId());
            if (card == null) return NotFound();

            var channels = await deliveryService.GetChannelsAsync(User.GetCurrentBranchId() ?? card.IssueBranchId);
            card.WhatsAppEnabled = channels.WhatsApp;
            card.EmailEnabled = channels.Email;

            if (card.CanRenew)
            {
                card.RenewalWindowDays = await deliveryService.GetRenewalWindowDaysAsync(User.GetCurrentBranchId() ?? card.IssueBranchId);
                card.Plans = await apiClient.GetPlansAsync(User.GetCompanyId(), status: true);
                card.PaymentMethods = (await paymentService.GetActiveMethodsAsync()).ToList();
            }
            return View(card);
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to load the membership card. " + ex.Message;
            return RedirectToAction(nameof(Index));
        }
    }

    /// <summary>
    /// Renews a card: the API issues the next card (same members, points carried forward, fee and ledger posted
    /// like a fresh issue) and closes this one as Renewed. planId 0 keeps the plan.
    /// </summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Renew(int id, int planId, int? paymentMethodId, string? transactionRef, string? remarks)
    {
        var branchId = User.GetCurrentBranchId();
        try
        {
            if (branchId is null or <= 0) throw new MembershipApiException("Select a working branch before renewing a card.");
            var companyId = User.GetCompanyId();
            var result = await apiClient.RenewCardAsync(id, planId, paymentMethodId, transactionRef, remarks, companyId, branchId.Value, User.GetUserId());
            await auditLogService.LogAsync("Membership Cards", "Renew",
                $"Renewed membership card #{id} as {result.CardNo} (fee ₹{result.FeeAmount:N2}, receipt {result.ReceiptNo ?? "-"})");

            var notes = new List<string> { $"Card renewed as {result.CardNo}; points carried forward." };
            if (!string.IsNullOrWhiteSpace(result.ReceiptNo)) notes.Add($"Receipt {result.ReceiptNo} for ₹{result.FeeAmount:N2}.");
            try
            {
                var channels = await deliveryService.GetChannelsAsync(branchId.Value);
                if (channels.AutoSendOnIssue && (channels.WhatsApp || channels.Email))
                {
                    var card = await apiClient.GetCardAsync(result.CardId, companyId);
                    if (card != null)
                        notes.AddRange((await deliveryService.SendAsync(card, branchId.Value)).Select(Describe));
                }
            }
            catch (Exception ex)
            {
                notes.Add("The new card could not be sent automatically: " + ex.Message);
            }

            TempData["Success"] = string.Join(" ", notes);
            return RedirectToAction(nameof(Details), new { id = result.CardId });
        }
        catch (MembershipApiException ex)
        {
            TempData["Error"] = ex.Message;
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to renew the card. " + ex.Message;
        }
        return RedirectToAction(nameof(Details), new { id });
    }

    /// <summary>The card PDF, shown inline for printing (each open counts as a print) or downloaded with download=true.</summary>
    [HttpGet]
    public async Task<IActionResult> Card(int id, bool download = false)
    {
        var companyId = User.GetCompanyId();
        var card = await apiClient.GetCardAsync(id, companyId);
        if (card == null) return NotFound();

        var pdf = await deliveryService.BuildPdfAsync(card, User.GetCurrentBranchId() ?? card.IssueBranchId);
        if (!download)
        {
            await apiClient.MarkPrintedAsync(id, companyId, User.GetUserId());
            await auditLogService.LogAsync("Membership Cards", "Print", $"Printed membership card {card.CardNo}");
        }

        var fileName = $"Membership_Card_{card.CardNo}.pdf";
        if (download) return File(pdf, "application/pdf", fileName);
        Response.Headers.ContentDisposition = $"inline; filename=\"{fileName}\"";
        return File(pdf, "application/pdf");
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Send(int id)
    {
        try
        {
            var card = await apiClient.GetCardAsync(id, User.GetCompanyId());
            if (card == null) return NotFound();

            var outcomes = await deliveryService.SendAsync(card, User.GetCurrentBranchId() ?? card.IssueBranchId);
            await auditLogService.LogAsync("Membership Cards", "Send",
                $"Sent membership card {card.CardNo}: {string.Join("; ", outcomes.Select(o => $"{o.Channel} {o.Status}"))}");

            var text = string.Join(" ", outcomes.Select(Describe));
            if (outcomes.Any(o => o.Status == "Sent")) TempData["Success"] = text;
            else TempData["Error"] = text;
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to send the card. " + ex.Message;
        }
        return RedirectToAction(nameof(Details), new { id });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> AddMember(int id, int patientId)
    {
        string? relation = null;   // taken from the patient's own record by the API
        try
        {
            if (patientId <= 0) throw new MembershipApiException("Select the patient to add.");
            var branchId = User.GetCurrentBranchId() ?? 0;
            await apiClient.AddMemberAsync(id, User.GetCompanyId(), branchId, patientId, relation, User.GetUserId());
            await auditLogService.LogAsync("Membership Cards", "Add Member", $"Added patient #{patientId} to membership card #{id}");
            TempData["Success"] = "Member added. Print or send the card again so the new member is on it.";
        }
        catch (MembershipApiException ex)
        {
            TempData["Error"] = ex.Message;
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to add the member. " + ex.Message;
        }
        return RedirectToAction(nameof(Details), new { id });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SetStatus(int id, string status, string? reason)
    {
        try
        {
            var branchId = User.GetCurrentBranchId() ?? 0;
            await apiClient.SetCardStatusAsync(id, User.GetCompanyId(), branchId, status, reason, User.GetUserId());
            await auditLogService.LogAsync("Membership Cards", "Status", $"Membership card #{id} set to {status}. {reason}");
            TempData["Success"] = $"Card is now {status}.";
        }
        catch (MembershipApiException ex)
        {
            TempData["Error"] = ex.Message;
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to change the card status. " + ex.Message;
        }
        return RedirectToAction(nameof(Details), new { id });
    }


    // ── Register a new patient from Issue Membership Card (SQLScripts/2282) ─────────────────────────────────────
    // The patient goes into the common Patient Master the same way LAB booking registers one
    // (PatientService.CreateDemographicsOnlyAsync -> usp_PatientMaster_Insert: patient code of the branch, no bill),
    // as the head of family (relation Self), so the card can be issued to him or her straight away.

    public sealed class NewPatientRequest
    {
        /// <summary>Set when an existing patient was picked from the mobile search: registering is then refused.</summary>
        public int? ExistingPatientId { get; set; }
        public string? Salutation { get; set; }
        public string? FirstName { get; set; }
        public string? MiddleName { get; set; }
        public string? LastName { get; set; }
        public string? Gender { get; set; }
        public DateTime? DateOfBirth { get; set; }
        public int? AgeYears { get; set; }
        public int? AgeMonths { get; set; }
        public int? AgeDays { get; set; }
        public string? PhoneNumber { get; set; }
        public string? SecondaryPhoneNumber { get; set; }
        public string? EmailId { get; set; }
        public string? GuardianName { get; set; }
        public int? CountryId { get; set; }
        public int? StateId { get; set; }
        public int? DistrictId { get; set; }
        public int? CityId { get; set; }
        public int? AreaId { get; set; }
        public string? Address { get; set; }
        public int? ReligionId { get; set; }
        public int? MaritalStatusId { get; set; }
        public int? OccupationId { get; set; }
        public int? LanguageId { get; set; }
        public string? BloodGroup { get; set; }
        public int? IdentificationTypeId { get; set; }
        public string? IdentificationNumber { get; set; }
        public string? KnownAllergies { get; set; }
        public string? Remarks { get; set; }
    }

    private static object Opt(int id, string name) => new { id, name };

    /// <summary>The lists of the new-patient form (the masters the OPD registration uses); India / West Bengal preselected.</summary>
    [HttpGet]
    public async Task<IActionResult> NewPatientLookups()
    {
        if (!await permissionGuard.AllowsAsync(HttpContext, Page, RegisterPatientControl)) return Forbid();
        var countries = await dbContext.CountryMasters.Where(x => x.IsActive).OrderBy(x => x.CountryName).Select(x => new { id = x.CountryId, name = x.CountryName }).ToListAsync();
        var india = countries.FirstOrDefault(c => c.name.Equals("India", StringComparison.OrdinalIgnoreCase));
        int? stateId = null;
        if (india != null)
            stateId = await dbContext.StateMasters.Where(s => s.IsActive && s.CountryId == india.id && s.StateName.Contains("West Bengal")).Select(s => (int?)s.StateId).FirstOrDefaultAsync();
        return Json(new
        {
            countries,
            defaultCountryId = india?.id ?? countries.FirstOrDefault()?.id,
            defaultStateId = stateId,
            religions = await dbContext.ReligionMasters.Where(x => x.IsActive).OrderBy(x => x.ReligionName).Select(x => new { id = x.ReligionId, name = x.ReligionName }).ToListAsync(),
            idTypes = await dbContext.IdentificationTypeMasters.Where(x => x.IsActive).OrderBy(x => x.IdentificationTypeName).Select(x => new { id = x.IdentificationTypeId, name = x.IdentificationTypeName }).ToListAsync(),
            occupations = await dbContext.OccupationMasters.Where(x => x.IsActive).OrderBy(x => x.OccupationName).Select(x => new { id = x.OccupationId, name = x.OccupationName }).ToListAsync(),
            maritalStatuses = await dbContext.MaritalStatusMasters.Where(x => x.IsActive).OrderBy(x => x.StatusName).Select(x => new { id = x.MaritalStatusId, name = x.StatusName }).ToListAsync(),
            languages = await dbContext.LanguageMasters.Where(x => x.IsActive).OrderBy(x => x.LanguageName).Select(x => new { id = x.LanguageId, name = x.LanguageName }).ToListAsync()
        });
    }

    /// <summary>Country > state > district > city > area, one level at a time.</summary>
    [HttpGet]
    public async Task<IActionResult> NewPatientGeo(string level, int parentId)
    {
        if (!await permissionGuard.AllowsAsync(HttpContext, Page, RegisterPatientControl)) return Forbid();
        object list = level switch
        {
            "state" => await dbContext.StateMasters.Where(x => x.IsActive && x.CountryId == parentId).OrderBy(x => x.StateName).Select(x => new { id = x.StateId, name = x.StateName }).ToListAsync(),
            "district" => await dbContext.DistrictMasters.Where(x => x.IsActive && x.StateId == parentId).OrderBy(x => x.DistrictName).Select(x => new { id = x.DistrictId, name = x.DistrictName }).ToListAsync(),
            "city" => await dbContext.CityMasters.Where(x => x.IsActive && x.DistrictId == parentId).OrderBy(x => x.CityName).Select(x => new { id = x.CityId, name = x.CityName }).ToListAsync(),
            "area" => await dbContext.AreaMasters.Where(x => x.IsActive && x.CityId == parentId).OrderBy(x => x.AreaName).Select(x => new { id = x.AreaId, name = x.AreaName }).ToListAsync(),
            _ => Array.Empty<object>()
        };
        return Json(list);
    }

    /// <summary>Patients already registered on a mobile number (as OPD registration searches: this branch, or every branch
    /// when Hospital Settings > Global Patient Search is on).</summary>
    [HttpGet]
    public async Task<IActionResult> NewPatientPhoneSearch(string? phone)
    {
        if (!await permissionGuard.AllowsAsync(HttpContext, Page, RegisterPatientControl)) return Forbid();
        phone = new string((phone ?? "").Where(char.IsDigit).ToArray());
        if (phone.Length < 3) return Json(Array.Empty<object>());
        var branchId = User.GetCurrentBranchId();
        var global = await dbContext.HospitalSettings.Where(s => s.BranchId == branchId).Select(s => (bool?)s.GlobalPatientSearchRequired).FirstOrDefaultAsync() == true;
        var rows = await patientService.SearchByPhoneAsync(phone, global ? null : branchId);
        return Json(rows.Select(r => new { r.PatientId, r.PatientCode, r.FullName, r.PhoneNumber, r.Gender, r.Age, r.RelationName }));
    }

    /// <summary>One registered patient's details, to show in the form (read-only).</summary>
    [HttpGet]
    public async Task<IActionResult> NewPatientExisting(int id)
    {
        if (!await permissionGuard.AllowsAsync(HttpContext, Page, RegisterPatientControl)) return Forbid();
        var p = await patientService.GetByIdAsync(id);
        if (p == null || !p.IsActive) return Json(new { success = false, error = "Patient not found." });
        var relation = p.RelationId.HasValue ? await dbContext.RelationMasters.Where(r => r.RelationId == p.RelationId).Select(r => r.RelationName).FirstOrDefaultAsync() : null;
        return Json(new
        {
            success = true,
            patient = new
            {
                p.PatientId, p.PatientCode, p.Salutation, p.FirstName, p.MiddleName, p.LastName, p.Gender, p.DateOfBirth, p.PhoneNumber,
                p.SecondaryPhoneNumber, p.EmailId, p.GuardianName, p.CountryId, p.StateId, p.DistrictId, p.CityId, p.AreaId, p.Address,
                p.ReligionId, p.MaritalStatusId, p.OccupationId, p.LanguageId, p.BloodGroup, p.IdentificationTypeId, p.IdentificationNumber,
                p.KnownAllergies, p.Remarks, RelationName = relation, IsSelf = relation == "Self"
            }
        });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> RegisterPatient([FromForm] NewPatientRequest r, IFormFile? profilePictureFile, IFormFile? identificationFile)
    {
        if (!await permissionGuard.AllowsAsync(HttpContext, Page, RegisterPatientControl))
            return Json(new { success = false, error = "You do not have permission to register patients here." });
        if (r.ExistingPatientId is > 0)
            return Json(new { success = false, error = "This patient is already registered. A new patient cannot be created here: close this form and select the patient on the Issue Membership Card screen." });
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return Json(new { success = false, error = "Select a branch first." });

        string? T(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
        var phone = new string((r.PhoneNumber ?? "").Where(char.IsDigit).ToArray());
        var errors = new List<string>();
        // the rules of OPD Patient Registration
        if (string.IsNullOrWhiteSpace(r.FirstName)) errors.Add("First name is required.");
        if (string.IsNullOrWhiteSpace(r.LastName)) errors.Add("Last name is required.");
        if (string.IsNullOrWhiteSpace(r.Gender)) errors.Add("Gender is required.");
        if (!System.Text.RegularExpressions.Regex.IsMatch(phone, @"^[6-9]\d{9}$")) errors.Add("Enter a valid 10-digit mobile number.");
        if (!string.IsNullOrWhiteSpace(r.EmailId) && !System.Text.RegularExpressions.Regex.IsMatch(r.EmailId.Trim(), @"^[^@\s]+@[^@\s]+\.[^@\s]+$")) errors.Add("Enter a valid e-mail address.");
        // date of birth, or the age in years (date of birth worked out as today minus the years)
        var dob = r.DateOfBirth?.Date;
        if (dob == null && (r.AgeYears.HasValue || r.AgeMonths.HasValue || r.AgeDays.HasValue))
            dob = DateTime.Today.AddYears(-(r.AgeYears ?? 0)).AddMonths(-(r.AgeMonths ?? 0)).AddDays(-(r.AgeDays ?? 0));
        if (dob == null) errors.Add("Enter the date of birth or the age.");
        else if (dob > DateTime.Today) errors.Add("The date of birth cannot be in the future.");
        else if (dob < DateTime.Today.AddYears(-110)) errors.Add("Age cannot be more than 110 years.");
        if (errors.Count > 0) return Json(new { success = false, error = string.Join(" ", errors) });

        // relation is always Self (never taken from the request): only a Self patient can hold a card, and the family on
        // the card is found from the head's mobile number - any other relation would break the membership flow
        var selfId = await dbContext.RelationMasters.Where(x => x.IsActive && x.RelationName == "Self").Select(x => (int?)x.RelationId).FirstOrDefaultAsync();
        if (selfId is null) return Json(new { success = false, error = "Relation 'Self' is missing in Relation Master." });
        // as OPD registration (and the database, script 2221): one active Self patient per phone number and per e-mail
        var dupPhone = await dbContext.PatientMasters.Where(p => p.IsActive && p.RelationId == selfId && p.PhoneNumber == phone)
            .Select(p => new { p.PatientCode, p.FirstName, p.LastName }).FirstOrDefaultAsync();
        if (dupPhone != null)
            return Json(new { success = false, error = $"A patient with relation \"Self\" is already registered for phone {phone}: {dupPhone.FirstName} {dupPhone.LastName} ({dupPhone.PatientCode}). Search and select that patient instead." });
        var email = T(r.EmailId)?.ToLowerInvariant();
        if (email != null && await dbContext.PatientMasters.AnyAsync(p => p.IsActive && p.RelationId == selfId && p.EmailId == email))
            return Json(new { success = false, error = $"A patient with relation \"Self\" is already registered with e-mail {email}." });

        // files, stored as OPD registration stores them (wwwroot/uploads/patients)
        async Task<(string? Path, string? Error)> SaveFile(IFormFile? f, string[] allowed, string what)
        {
            if (f is not { Length: > 0 }) return (null, null);
            var ext = Path.GetExtension(f.FileName).ToLowerInvariant();
            if (!allowed.Contains(ext)) return (null, $"Only {string.Join(", ", allowed.Select(a => a.TrimStart('.').ToUpperInvariant()))} files are allowed for {what}.");
            if (f.Length > 5 * 1024 * 1024) return (null, $"{what} must be 5 MB or smaller.");
            var dir = Path.Combine(env.WebRootPath, "uploads", "patients");
            Directory.CreateDirectory(dir);
            var name = $"{Guid.NewGuid()}{ext}";
            await using (var s = new FileStream(Path.Combine(dir, name), FileMode.Create)) await f.CopyToAsync(s);
            return ($"/uploads/patients/{name}", null);
        }
        var (photoPath, photoErr) = await SaveFile(profilePictureFile, [".jpg", ".jpeg", ".png", ".gif"], "the profile picture");
        if (photoErr != null) return Json(new { success = false, error = photoErr });
        var (idPath, idErr) = await SaveFile(identificationFile, [".pdf", ".jpg", ".jpeg", ".png"], "the ID document");
        if (idErr != null) return Json(new { success = false, error = idErr });

        var patient = new PatientMaster
        {
            Salutation = T(r.Salutation), FirstName = r.FirstName!.Trim(), MiddleName = T(r.MiddleName), LastName = T(r.LastName),
            Gender = r.Gender!.Trim(), DateOfBirth = dob, PhoneNumber = phone, SecondaryPhoneNumber = T(r.SecondaryPhoneNumber),
            EmailId = email, PhotoPath = photoPath, IdentificationFilePath = idPath, GuardianName = T(r.GuardianName), RelationId = selfId,   // Self: head of family
            CountryId = r.CountryId, StateId = r.StateId, DistrictId = r.DistrictId, CityId = r.CityId, AreaId = r.AreaId,
            Address = T(r.Address), ReligionId = r.ReligionId, MaritalStatusId = r.MaritalStatusId, OccupationId = r.OccupationId,
            LanguageId = r.LanguageId, BloodGroup = T(r.BloodGroup), IdentificationTypeId = r.IdentificationTypeId,
            IdentificationNumber = T(r.IdentificationNumber), KnownAllergies = T(r.KnownAllergies), Remarks = T(r.Remarks),
            BranchId = branchId.Value, CompanyId = User.GetCompanyId(), IsActive = true
        };
        try
        {
            var id = await patientService.CreateDemographicsOnlyAsync(patient, User.GetUserId());
            var saved = await patientService.GetByIdAsync(id);
            await auditLogService.LogAsync("Membership Cards", "Patient.Create",
                $"Registered patient {saved?.PatientCode} ({patient.FirstName} {patient.LastName}) from Issue Membership Card");
            var age = dob.HasValue ? (int?)(DateTime.Today.Year - dob.Value.Year - (DateTime.Today.DayOfYear < dob.Value.DayOfYear ? 1 : 0)) : null;
            return Json(new
            {
                success = true,
                patient = new
                {
                    patientId = id, patientCode = saved?.PatientCode,
                    patientName = string.Join(" ", new[] { patient.Salutation, patient.FirstName, patient.MiddleName, patient.LastName }.Where(s => !string.IsNullOrWhiteSpace(s))),
                    phoneNumber = phone, gender = patient.Gender, age, familyCount = 0
                }
            });
        }
        catch (Exception ex)
        {
            return Json(new { success = false, error = "The patient could not be registered. " + ex.Message });
        }
    }

    private async Task LoadIssuePageAsync(MembershipCardIssueViewModel model)
    {
        try
        {
            model.Plans = await apiClient.GetPlansAsync(User.GetCompanyId(), status: true);
            model.PaymentMethods = (await paymentService.GetActiveMethodsAsync()).ToList();
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to load plans or payment methods. " + ex.Message;
        }
    }

    private static List<MembershipCardMemberInput> ParseMembers(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return [];
        try
        {
            return (JsonSerializer.Deserialize<List<MembershipCardMemberInput>>(json, JsonOptions) ?? [])
                .Where(m => m.PatientId > 0).ToList();
        }
        catch (JsonException)
        {
            return [];
        }
    }

    private static string Describe(MembershipCardSendOutcome o) => $"{o.Channel}: {o.Status.ToLowerInvariant()} - {o.Message}";
}
