using System.Security.Claims;
using Dapper;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.DTOs;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

/// <summary>
/// The patient app's view of what the web Patient Portal shows: OPD visits and LAB bills from the patient profile
/// (PatientProfileService), the live LAB stage, the approved LAB report PDF, and the prescription / bill prints.
/// Signed in with the token of EMR.Api api/auth/patient-login (token_use = patient); every record is checked to be the
/// patient's. A document opens through a link carrying a 10-minute ticket for that one document, so the phone's
/// browser or PDF viewer can show and save it without the sign-in token.
/// </summary>
[AllowAnonymous]
[IgnoreAntiforgeryToken]
[Route("api/patient-app")]
public sealed class PatientAppController(
    ApplicationDbContext dbContext,
    IApiTokenService tokens,
    IPatientProfileService profileService,
    IPatientDocumentService documents,
    IHttpClientFactory httpClientFactory,
    IDoctorConsultingFeeService consultingFeeService,
    IPatientService patientService,
    ILedgerService ledgerService,
    IAuditLogService auditLogService,
    IOpdBookingNotifier bookingNotifier,
    ILabOrderApiClient labOrderApiClient,
    ILabBookingNotifier labBookingNotifier,
    ILogger<PatientAppController> logger) : Controller
{
    private static readonly TimeSpan TicketLifetime = TimeSpan.FromMinutes(10);

    // GET api/patient-app/records - OPD visits and LAB bills (as on the portal dashboard), with each bill's report state,
    // and the family and membership card as Patient Master shows them (Views/OPD/Details.cshtml)
    [HttpGet("records")]
    public Task<IActionResult> Records() => AsPatient(async patientId =>
    {
        var model = await profileService.BuildAsync(patientId);
        if (model == null || !model.Patient.IsActive) return Unauthorized(Fail("UNAUTHENTICATED", "Please sign in again."));
        var p = model.Patient;

        var labOrders = new List<object>();
        foreach (var l in model.LabOrderHistory)
        {
            var st = await documents.ReportStateAsync(l.LabOrderId);
            labOrders.Add(new
            {
                labOrderId = l.LabOrderId, orderDate = l.OrderDate, billNo = l.BillNo, totalAmount = l.TotalAmount,
                discountAmount = l.DiscountAmount, paidAmount = l.PaidAmount, paymentStatus = l.PaymentStatus,
                approvedTestCount = l.ApprovedTestCount,
                totalTests = st?.TotalTests ?? 0, approvedTests = st?.ApprovedTests ?? 0, isFinal = st?.IsFinal ?? false,
                finalApprovedOn = st?.FinalApprovedOn, reportByPartner = st is { IsB2B: true, NotificationAllowed: false }
            });
        }

        var card = model.CurrentCard;
        var headOfFamily = p.RelationId == 1 ? null : model.Family.FirstOrDefault(f => f.IsSelf);
        return Ok(new
        {
            success = true,
            visits = model.VisitHistory.Select(v => new
            {
                opdServiceId = v.OPDServiceId, visitDate = v.VisitDate, billNo = v.OPDBillNo, tokenNo = v.TokenNo,
                totalAmount = v.TotalAmount, status = v.Status, paymentStatus = v.PaymentStatus,
                doctorName = v.ConsultingDoctorName, services = v.ServiceTypesSummary
            }),
            labOrders,
            billing = model.BillingSummary,
            // where a home collection goes (LAB > Home Collection Dispatch reads the same)
            homeCollectionAddress = !string.IsNullOrWhiteSpace(p.HomeCollectionAddress) ? p.HomeCollectionAddress
                                  : !string.IsNullOrWhiteSpace(p.Address) ? p.Address : null,
            family = new
            {
                phone = p.PhoneNumber,
                isHead = p.RelationId == 1,
                relationName = model.RelationName,
                head = headOfFamily == null ? null : new { headOfFamily.PatientId, headOfFamily.FullName, headOfFamily.PatientCode },
                members = model.Family.Select(f => new
                {
                    f.PatientId, f.PatientCode, f.FullName, f.Gender, f.DateOfBirth, f.RelationName, f.IsSelf, f.IsActive,
                    onCard = card != null && model.CardMembers.Any(m => m.CardId == card.CardId && m.PatientId == f.PatientId && m.IsActive)
                })
            },
            membership = new
            {
                current = card == null ? null : new
                {
                    card.CardId, card.CardNo, card.PlanName, card.PlanType, status = card.EffectiveStatus, card.ValidFrom, card.ValidTo,
                    card.PointsBalance, pointsValue = card.PointsBalance * card.PointValue, card.MaxMembers, card.FeeAmount, card.ReceiptNo,
                    card.IssueBranchName, issuedOn = card.CreatedDate, card.IsPrimary, card.MemberRelation, card.MemberActive,
                    card.PrimaryName, card.PrimaryCode,
                    members = model.CardMembers.Where(m => m.CardId == card.CardId).Select(m => new
                    {
                        m.PatientId, m.PatientCode, m.FullName, m.Relation, m.IsPrimary, m.IsActive, isYou = m.PatientId == patientId
                    })
                },
                others = model.MembershipCards.Where(c => card == null || c.CardId != card.CardId)
                    .Select(c => new { c.CardId, c.CardNo, c.PlanName, status = c.EffectiveStatus, c.ValidTo }),
                points = model.PointsLedger.Select(lp => new
                {
                    lp.CreatedDate, lp.CardNo, lp.TxnType, lp.Points, lp.Amount, lp.BalanceAfter, lp.ReceiptNo, lp.Narration
                })
            }
        });
    });

    // GET api/patient-app/lab-workflow?ids=5,6 - the live stage of the patient's LAB bills
    [HttpGet("lab-workflow")]
    public Task<IActionResult> LabWorkflow(string? ids) => AsPatient(async patientId =>
    {
        var wanted = (ids ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries).Select(x => int.TryParse(x, out var v) ? v : 0);
        return Ok(new { success = true, data = await documents.LabWorkflowAsync(patientId, wanted) });
    });

    // GET api/patient-app/lab-menu - what the patient can book online: the items on the patient's branch B2C rate list,
    // at the branch rate, with the gender / age rules of LAB > B2C Booking (usp_GetAvailableInvestigations, SQLScripts/2199)
    [HttpGet("lab-menu")]
    public Task<IActionResult> LabMenu() => AsPatient(async patientId =>
    {
        var menu = await LabMenuAsync(patientId);
        if (menu == null) return Unauthorized(Fail("UNAUTHENTICATED", "Please sign in again."));
        return Ok(new
        {
            success = true,
            menu.BranchId,
            categories = menu.Items.Where(i => i.CategoryId != null).GroupBy(i => new { i.CategoryId, i.CategoryName })
                .Select(g => new { id = g.Key.CategoryId, name = g.Key.CategoryName, count = g.Count() }).OrderBy(c => c.name),
            items = menu.Items.Select(i => new
            {
                key = i.Key, kind = i.Kind, id = i.Id, code = i.Code, name = i.Name, rate = i.Rate, tatHours = i.TatHours,
                fasting = i.Fasting, sampleType = i.SampleType, method = i.Method, categoryId = i.CategoryId,
                categoryName = i.CategoryName, includes = i.Includes
            })
        });
    });

    private sealed record LabMenuEntry(string Key, string Kind, int Id, string? Code, string Name, decimal Rate, string? TatHours, bool Fasting,
        string? SampleType, string? Method, int? CategoryId, string? CategoryName, List<string> Includes);

    private sealed record PatientLabMenu(int BranchId, PatientMaster Patient, List<LabMenuEntry> Items);

    /// <summary>The branch rate list for this patient (null when the patient is not found).</summary>
    private async Task<PatientLabMenu?> LabMenuAsync(int patientId)
    {
        var patient = await dbContext.PatientMasters.AsNoTracking().FirstOrDefaultAsync(p => p.PatientId == patientId && p.IsActive);
        if (patient == null) return null;
        var branchId = patient.BranchId ?? 1;
        int? age = patient.DateOfBirth is { } dob ? (int)((DateTime.Today - dob.Date).TotalDays / 365.25) : null;
        var gender = string.IsNullOrWhiteSpace(patient.Gender) ? null : patient.Gender.Trim();

        HttpContext.Items[EmrApiTokenHandler.PatientIdItem] = patientId;
        var rateList = (await labOrderApiClient.GetAvailableInvestigationsAsync(branchId, null, null, null, gender, age, "B2C"))
            .Where(t => t.MRP > 0).ToList();

        // what the rate list does not carry: category and fasting of a test, and the tests in a profile / package
        var testIds = rateList.Where(t => !t.IsPackage).Select(t => t.InvestigationId).ToList();
        var profileIds = rateList.Where(t => t.ProfileId is > 0).Select(t => t.ProfileId!.Value).Distinct().ToList();
        var con = dbContext.Database.GetDbConnection();
        var tests = (await con.QueryAsync<(int Id, int? CategoryId, string? CategoryName, bool Fasting)>(
            @"SELECT i.Test_ID, i.Category_ID, c.Category_Name, CAST(ISNULL(i.Is_Fasting_Required, 0) AS BIT)
                FROM dbo.LabInvestigationMaster i LEFT JOIN dbo.LabTestCategoryMaster c ON c.Category_ID = i.Category_ID
               WHERE i.Test_ID IN @Ids", new { Ids = testIds.DefaultIfEmpty(0) })).ToDictionary(x => x.Id);
        var includes = (await con.QueryAsync<(int ProfileId, string TestName)>(
            @"SELECT d.Profile_ID, i.Test_Name FROM dbo.LabInvestigationProfileDetail d
                JOIN dbo.LabInvestigationMaster i ON i.Test_ID = d.Test_ID
               WHERE ISNULL(d.IsDeleted, 0) = 0 AND d.Profile_ID IN @Ids ORDER BY d.Profile_ID, d.Sequence",
            new { Ids = profileIds.DefaultIfEmpty(0) })).GroupBy(x => x.ProfileId).ToDictionary(g => g.Key, g => g.Select(x => x.TestName).ToList());

        var items = rateList.Select(t =>
        {
            tests.TryGetValue(t.InvestigationId, out var info);
            var kind = t.IsPackage ? "Package" : t.IsProfileTest ? "Profile" : "Test";
            return new LabMenuEntry(
                (t.IsPackage ? "P" : "T") + t.InvestigationId, kind, t.InvestigationId, t.TestCode, t.TestName, t.MRP, t.TATHours,
                !t.IsPackage && info.Fasting, t.SampleType, t.Method, t.IsPackage ? null : info.CategoryId, t.IsPackage ? null : info.CategoryName,
                t.ProfileId is int pid && includes.TryGetValue(pid, out var list) ? list : new List<string>());
        }).OrderBy(i => i.Name).ToList();
        return new PatientLabMenu(branchId, patient, items);
    }

    // ── Online LAB booking: LAB > B2C Booking for the signed-in patient ────────────────────────────────────────
    // Only items on the branch rate list, at the branch rate (usp_CreateLabOrder refuses anything else). The order is a
    // booking ("Is Booking Req": its date and time, a booking number), left Due; a home collection without a phlebotomist
    // is listed in LAB > Home Collection Dispatch at the patient's home collection address.

    public sealed record LabBookingItem(string Kind, int Id);
    public sealed record LabBookingRequest(List<LabBookingItem> Items, string CollectionMode, DateTime Date, string SlotStart, string? Address);

    // POST api/patient-app/lab/bookings
    [HttpPost("lab/bookings")]
    public Task<IActionResult> BookLab([FromBody] LabBookingRequest req) => AsPatient(async patientId =>
    {
        if (req.Items is not { Count: > 0 }) return BadRequest(Fail("NO_TESTS", "Add at least one test."));
        var home = string.Equals(req.CollectionMode, "home", StringComparison.OrdinalIgnoreCase);
        if (!TimeSpan.TryParse(req.SlotStart, out var start)) return BadRequest(Fail("BAD_SLOT", "Choose a collection time."));
        var bookingAt = req.Date.Date.Add(start);
        if (bookingAt < DateTime.Now.AddMinutes(-2)) return BadRequest(Fail("PAST_TIME", "Choose a collection time that has not passed."));
        if (home && string.IsNullOrWhiteSpace(req.Address)) return BadRequest(Fail("NO_ADDRESS", "Enter the address for home collection."));

        var menu = await LabMenuAsync(patientId);
        if (menu == null) return Unauthorized(Fail("UNAUTHENTICATED", "Please sign in again."));

        // priced from the branch rate list, never from the app
        var lines = new List<LabOrderItemRequestDto>();
        foreach (var it in req.Items.DistinctBy(i => (i.Kind, i.Id)))
        {
            var key = (string.Equals(it.Kind, "Package", StringComparison.OrdinalIgnoreCase) ? "P" : "T") + it.Id;
            var m = menu.Items.FirstOrDefault(x => x.Key == key);
            if (m == null) return BadRequest(Fail("NOT_ON_RATE_LIST", "One of the tests is no longer offered online. Remove it and try again."));
            lines.Add(new LabOrderItemRequestDto
            {
                InvestigationId = m.Id, Code = m.Code, TestCode = m.Code, Name = m.Name, TestName = m.Name, Price = m.Rate,
                Type = m.Kind == "Package" ? "P" : "I", IsPackage = m.Kind == "Package"
            });
        }

        var patient = menu.Patient;
        if (home && !string.Equals(patient.HomeCollectionAddress?.Trim(), req.Address!.Trim(), StringComparison.Ordinal))
            await dbContext.Database.GetDbConnection().ExecuteAsync(   // as the counter's booking saves it; Dispatch reads it from here
                "UPDATE dbo.PatientMaster SET HomeCollectionAddress = @Address WHERE PatientId = @Id", new { Address = req.Address!.Trim(), Id = patientId });

        HttpContext.Items[EmrApiTokenHandler.PatientIdItem] = patientId;
        LabOrderResponseDto order;
        try
        {
            order = await labOrderApiClient.CreateOrderAsync(new LabOrderRequestDto
            {
                PatientId = patientId, BranchId = menu.BranchId, CollectionType = home ? "Home Collection" : "Lab",
                BookingDate = bookingAt, IsBookingRequired = true, Items = lines
            });
        }
        catch (InvalidOperationException ex)
        {
            return BadRequest(Fail("REFUSED", ex.Message));   // a billing rule of usp_CreateLabOrder
        }

        // as LAB > B2C Booking: samples, ledger, GST, audit trail, then the bill by WhatsApp / e-mail
        var total = lines.Sum(x => x.Price);
        await labOrderApiClient.CreateSampleCollectionAsync(order.LabOrderId, menu.BranchId, patient.CompanyId, null);
        await ledgerService.PostLabBillLedgerAsync(order.LabOrderId, total, menu.BranchId, patient.CompanyId, null, order.BillNo);
        try
        {
            await dbContext.Database.GetDbConnection().ExecuteAsync("dbo.usp_Ledger_SyncLabGst",
                new { order.LabOrderId, UserId = (int?)null }, commandType: System.Data.CommandType.StoredProcedure);
        }
        catch (Exception ex) { logger.LogError(ex, "GST ledger sync failed for LabOrderId {LabOrderId}", order.LabOrderId); }

        var name = ((patient.Salutation ?? "") + " " + patient.FirstName + " " + patient.LastName).Trim();
        await auditLogService.LogActivityAsync(
            eventType: "LAB Billing", actionName: "LAB.OrderBooked",
            description: $"Lab Order Bill {order.BillNo} booked from the patient app for {name} ({patient.PatientCode}). Total Items: {lines.Count}. Total: ₹{total:F2}. {(home ? "Home collection" : "Lab visit")} on {bookingAt:dd MMM yyyy hh:mm tt}.",
            userId: null, branchId: menu.BranchId, moduleCode: "LAB", referenceNo: order.BillNo, referenceId: order.LabOrderId, patientCode: patient.PatientCode,
            metadata: new { order.LabOrderId, order.BillNo, order.BookingNo, order.TokenNo, TotalAmount = total, ItemCount = lines.Count,
                            Items = lines.Select(x => new { x.InvestigationId, x.Price, x.Type }), CollectionType = home ? "Home Collection" : "Lab", Source = "PatientApp" });
        labBookingNotifier.Queue(menu.BranchId, order.LabOrderId, order.BillNo, patient.EmailId, name, Host);

        return Ok(new
        {
            success = true,
            data = new { order.LabOrderId, orderNo = order.BookingNo ?? order.BillNo, order.BillNo, order.BookingNo, amount = total,
                         collectionDate = bookingAt.Date, collectionSlot = req.SlotStart, collectionMode = home ? "home" : "lab" }
        });
    });

    // ── Online OPD booking: OPD > New Service Booking for the signed-in patient ─────────────────────────────────
    // The visit is booked at the patient's registered branch. As at the counter, booking makes the OPD bill with the
    // chosen consultation and leaves it Due; the token is issued once the bill is paid (at once for a ₹0 bill).

    // GET api/patient-app/opd/doctors - OPD doctors of the patient's branch with their consultation fees
    [HttpGet("opd/doctors")]
    public Task<IActionResult> OpdDoctors() => AsPatient(async patientId =>
    {
        var branchId = await PatientBranchAsync(patientId);
        HttpContext.Items[EmrApiTokenHandler.PatientIdItem] = patientId;
        try
        {
            using var res = await httpClientFactory.CreateClient("EmrApi").GetAsync($"api/doctors?branchId={branchId}&pageSize=500");
            if (!res.IsSuccessStatusCode) return StatusCode(503, Fail("UNAVAILABLE", "Doctors could not be loaded. Please try again."));
            using var doc = System.Text.Json.JsonDocument.Parse(await res.Content.ReadAsStringAsync());
            var doctors = new List<object>();
            foreach (var d in doc.RootElement.GetProperty("data").GetProperty("items").EnumerateArray())
            {
                if (!d.GetProperty("isActive").GetBoolean() || !d.GetProperty("hasOPDDept").GetBoolean()) continue;
                var id = d.GetProperty("doctorId").GetInt32();
                var fees = (await consultingFeeService.GetByDoctorAsync(id, branchId)).ToList();
                if (fees.Count == 0) continue;   // nothing to bill a consultation with at this branch
                doctors.Add(new
                {
                    doctorId = id,
                    fullName = Str(d, "fullName"),
                    gender = Str(d, "gender"),
                    specialityId = d.TryGetProperty("primarySpecialityId", out var sp) && sp.ValueKind == System.Text.Json.JsonValueKind.Number ? sp.GetInt32() : (int?)null,
                    speciality = Str(d, "primarySpecialityName") ?? Str(d, "primarySpeciality"),
                    departments = Str(d, "departmentNames"),
                    fees = fees.Select(f => new { f.ServiceId, f.ItemName, charges = f.ItemCharges, f.ConsultingType })
                });
            }
            return Ok(new { success = true, branchId, doctors });
        }
        catch (HttpRequestException ex)
        {
            logger.LogWarning(ex, "[PATIENT-APP] Doctors for branch {BranchId} failed", branchId);
            return StatusCode(503, Fail("UNAVAILABLE", "The service is unavailable. Please try again."));
        }
    });

    // GET api/patient-app/opd/slots?doctorId=2&date=2026-11-08 - the doctor's slots on a day (Doctor Schedule)
    [HttpGet("opd/slots")]
    public Task<IActionResult> OpdSlots(int doctorId, DateTime date) => AsPatient(async patientId =>
    {
        var slots = await SlotsAsync(patientId, doctorId, date);
        return slots is null
            ? StatusCode(503, Fail("UNAVAILABLE", "The doctor's schedule could not be loaded. Please try again."))
            : Content(slots, "application/json");
    });

    public sealed record OpdBookingRequest(int DoctorId, int ScheduleId, DateTime Date, string SlotTime, int ServiceId);

    // POST api/patient-app/opd/bookings - book the visit
    [HttpPost("opd/bookings")]
    public Task<IActionResult> BookOpd([FromBody] OpdBookingRequest req) => AsPatient(async patientId =>
    {
        var patient = await dbContext.PatientMasters.AsNoTracking().FirstOrDefaultAsync(p => p.PatientId == patientId && p.IsActive);
        if (patient == null) return Unauthorized(Fail("UNAUTHENTICATED", "Please sign in again."));
        var branchId = patient.BranchId ?? 1;
        if (req.Date.Date < DateTime.Today) return BadRequest(Fail("PAST_DATE", "Choose today or a later day."));

        // the slot must still be open, and the consultation must be one of the doctor's at this branch
        var slotsJson = await SlotsAsync(patientId, req.DoctorId, req.Date);
        if (slotsJson is null) return StatusCode(503, Fail("UNAVAILABLE", "The doctor's schedule could not be checked. Please try again."));
        using (var sd = System.Text.Json.JsonDocument.Parse(slotsJson))
        {
            var slot = sd.RootElement.GetProperty("data").GetProperty("slots").EnumerateArray()
                .FirstOrDefault(x => x.GetProperty("scheduleId").GetInt32() == req.ScheduleId && Str(x, "slotTime") == req.SlotTime);
            if (slot.ValueKind != System.Text.Json.JsonValueKind.Object || !slot.GetProperty("isAvailable").GetBoolean() ||
                (slot.TryGetProperty("isPast", out var past) && past.GetBoolean()))
                return Conflict(Fail("SLOT_TAKEN", "This time is no longer available. Please pick another slot."));
        }
        var fee = (await consultingFeeService.GetByDoctorAsync(req.DoctorId, branchId)).FirstOrDefault(f => f.ServiceId == req.ServiceId);
        if (fee == null) return BadRequest(Fail("FEE_NOT_FOUND", "Choose one of the doctor's consultations."));
        // the schedule gives "09:30" or "09:30 AM"
        if (!TimeSpan.TryParse(req.SlotTime, out var time))
        {
            if (!DateTime.TryParse(req.SlotTime, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out var t))
                return BadRequest(Fail("BAD_SLOT", "The slot time is not valid."));
            time = t.TimeOfDay;
        }

        var con = dbContext.Database.GetDbConnection();
        if (await con.ExecuteScalarAsync<int>(
                @"SELECT COUNT(1) FROM PatientOPDService WHERE PatientId = @P AND ConsultingDoctorId = @D AND IsActive = 1
                    AND Status <> 'Cancelled' AND CAST(VisitDate AS DATE) = @Day", new { P = patientId, D = req.DoctorId, Day = req.Date.Date }) > 0)
            return Conflict(Fail("ALREADY_BOOKED", "You already have a visit booked with this doctor on that day."));

        var bill = new PatientOPDService
        {
            PatientId = patientId, BranchId = branchId, ConsultingDoctorId = req.DoctorId, ScheduleId = req.ScheduleId,
            VisitDate = req.Date.Date.Add(time), AppointmentTime = time
        };
        var lineItems = System.Text.Json.JsonSerializer.Serialize(new[]
        {
            new OPDServiceLineItem { ServiceType = "Consulting", ServiceId = fee.ServiceId, ItemName = fee.ItemName, ServiceCharges = fee.ItemCharges }
        });
        var (billNo, tokenNo, opdServiceId) = await patientService.CreateServiceBookingOnlyAsync(bill, lineItems, null);

        // as OPD > New Service Booking: the ledger entry, the audit trail and the confirmation by WhatsApp / e-mail
        var total = await con.ExecuteScalarAsync<decimal?>("SELECT TotalAmount FROM dbo.PatientOPDService WHERE OPDServiceId = @Id", new { Id = opdServiceId }) ?? 0;
        await ledgerService.PostOpdBillLedgerAsync(opdServiceId, total, branchId, patient.CompanyId, null, billNo);
        var name = $"{patient.FirstName} {patient.LastName}".Trim();
        await auditLogService.LogActivityAsync(
            eventType: "OPD Billing", actionName: "OPD.ServiceBooking",
            description: $"OPD Service Booking bill {billNo} created from the patient app for {name} ({patient.PatientCode}). Token: {(string.IsNullOrEmpty(tokenNo) ? "Pending Payment" : tokenNo)}.",
            userId: null, branchId: branchId, moduleCode: "OPD", referenceNo: billNo, referenceId: opdServiceId, patientCode: patient.PatientCode,
            metadata: new { BillNo = billNo, TokenNo = tokenNo, OPDServiceId = opdServiceId, PatientCode = patient.PatientCode, PatientName = name, Source = "PatientApp" });
        bookingNotifier.Queue(branchId, opdServiceId, Host);

        return Ok(new
        {
            success = true,
            data = new { opdServiceId, billNo, tokenNo, visitDate = req.Date.Date, slotTime = req.SlotTime, amount = total, consultation = fee.ItemName }
        });
    });

    // GET api/patient-app/opd-visits/5/workflow - where an OPD visit is, from booking to the end of the consultation
    [HttpGet("opd-visits/{opdServiceId:int}/workflow")]
    public Task<IActionResult> OpdWorkflow(int opdServiceId) => AsPatient(async patientId =>
    {
        if (!await OwnsVisitAsync(opdServiceId, patientId)) return NotFound(Fail("NOT_FOUND", "Visit not found."));
        HttpContext.Items[EmrApiTokenHandler.PatientIdItem] = patientId;
        try
        {
            using var res = await httpClientFactory.CreateClient("EmrApi").GetAsync($"api/opd-visits/{opdServiceId}/workflow");
            return new ContentResult { Content = await res.Content.ReadAsStringAsync(), ContentType = "application/json", StatusCode = (int)res.StatusCode };
        }
        catch (HttpRequestException ex)
        {
            logger.LogWarning(ex, "[PATIENT-APP] OPD workflow {OpdServiceId} failed", opdServiceId);
            return StatusCode(503, Fail("UNAVAILABLE", "The service is unavailable. Please try again."));
        }
    });

    // GET api/patient-app/links/lab-report/5 - the bill's approved reports (Lab Report and/or Microbiology Report), each
    // with a download link, once the report is the patient's to have (ReportBlockAsync); otherwise why not yet
    [HttpGet("links/lab-report/{labOrderId:int}")]
    public Task<IActionResult> LabReportLink(int labOrderId) => AsPatient(async patientId =>
    {
        if (!await OwnsLabOrderAsync(labOrderId, patientId)) return NotFound(Fail("NOT_FOUND", "Bill not found."));
        if (await ReportBlockAsync(labOrderId) is { } why) return Ok(new { success = false, message = why, reports = Array.Empty<object>() });

        var reports = (await documents.ReportTypesAsync(labOrderId)).Select(type => new
        {
            type,
            title = type == LabReportTypes.Template ? "Microbiology Report" : "Lab Report",
            url = $"{Host}/api/patient-app/files/lab-report/{labOrderId}?type={Uri.EscapeDataString(type)}&t={Ticket(patientId, $"report:{labOrderId}")}"
        }).ToList();
        return Ok(new { success = reports.Count > 0, message = reports.Count > 0 ? null : "The report is not available yet.", reports });
    });

    // GET api/patient-app/files/lab-report/5?t= - the PDF itself (the link above)
    [HttpGet("files/lab-report/{labOrderId:int}")]
    public async Task<IActionResult> LabReportFile(int labOrderId, string? type, string? t)
    {
        var patientId = await TicketPatientAsync(t, $"report:{labOrderId}");
        if (patientId is null) return Content("This link has expired. Open the report again from the app.");
        if (await ReportBlockAsync(labOrderId) is { } why) return Content(why);
        try
        {
            var file = await documents.LabReportAsync(labOrderId, patientId.Value, string.IsNullOrEmpty(type) ? null : type, digitalCopy: true);
            if (file.Pdf is not { } pdf) return Content(file.Message ?? "The report is not available yet.");
            Response.Headers["Content-Disposition"] = $"inline; filename=\"{file.FileName}\"";
            return File(pdf, "application/pdf");
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "[PATIENT-APP] Report of LAB order {LabOrderId} for patient {PatientId} failed", labOrderId, patientId);
            return Content("The report could not be prepared right now. Please try again.");
        }
    }

    // GET api/patient-app/links/prescription?opdServiceId=5&doctorId=2 - the EMR prescription print of a visit
    [HttpGet("links/prescription")]
    public Task<IActionResult> PrescriptionLink(int opdServiceId, int doctorId) => AsPatient(async patientId =>
    {
        if (!await OwnsVisitAsync(opdServiceId, patientId)) return NotFound(Fail("NOT_FOUND", "Visit not found."));
        var secret = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes($"prescription-{opdServiceId}-{doctorId}-emr"));
        return Ok(new { success = true, url = $"{Host}/OPD/PrintPrescriptionAnonymous?opdServiceId={opdServiceId}&doctorId={doctorId}&secret={Uri.EscapeDataString(secret)}" });
    });

    // GET api/patient-app/links/opd-bill/5 and links/lab-bill/5 - the bill prints, as the portal's Bill buttons
    [HttpGet("links/opd-bill/{id:int}")]
    public Task<IActionResult> OpdBillLink(int id) => AsPatient(async patientId =>
    {
        if (!await OwnsVisitAsync(id, patientId)) return NotFound(Fail("NOT_FOUND", "Bill not found."));
        return Ok(new { success = true, url = $"{Host}/OPD/PrintBillAnonymous?id={id}&secret={Uri.EscapeDataString(BillSecret(id))}" });
    });

    [HttpGet("links/lab-bill/{id:int}")]
    public Task<IActionResult> LabBillLink(int id) => AsPatient(async patientId =>
    {
        if (!await OwnsLabOrderAsync(id, patientId)) return NotFound(Fail("NOT_FOUND", "Bill not found."));
        return Ok(new { success = true, url = $"{Host}/LabOrderBooking/PrintBillAnonymous?labOrderId={id}&secret={Uri.EscapeDataString($"lab_print_{id}")}" });
    });

    // ── helpers ──────────────────────────────────────────────────────────

    /// <summary>
    /// Why the report is not the patient's yet, by the rules of the patient's WhatsApp copy (LabReportWhatsAppService):
    /// a franchise bill without "Notification Required" is handed over by the franchise, and the report goes out only once
    /// every reportable test is approved. The paid check comes with the PDF itself (PatientDocumentService). Null = allowed.
    /// </summary>
    private async Task<string?> ReportBlockAsync(int labOrderId)
    {
        var st = await documents.ReportStateAsync(labOrderId);
        if (st == null) return "Bill not found.";
        if (st.IsB2B && !st.NotificationAllowed) return "This report is handed over by the centre where your sample was collected.";
        if (!st.IsFinal || st.FinalApprovedOn == null)
            return $"Your report will be ready once all your tests are approved ({st.ApprovedTests} of {st.TotalTests} approved).";
        return null;
    }

    private async Task<IActionResult> AsPatient(Func<int, Task<IActionResult>> action)
    {
        var header = Request.Headers.Authorization.ToString();
        var token = header.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) ? header[7..].Trim() : "";
        var identity = await tokens.ValidateAsync(token, TokenUse.Patient);
        if (identity is null || !int.TryParse(identity.FindFirst(TokenUse.PatientIdClaim)?.Value, out var patientId) || patientId <= 0)
        {
            Response.Headers.WWWAuthenticate = "Bearer";
            return Unauthorized(Fail("UNAUTHENTICATED", "Please sign in again."));
        }
        return await action(patientId);
    }

    private string Ticket(int patientId, string doc) => tokens.CreateToken(new[]
    {
        new Claim(TokenUse.PatientIdClaim, patientId.ToString()),
        new Claim(TokenUse.DocumentClaim, doc)
    }, TokenUse.PatientDocument, TicketLifetime);

    private async Task<int?> TicketPatientAsync(string? ticket, string doc)
    {
        var identity = await tokens.ValidateAsync(ticket ?? "", TokenUse.PatientDocument);
        if (identity?.FindFirst(TokenUse.DocumentClaim)?.Value != doc) return null;
        return int.TryParse(identity.FindFirst(TokenUse.PatientIdClaim)?.Value, out var id) ? id : null;
    }

    private async Task<int> PatientBranchAsync(int patientId) =>
        await dbContext.PatientMasters.Where(p => p.PatientId == patientId).Select(p => p.BranchId).FirstOrDefaultAsync() ?? 1;

    /// <summary>The doctor's slots on a day from EMR.Api (Doctor Schedule) at the patient's branch, as JSON; null when unreachable.</summary>
    private async Task<string?> SlotsAsync(int patientId, int doctorId, DateTime date)
    {
        var branchId = await PatientBranchAsync(patientId);
        HttpContext.Items[EmrApiTokenHandler.PatientIdItem] = patientId;
        try
        {
            using var res = await httpClientFactory.CreateClient("EmrApi")
                .GetAsync($"api/doctorschedules/availableslots?doctorId={doctorId}&branchId={branchId}&date={date:yyyy-MM-dd}");
            return res.IsSuccessStatusCode ? await res.Content.ReadAsStringAsync() : null;
        }
        catch (HttpRequestException ex)
        {
            logger.LogWarning(ex, "[PATIENT-APP] Slots of doctor {DoctorId} on {Date} failed", doctorId, date);
            return null;
        }
    }

    private static string? Str(System.Text.Json.JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == System.Text.Json.JsonValueKind.String ? v.GetString() : null;

    private Task<bool> OwnsVisitAsync(int opdServiceId, int patientId) =>
        OwnsAsync("SELECT COUNT(1) FROM PatientOPDService WHERE OPDServiceId = @Id AND PatientId = @P AND IsActive = 1", opdServiceId, patientId);

    private Task<bool> OwnsLabOrderAsync(int labOrderId, int patientId) =>
        OwnsAsync("SELECT COUNT(1) FROM LabOrder WHERE LabOrderId = @Id AND PatientId = @P AND IsActive = 1", labOrderId, patientId);

    private async Task<bool> OwnsAsync(string sql, int id, int patientId) =>
        await dbContext.Database.GetDbConnection().ExecuteScalarAsync<int>(sql, new { Id = id, P = patientId }) > 0;

    // the OPD bill print's link secret (OPDController.PrintBillAnonymous)
    private static string BillSecret(int id) => Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes($"bill-{id}-emr"));

    private string Host => $"{Request.Scheme}://{Request.Host}";

    private static object Fail(string code, string message) => new { success = false, code, message };
}
