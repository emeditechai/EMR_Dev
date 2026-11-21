using System.Data;
using System.Security.Claims;
using EMR.Api.PatientApp;
using EMR.Shared.Security;
using Microsoft.AspNetCore.Authorization;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Security;
using EMR.Api.Services;
using EMR.Common;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>
/// The patient app (EMRPatientPortal) for the signed-in patient (a patient token from api/auth/patient-login), or for a
/// dependent the head of family picks (X-Patient-Id, PatientAppAttribute). The same paths and answers the app had from
/// EMR.Web's api/patient-app, so the app needs only this API.
/// </summary>
[ApiController]
[Route("api/patient-app")]
[PatientApp]
[Produces("application/json")]
public sealed partial class PatientAppController(
    IDbConnectionFactory db,
    ILabOrderService labOrderService,
    IDoctorService doctorService,
    IDoctorScheduleService scheduleService,
    IOpdVisitHistoryService opdVisitService,
    ILedgerService ledgerService,
    IPatientAppNotices notices,
    IPatientDocumentService documents,
    IApiTokenService tokens,
    IConfiguration config,
    ILogger<PatientAppController> logger) : ControllerBase
{
    private int PatientId => (int)HttpContext.Items[PatientAppAttribute.PatientIdItem]!;

    private static object Fail(string code, string message) => new { success = false, code, message };

    /// <summary>The patient's row: who they are, their branch, and where a home collection goes.</summary>
    private sealed class PatientRow
    {
        public int PatientId { get; set; }
        public string? PatientCode { get; set; }
        public string? Salutation { get; set; }
        public string? FirstName { get; set; }
        public string? LastName { get; set; }
        public string? Gender { get; set; }
        public DateTime? DateOfBirth { get; set; }
        public string? PhoneNumber { get; set; }
        public string? EmailId { get; set; }
        public string? Address { get; set; }
        public string? HomeCollectionAddress { get; set; }
        public int? RelationId { get; set; }
        public int? BranchId { get; set; }
        public int? CompanyId { get; set; }
        public int? CreatedBy { get; set; }
        public int? ReferralDoctorId { get; set; }
        public bool IsActive { get; set; }
        public string FullName => ((Salutation ?? "") + " " + FirstName + " " + LastName).Trim();
    }

    private async Task<PatientRow?> PatientAsync(IDbConnection con, int patientId) =>
        await con.QueryFirstOrDefaultAsync<PatientRow>(
            @"SELECT PatientId, PatientCode, Salutation, FirstName, LastName, Gender, DateOfBirth, PhoneNumber, EmailId, Address,
                     HomeCollectionAddress, RelationId, BranchId, CompanyId, CreatedBy, ReferralDoctorId, CAST(ISNULL(IsActive, 0) AS BIT) AS IsActive
                FROM dbo.PatientMaster WHERE PatientId = @Id", new { Id = patientId });

    /// <summary>Whether a LAB bill's report is the patient's to have (the WhatsApp copy's rule, usp_LabReportWhatsApp_GetState).</summary>
    private sealed class ReportState
    {
        public int TotalTests { get; set; }
        public int ApprovedTests { get; set; }
        public bool IsFinal { get; set; }
        public DateTime? FinalApprovedOn { get; set; }
        public bool IsB2B { get; set; }
        public bool NotificationAllowed { get; set; }
    }

    private static Task<ReportState?> ReportStateAsync(IDbConnection con, int labOrderId) =>
        con.QueryFirstOrDefaultAsync<ReportState?>("dbo.usp_LabReportWhatsApp_GetState", new { LabOrderId = labOrderId },
            commandType: CommandType.StoredProcedure);

    // GET api/patient-app/records - visits, LAB bills, billing, family and membership of the patient
    [HttpGet("records")]
    public async Task<IActionResult> Records()
    {
        var patientId = PatientId;
        using var con = db.CreateConnection();
        var p = await PatientAsync(con, patientId);
        if (p == null || !p.IsActive) return Unauthorized(Fail("UNAUTHENTICATED", "Please sign in again."));

        var visits = await Safe(() => PatientRecordQueries.VisitsAsync(con, patientId), []);
        var lab = await Safe(() => PatientRecordQueries.LabOrdersAsync(con, patientId), []);
        var links = await Safe(() => PatientRecordQueries.LinksAsync(con, patientId, p.PhoneNumber, p.RelationId, p.BranchId, p.CreatedBy,
            p.ReferralDoctorId, p.CompanyId), new PatientLinks());

        var labOrders = new List<object>();
        foreach (var l in lab)
        {
            var st = await ReportStateAsync(con, l.LabOrderId);
            labOrders.Add(new
            {
                labOrderId = l.LabOrderId, orderDate = l.OrderDate, billNo = l.BillNo, totalAmount = l.TotalAmount,
                discountAmount = l.DiscountAmount, paidAmount = l.PaidAmount, paymentStatus = l.PaymentStatus,
                approvedTestCount = l.ApprovedTestCount,
                totalTests = st?.TotalTests ?? 0, approvedTests = st?.ApprovedTests ?? 0, isFinal = st?.IsFinal ?? false,
                finalApprovedOn = st?.FinalApprovedOn, reportByPartner = st is { IsB2B: true, NotificationAllowed: false }
            });
        }

        var card = links.MembershipCards.FirstOrDefault(c => c.EffectiveStatus == "Active") ?? links.MembershipCards.FirstOrDefault();
        var headOfFamily = p.RelationId == 1 ? null : links.Family.FirstOrDefault(f => f.IsSelf);
        return Ok(new
        {
            success = true,
            visits = visits.Select(v => new
            {
                opdServiceId = v.OPDServiceId, visitDate = v.VisitDate, billNo = v.OPDBillNo, tokenNo = v.TokenNo,
                totalAmount = v.TotalAmount, status = v.Status, paymentStatus = v.PaymentStatus,
                doctorName = v.ConsultingDoctorName, services = v.ServiceTypesSummary
            }),
            labOrders,
            billing = links.BillingSummary,
            // where a home collection goes (LAB > Home Collection Dispatch reads the same)
            homeCollectionAddress = !string.IsNullOrWhiteSpace(p.HomeCollectionAddress) ? p.HomeCollectionAddress
                                  : !string.IsNullOrWhiteSpace(p.Address) ? p.Address : null,
            family = new
            {
                phone = p.PhoneNumber,
                isHead = p.RelationId == 1,
                relationName = links.RelationName,
                head = headOfFamily == null ? null : new { headOfFamily.PatientId, headOfFamily.FullName, headOfFamily.PatientCode },
                members = links.Family.Select(f => new
                {
                    f.PatientId, f.PatientCode, f.FullName, f.Gender, f.DateOfBirth, f.RelationName, f.IsSelf, f.IsActive,
                    onCard = card != null && links.CardMembers.Any(m => m.CardId == card.CardId && m.PatientId == f.PatientId && m.IsActive)
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
                    members = links.CardMembers.Where(m => m.CardId == card.CardId).Select(m => new
                    {
                        m.PatientId, m.PatientCode, m.FullName, m.Relation, m.IsPrimary, m.IsActive, isYou = m.PatientId == patientId
                    })
                },
                others = links.MembershipCards.Where(c => card == null || c.CardId != card.CardId)
                    .Select(c => new { c.CardId, c.CardNo, c.PlanName, status = c.EffectiveStatus, c.ValidTo }),
                points = links.PointsLedger.Select(lp => new
                {
                    lp.CreatedDate, lp.CardNo, lp.TxnType, lp.Points, lp.Amount, lp.BalanceAfter, lp.ReceiptNo, lp.Narration
                })
            }
        });
    }

    // a section that cannot be read leaves the rest of the records (as the portal's profile does)
    private async Task<T> Safe<T>(Func<Task<T>> read, T fallback)
    {
        try { return await read(); }
        catch (Exception ex) { logger.LogWarning(ex, "[PATIENT-APP] A records section of patient {PatientId} failed", PatientId); return fallback; }
    }

    // GET api/patient-app/lab-workflow?ids=5,6 - the live stage of the patient's LAB bills (no staff names)
    [HttpGet("lab-workflow")]
    public async Task<IActionResult> LabWorkflow(string? ids)
    {
        var wanted = (ids ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries).Select(x => int.TryParse(x, out var v) ? v : 0)
            .Where(v => v > 0).Distinct().Take(50).ToList();
        var result = new List<object>();
        if (wanted.Count == 0) return Ok(new { success = true, data = result });

        using var con = db.CreateConnection();
        var own = (await con.QueryAsync<int>("SELECT LabOrderId FROM LabOrder WHERE PatientId = @P AND LabOrderId IN @Ids",
            new { P = PatientId, Ids = wanted })).ToHashSet();
        if (con is not System.Data.Common.DbConnection dbc) return Ok(new { success = true, data = result });
        foreach (var id in wanted.Where(own.Contains))
        {
            var wf = System.Text.Json.JsonSerializer.SerializeToElement(await LabOrderWorkflow.BuildAsync(dbc, id));
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
        return Ok(new { success = true, data = result });
    }

    // ── LAB menu: what the patient can book online - the items on the patient's branch B2C rate list, at the branch rate,
    //    with the gender / age rules of LAB > B2C Booking (usp_GetAvailableInvestigations, SQLScripts/2199) ──

    private sealed record LabMenuEntry(string Key, string Kind, int Id, string? Code, string Name, decimal Rate, string? TatHours, bool Fasting,
        string? SampleType, string? Method, int? CategoryId, string? CategoryName, List<string> Includes);

    private sealed record PatientLabMenu(int BranchId, PatientRow Patient, List<LabMenuEntry> Items);

    private async Task<PatientLabMenu?> LabMenuAsync(IDbConnection con, int patientId)
    {
        var patient = await PatientAsync(con, patientId);
        if (patient == null || !patient.IsActive) return null;
        var branchId = patient.BranchId ?? 1;
        int? age = patient.DateOfBirth is { } dob ? (int)((DateTime.Today - dob.Date).TotalDays / 365.25) : null;
        var gender = string.IsNullOrWhiteSpace(patient.Gender) ? null : patient.Gender.Trim();

        var rateList = (await labOrderService.GetAvailableInvestigationsAsync(branchId, null, null, null, gender, age, "B2C"))
            .Where(t => t.MRP > 0).ToList();

        // what the rate list does not carry: category and fasting of a test, and the tests in a profile / package
        var testIds = rateList.Where(t => !t.IsPackage).Select(t => t.InvestigationId).ToList();
        var profileIds = rateList.Where(t => t.ProfileId is > 0).Select(t => t.ProfileId!.Value).Distinct().ToList();
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

    // GET api/patient-app/lab-menu
    [HttpGet("lab-menu")]
    public async Task<IActionResult> LabMenu()
    {
        using var con = db.CreateConnection();
        var menu = await LabMenuAsync(con, PatientId);
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
    }

    public sealed record LabBookingItem(string Kind, int Id);
    public sealed record LabQuoteRequest(List<LabBookingItem> Items);

    /// <summary>A cart line priced from the branch rate list (never from the app); Key T{id} for a test / profile, P{id} for a package.</summary>
    private sealed record PricedLine(string Key, LabMenuEntry Item)
    {
        public bool IsPackage => Item.Kind == "Package";
    }

    // null when an item is no longer on the rate list
    private static List<PricedLine>? PriceCart(PatientLabMenu menu, IEnumerable<LabBookingItem> items)
    {
        var lines = new List<PricedLine>();
        foreach (var it in items.DistinctBy(i => (i.Kind, i.Id)))
        {
            var key = (string.Equals(it.Kind, "Package", StringComparison.OrdinalIgnoreCase) ? "P" : "T") + it.Id;
            var m = menu.Items.FirstOrDefault(x => x.Key == key);
            if (m == null) return null;
            lines.Add(new PricedLine(key, m));
        }
        return lines;
    }

    // The member's plan benefits on the cart, by the rules the counter's payment applies (LabMembershipBenefits,
    // usp_Membership_LabBenefits: benefit rules on tests and profiles - category, else department, else all tests - on
    // tests the rate card allows to be discounted; packages take none).
    private static Task<LabMemberBenefit?> CartBenefitAsync(IDbConnection con, int patientId, int branchId, List<PricedLine> lines) =>
        LabMembershipBenefits.ComputeAsync(con, patientId, branchId,
            lines.Select(l => new LabBenefitLineInput(l.Key, l.IsPackage ? "P" : "T", l.Item.Id, l.Item.Rate)));

    private static object Quote(List<PricedLine> lines, LabMemberBenefit? b)
    {
        var subTotal = lines.Sum(l => l.Item.Rate);
        var discount = Math.Min(subTotal, b?.TestDiscount ?? 0m);
        return new
        {
            subTotal, membershipDiscount = discount, netAmount = subTotal - discount,
            membership = b == null ? null : new
            {
                cardNo = b.CardNo, planName = b.PlanName,
                lines = b.Lines.Where(kv => kv.Value.Discount > 0).Select(kv => new { key = kv.Key, discount = kv.Value.Discount, rule = kv.Value.Rule })
            }
        };
    }

    // POST api/patient-app/lab/quote - the cart's bill before booking: the rate list prices and the member's plan discount
    [HttpPost("lab/quote")]
    public async Task<IActionResult> LabQuote([FromBody] LabQuoteRequest req)
    {
        using var con = db.CreateConnection();
        var menu = await LabMenuAsync(con, PatientId);
        if (menu == null) return Unauthorized(Fail("UNAUTHENTICATED", "Please sign in again."));
        var lines = PriceCart(menu, req.Items ?? []);
        if (lines == null) return BadRequest(Fail("NOT_ON_RATE_LIST", "One of the tests is no longer offered online. Remove it and try again."));
        return Ok(new { success = true, data = Quote(lines, await CartBenefitAsync(con, PatientId, menu.BranchId, lines)) });
    }

    // ── Online LAB booking: LAB > B2C Booking for the signed-in patient. Only items on the branch rate list, at the branch
    //    rate (usp_CreateLabOrder refuses anything else). The order is a booking ("Is Booking Req": its date and time, a
    //    booking number), left Due; a home collection without a phlebotomist is listed in LAB > Home Collection Dispatch at
    //    the patient's home collection address. ──

    public sealed record LabBookingRequest(List<LabBookingItem> Items, string CollectionMode, DateTime Date, string SlotStart, string? Address);

    // the user a booking from the app is recorded under (as the counter's API calls record a call without a user)
    private const int AppUserId = 1;

    // POST api/patient-app/lab/bookings
    [HttpPost("lab/bookings")]
    public async Task<IActionResult> BookLab([FromBody] LabBookingRequest req)
    {
        var patientId = PatientId;
        if (req.Items is not { Count: > 0 }) return BadRequest(Fail("NO_TESTS", "Add at least one test."));
        var home = string.Equals(req.CollectionMode, "home", StringComparison.OrdinalIgnoreCase);
        if (!TimeSpan.TryParse(req.SlotStart, out var start)) return BadRequest(Fail("BAD_SLOT", "Choose a collection time."));
        var bookingAt = req.Date.Date.Add(start);
        if (bookingAt < DateTime.Now.AddMinutes(-2)) return BadRequest(Fail("PAST_TIME", "Choose a collection time that has not passed."));
        if (home && string.IsNullOrWhiteSpace(req.Address)) return BadRequest(Fail("NO_ADDRESS", "Enter the address for home collection."));

        using var con = db.CreateConnection();
        var menu = await LabMenuAsync(con, patientId);
        if (menu == null) return Unauthorized(Fail("UNAUTHENTICATED", "Please sign in again."));

        // priced from the branch rate list, never from the app
        var priced = PriceCart(menu, req.Items);
        if (priced == null) return BadRequest(Fail("NOT_ON_RATE_LIST", "One of the tests is no longer offered online. Remove it and try again."));

        var patient = menu.Patient;
        if (home && !string.Equals(patient.HomeCollectionAddress?.Trim(), req.Address!.Trim(), StringComparison.Ordinal))
            await con.ExecuteAsync(   // as the counter's booking saves it; Dispatch reads it from here
                "UPDATE dbo.PatientMaster SET HomeCollectionAddress = @Address WHERE PatientId = @Id", new { Address = req.Address!.Trim(), Id = patientId });

        Models.LabOrderResponse order;
        try
        {
            order = await labOrderService.CreateOrderAsync(new Models.LabOrderRequest
            {
                PatientId = patientId, BranchId = menu.BranchId, CollectionType = home ? "Home Collection" : "Lab",
                BookingDate = bookingAt, IsBookingRequired = true,
                Items = priced.Select(p => new Models.LabOrderItemRequest
                {
                    InvestigationId = p.Item.Id, Price = p.Item.Rate, Type = p.IsPackage ? "P" : "I", IsPackage = p.IsPackage
                }).ToList()
            }, AppUserId);
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when ((ex.Number == 50000 && ex.Class == 16) || ex.Number is >= 56402 and <= 56404)
        {
            return BadRequest(Fail("REFUSED", ex.Message));   // a billing rule of usp_CreateLabOrder
        }

        // as LAB > B2C Booking: samples, ledger, GST, audit trail, then the bill by WhatsApp / e-mail
        var total = priced.Sum(x => x.Item.Rate);
        var companyId = patient.CompanyId ?? 1;
        await labOrderService.CreateSampleCollectionAsync(order.LabOrderId, menu.BranchId, companyId, AppUserId);
        await ledgerService.PostLabBillLedgerAsync(order.LabOrderId, total, menu.BranchId, companyId, null, order.BillNo);
        try
        {
            await con.ExecuteAsync("dbo.usp_Ledger_SyncLabGst", new { order.LabOrderId, UserId = (int?)null }, commandType: CommandType.StoredProcedure);
        }
        catch (Exception ex) { logger.LogError(ex, "GST ledger sync failed for LabOrderId {LabOrderId}", order.LabOrderId); }

        // the plan discount the counter's payment will give this bill (the payment works it out again from the saved bill)
        LabMemberBenefit? benefit = null;
        try { benefit = await CartBenefitAsync(con, patientId, menu.BranchId, priced); }
        catch (Exception ex) { logger.LogWarning(ex, "[PATIENT-APP] Membership benefit of LabOrderId {LabOrderId} could not be worked out", order.LabOrderId); }
        var memDiscount = Math.Min(total, benefit?.TestDiscount ?? 0m);

        var name = patient.FullName;
        await AuditAsync(con, "LAB Billing", "LAB.OrderBooked",
            $"Lab Order Bill {order.BillNo} booked from the patient app for {name} ({patient.PatientCode}). Total Items: {priced.Count}. Total: ₹{total:F2}{(memDiscount > 0 ? $" (membership card {benefit!.CardNo}: ₹{memDiscount:F2} off at payment)" : "")}. {(home ? "Home collection" : "Lab visit")} on {bookingAt:dd MMM yyyy hh:mm tt}.",
            menu.BranchId, companyId, "LAB", order.BillNo, order.LabOrderId, patient.PatientCode,
            new { order.LabOrderId, order.BillNo, order.BookingNo, order.TokenNo, TotalAmount = total, ItemCount = priced.Count,
                  Items = priced.Select(x => new { InvestigationId = x.Item.Id, Price = x.Item.Rate, Type = x.IsPackage ? "P" : "I" }),
                  CollectionType = home ? "Home Collection" : "Lab", Source = "PatientApp" });
        notices.QueueLabBooking(menu.BranchId, order.LabOrderId);

        return Ok(new
        {
            success = true,
            data = new { order.LabOrderId, orderNo = order.BookingNo ?? order.BillNo, order.BillNo, order.BookingNo,
                         amount = total - memDiscount, subTotal = total, membershipDiscount = memDiscount, membershipCard = benefit?.CardNo,
                         collectionDate = bookingAt.Date, collectionSlot = req.SlotStart, collectionMode = home ? "home" : "lab" }
        });
    }

    // ── OPD: the doctors of the patient's branch with their consultation fees, and a doctor's slots on a day ──

    private sealed class ConsultingFee
    {
        public int ServiceId { get; set; }
        public string? ItemName { get; set; }
        public decimal ItemCharges { get; set; }
        public string? ConsultingType { get; set; }
    }

    // the doctor's consultations at the branch (Doctor Master > Consulting Fee mapping)
    private static async Task<List<ConsultingFee>> FeesAsync(IDbConnection con, int doctorId, int branchId) =>
        (await con.QueryAsync<ConsultingFee>(@"
            SELECT m.ServiceId, s.ItemName, s.ItemCharges, s.ConsultingType
              FROM DoctorConsultingFeeMap m
             INNER JOIN ServiceMaster s ON s.ServiceId = m.ServiceId
             WHERE m.DoctorId = @doctorId AND m.BranchId = @branchId AND m.IsActive = 1
             ORDER BY s.ItemCode", new { doctorId, branchId })).ToList();

    private async Task<int> PatientBranchAsync(IDbConnection con, int patientId) =>
        await con.QueryFirstOrDefaultAsync<int?>("SELECT BranchId FROM dbo.PatientMaster WHERE PatientId = @Id", new { Id = patientId }) ?? 1;

    // GET api/patient-app/opd/doctors
    [HttpGet("opd/doctors")]
    public async Task<IActionResult> OpdDoctors()
    {
        using var con = db.CreateConnection();
        var branchId = await PatientBranchAsync(con, PatientId);
        var list = await doctorService.GetListAsync(null, branchId, null, 1, 500);
        var doctors = new List<object>();
        foreach (var d in list.Items)
        {
            if (!d.IsActive || !d.HasOPDDept) continue;
            var fees = await FeesAsync(con, d.DoctorId, branchId);
            if (fees.Count == 0) continue;   // nothing to bill a consultation with at this branch
            doctors.Add(new
            {
                doctorId = d.DoctorId,
                fullName = d.FullName,
                gender = d.Gender,
                specialityId = d.PrimarySpecialityId,
                speciality = string.IsNullOrEmpty(d.PrimarySpecialityName) ? d.PrimarySpeciality : d.PrimarySpecialityName,
                departments = d.DepartmentNames,
                fees = fees.Select(f => new { f.ServiceId, f.ItemName, charges = f.ItemCharges, f.ConsultingType })
            });
        }
        return Ok(new { success = true, branchId, doctors });
    }

    // GET api/patient-app/opd/slots?doctorId=2&date=2026-11-08 - the doctor's slots on a day (Doctor Schedule)
    [HttpGet("opd/slots")]
    public async Task<IActionResult> OpdSlots(int doctorId, DateTime date)
    {
        using var con = db.CreateConnection();
        var branchId = await PatientBranchAsync(con, PatientId);
        try
        {
            return Ok(Models.ApiResponse<Models.AvailableSlotsResult>.Ok(await scheduleService.GetAvailableSlotsAsync(doctorId, branchId, date)));
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "[PATIENT-APP] Slots of doctor {DoctorId} on {Date} failed", doctorId, date);
            return StatusCode(503, Fail("UNAVAILABLE", "The doctor's schedule could not be loaded. Please try again."));
        }
    }

    public sealed record OpdBookingRequest(int DoctorId, int ScheduleId, DateTime Date, string SlotTime, int ServiceId);

    // POST api/patient-app/opd/bookings - book the visit: as OPD > New Service Booking, the OPD bill with the chosen
    // consultation, left Due; the token is issued once the bill is paid (at once for a ₹0 bill)
    [HttpPost("opd/bookings")]
    public async Task<IActionResult> BookOpd([FromBody] OpdBookingRequest req)
    {
        var patientId = PatientId;
        using var con = db.CreateConnection();
        var patient = await PatientAsync(con, patientId);
        if (patient == null || !patient.IsActive) return Unauthorized(Fail("UNAUTHENTICATED", "Please sign in again."));
        var branchId = patient.BranchId ?? 1;
        if (req.Date.Date < DateTime.Today) return BadRequest(Fail("PAST_DATE", "Choose today or a later day."));

        // the slot must still be open, and the consultation must be one of the doctor's at this branch
        Models.AvailableSlotsResult slots;
        try { slots = await scheduleService.GetAvailableSlotsAsync(req.DoctorId, branchId, req.Date); }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "[PATIENT-APP] Slots of doctor {DoctorId} on {Date} failed", req.DoctorId, req.Date);
            return StatusCode(503, Fail("UNAVAILABLE", "The doctor's schedule could not be checked. Please try again."));
        }
        var slot = slots.Slots.FirstOrDefault(x => x.ScheduleId == req.ScheduleId && x.SlotTime == req.SlotTime);
        if (slot == null || !slot.IsAvailable || slot.IsPast)
            return Conflict(Fail("SLOT_TAKEN", "This time is no longer available. Please pick another slot."));
        var fee = (await FeesAsync(con, req.DoctorId, branchId)).FirstOrDefault(f => f.ServiceId == req.ServiceId);
        if (fee == null) return BadRequest(Fail("FEE_NOT_FOUND", "Choose one of the doctor's consultations."));
        // the schedule gives "09:30" or "09:30 AM"
        if (!TimeSpan.TryParse(req.SlotTime, out var time))
        {
            if (!DateTime.TryParse(req.SlotTime, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out var t))
                return BadRequest(Fail("BAD_SLOT", "The slot time is not valid."));
            time = t.TimeOfDay;
        }

        if (await con.ExecuteScalarAsync<int>(
                @"SELECT COUNT(1) FROM PatientOPDService WHERE PatientId = @P AND ConsultingDoctorId = @D AND IsActive = 1
                    AND Status <> 'Cancelled' AND CAST(VisitDate AS DATE) = @Day", new { P = patientId, D = req.DoctorId, Day = req.Date.Date }) > 0)
            return Conflict(Fail("ALREADY_BOOKED", "You already have a visit booked with this doctor on that day."));

        var (billNo, tokenNo, opdServiceId) = await OpdBookingWriter.CreateAsync(con, patientId, branchId, req.DoctorId, req.ScheduleId,
            req.Date.Date.Add(time), time, null,
            [new OpdBookingLine { ServiceType = "Consulting", ServiceId = fee.ServiceId, ItemName = fee.ItemName, ServiceCharges = fee.ItemCharges }], null);

        // as OPD > New Service Booking: the ledger entry, the audit trail and the confirmation by WhatsApp / e-mail
        var total = await con.ExecuteScalarAsync<decimal?>("SELECT TotalAmount FROM dbo.PatientOPDService WHERE OPDServiceId = @Id", new { Id = opdServiceId }) ?? 0;
        await ledgerService.PostOpdBillLedgerAsync(opdServiceId, total, branchId, patient.CompanyId, null, billNo);
        var name = $"{patient.FirstName} {patient.LastName}".Trim();
        await AuditAsync(con, "OPD Billing", "OPD.ServiceBooking",
            $"OPD Service Booking bill {billNo} created from the patient app for {name} ({patient.PatientCode}). Token: {(string.IsNullOrEmpty(tokenNo) ? "Pending Payment" : tokenNo)}.",
            branchId, patient.CompanyId ?? 1, "OPD", billNo, opdServiceId, patient.PatientCode,
            new { BillNo = billNo, TokenNo = tokenNo, OPDServiceId = opdServiceId, PatientCode = patient.PatientCode, PatientName = name, Source = "PatientApp" });
        notices.QueueOpdBooking(branchId, opdServiceId);

        return Ok(new
        {
            success = true,
            data = new { opdServiceId, billNo, tokenNo, visitDate = req.Date.Date, slotTime = req.SlotTime, amount = total, consultation = fee.ItemName }
        });
    }

    // the Audit History entry of a booking (dbo.AuditLogs, as EMR.Web's AuditLogService writes it), with no staff user
    private async Task AuditAsync(IDbConnection con, string eventType, string actionName, string description, int branchId, int companyId,
        string moduleCode, string? referenceNo, long referenceId, string? patientCode, object metadata)
    {
        try
        {
            var ip = Request.Headers["X-Forwarded-For"].FirstOrDefault()?.Split(',')[0].Trim() is { Length: > 0 } fwd ? fwd
                   : HttpContext.Connection.RemoteIpAddress?.ToString();
            if (ip is "::1" or "0:0:0:0:0:0:0:1") ip = "127.0.0.1";
            if (ip?.StartsWith("::ffff:", StringComparison.OrdinalIgnoreCase) == true) ip = ip[7..];
            await con.ExecuteAsync(@"
                INSERT dbo.AuditLogs (UserId, CompanyId, BranchId, EventType, ActionName, ControllerName, RoutePath, HttpMethod, IpAddress,
                                      UserAgent, Description, ModuleCode, ReferenceNo, ReferenceId, PatientCode, MetadataJson, CreatedDate)
                VALUES (NULL, @CompanyId, @BranchId, @EventType, @ActionName, 'PatientApp', @RoutePath, @HttpMethod, @Ip,
                        @UserAgent, @Description, @ModuleCode, @ReferenceNo, @ReferenceId, @PatientCode, @MetadataJson, GETDATE())",
                new { CompanyId = companyId, BranchId = branchId, EventType = eventType, ActionName = actionName, RoutePath = Request.Path.Value,
                      HttpMethod = Request.Method, Ip = ip, UserAgent = Request.Headers.UserAgent.ToString(), Description = description,
                      ModuleCode = moduleCode, ReferenceNo = referenceNo, ReferenceId = referenceId, PatientCode = patientCode,
                      MetadataJson = System.Text.Json.JsonSerializer.Serialize(metadata) });
        }
        catch (Exception ex) { logger.LogWarning(ex, "[PATIENT-APP] Audit entry {Action} not written", actionName); }
    }

    // GET api/patient-app/opd-visits/5/workflow - where an OPD visit is, from booking to the end of the consultation
    [HttpGet("opd-visits/{opdServiceId:int}/workflow")]
    public async Task<IActionResult> OpdWorkflow(int opdServiceId)
    {
        using var con = db.CreateConnection();
        var owns = await con.ExecuteScalarAsync<int>(
            "SELECT COUNT(1) FROM PatientOPDService WHERE OPDServiceId = @Id AND PatientId = @P AND IsActive = 1", new { Id = opdServiceId, P = PatientId }) > 0;
        if (!owns) return NotFound(Fail("NOT_FOUND", "Visit not found."));
        return Ok(await opdVisitService.WorkflowAsync(opdServiceId));
    }

    // ── Documents: the LAB report (whole bill per report, or one test), the Image report and the LAB / OPD bills as PDFs,
    //    drawn with QuestPDF here; a link carries a 10-minute ticket so the phone can download it without the token. The
    //    prescription and the bill prints the app shows on screen are EMR.Web pages ("PatientApp:WebBaseUrl"). ──

    private static readonly TimeSpan TicketLifetime = TimeSpan.FromMinutes(10);

    // this API, where the app downloads the PDFs from
    private string Host => $"{Request.Scheme}://{Request.Host}";

    // EMR.Web, where the prescription and bill print pages are
    private string WebHost => (config["PatientApp:WebBaseUrl"] is { Length: > 0 } w ? w : Host).TrimEnd('/');

    private static string BillSecret(int id) => Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes($"bill-{id}-emr"));

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

    private async Task<bool> OwnsAsync(string sql, int id, int patientId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int>(sql, new { Id = id, P = patientId }) > 0;
    }

    private Task<bool> OwnsVisitAsync(int opdServiceId, int patientId) =>
        OwnsAsync("SELECT COUNT(1) FROM PatientOPDService WHERE OPDServiceId = @Id AND PatientId = @P AND IsActive = 1", opdServiceId, patientId);

    private Task<bool> OwnsLabOrderAsync(int labOrderId, int patientId) =>
        OwnsAsync("SELECT COUNT(1) FROM LabOrder WHERE LabOrderId = @Id AND PatientId = @P AND IsActive = 1", labOrderId, patientId);

    /// <summary>
    /// Why the report is not the patient's yet, by the rules of the patient's WhatsApp copy: a franchise bill without
    /// "Notification Required" is handed over by the franchise, and the report goes out only once every reportable test is
    /// approved. The paid check comes with the PDF itself (PatientDocumentService). Null = allowed.
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

    private static string ReportTitle(string type) =>
        type == LabReportTypes.Template ? "Microbiology Report" : type == EMR.Api.PatientApp.PatientDocumentService.ImageType ? "Image Report" : "Lab Report";

    private IActionResult PdfOrMessage(PatientReportFile file)
    {
        if (file.Pdf is not { } pdf) return Content(file.Message ?? "The report is not available yet.");
        Response.Headers["Content-Disposition"] = $"inline; filename=\"{file.FileName}\"";
        return File(pdf, "application/pdf");
    }

    private async Task<IActionResult> PdfFileAsync(Func<Task<PatientReportFile>> make, string what, string logName)
    {
        try { return PdfOrMessage(await make()); }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "[PATIENT-APP] {Document} failed", logName);
            return Content($"The {what} could not be prepared right now. Please try again.");
        }
    }

    // GET api/patient-app/links/lab-report/5 - the bill's approved reports (Lab Report, Microbiology Report, Image report),
    // the whole bill per report and each approved test on its own, each with a download link; otherwise why not yet
    [HttpGet("links/lab-report/{labOrderId:int}")]
    public async Task<IActionResult> LabReportLink(int labOrderId)
    {
        var patientId = PatientId;
        if (!await OwnsLabOrderAsync(labOrderId, patientId)) return NotFound(Fail("NOT_FOUND", "Bill not found."));
        if (await ReportBlockAsync(labOrderId) is { } why) return Ok(new { success = false, message = why, reports = Array.Empty<object>() });

        var tests = await documents.ApprovedTestsAsync(labOrderId);
        var ticket = Ticket(patientId, $"report:{labOrderId}");
        string Url(string type, long? sample) => type == EMR.Api.PatientApp.PatientDocumentService.ImageType
            ? $"{Host}/api/patient-app/files/image-report/{labOrderId}?t={ticket}{(sample is { } s ? $"&sample={s}" : "")}"
            : $"{Host}/api/patient-app/files/lab-report/{labOrderId}?type={Uri.EscapeDataString(type)}&t={ticket}{(sample is { } s2 ? $"&sample={s2}" : "")}";
        var reports = tests.Select(t => t.Type).Distinct()
            .OrderBy(t => t == LabReportTypes.Numeric ? 0 : t == LabReportTypes.Template ? 1 : 2)
            .Select(type => new { type, title = ReportTitle(type), url = Url(type, null) }).ToList();
        var perTest = tests.Select(t => new { sampleCollectionId = t.SampleCollectionId, testName = t.TestName, type = t.Type, title = ReportTitle(t.Type), url = Url(t.Type, t.SampleCollectionId) });
        return Ok(new { success = reports.Count > 0, message = reports.Count > 0 ? null : "The report is not available yet.", reports, tests = perTest });
    }

    // GET api/patient-app/files/lab-report/5?t=&type=&sample= - the LAB / Microbiology report PDF (the link above)
    [HttpGet("files/lab-report/{labOrderId:int}"), AllowAnonymous]
    public async Task<IActionResult> LabReportFile(int labOrderId, string? type, string? t, long? sample)
    {
        var patientId = await TicketPatientAsync(t, $"report:{labOrderId}");
        if (patientId is null) return Content("This link has expired. Open the report again from the app.");
        if (await ReportBlockAsync(labOrderId) is { } why) return Content(why);
        return await PdfFileAsync(() => documents.LabReportAsync(labOrderId, patientId.Value, string.IsNullOrEmpty(type) ? null : type, digitalCopy: true, sampleId: sample),
            "report", $"Report of LAB order {labOrderId}");
    }

    // GET api/patient-app/files/image-report/5?t=&sample= - the approved Image report (X-Ray, USG, ...) PDF
    [HttpGet("files/image-report/{labOrderId:int}"), AllowAnonymous]
    public async Task<IActionResult> ImageReportFile(int labOrderId, string? t, long? sample)
    {
        var patientId = await TicketPatientAsync(t, $"report:{labOrderId}");
        if (patientId is null) return Content("This link has expired. Open the report again from the app.");
        if (await ReportBlockAsync(labOrderId) is { } why) return Content(why);
        return await PdfFileAsync(() => documents.ImageReportAsync(labOrderId, sample), "report", $"Image report of LAB order {labOrderId}");
    }

    // GET api/patient-app/files/lab-bill/5?t= and files/opd-bill/5?t= - the bills as PDFs
    [HttpGet("files/lab-bill/{id:int}"), AllowAnonymous]
    public async Task<IActionResult> LabBillFile(int id, string? t) =>
        await TicketPatientAsync(t, $"lab-bill:{id}") is null
            ? Content("This link has expired. Open the bill again from the app.")
            : await PdfFileAsync(() => documents.LabBillAsync(id), "bill", $"LAB bill {id}");

    [HttpGet("files/opd-bill/{id:int}"), AllowAnonymous]
    public async Task<IActionResult> OpdBillFile(int id, string? t) =>
        await TicketPatientAsync(t, $"opd-bill:{id}") is null
            ? Content("This link has expired. Open the bill again from the app.")
            : await PdfFileAsync(() => documents.OpdBillAsync(id), "bill", $"OPD bill {id}");

    // GET api/patient-app/links/prescription?opdServiceId=5&doctorId=2 - the EMR prescription print of a visit (EMR.Web page)
    [HttpGet("links/prescription")]
    public async Task<IActionResult> PrescriptionLink(int opdServiceId, int doctorId)
    {
        if (!await OwnsVisitAsync(opdServiceId, PatientId)) return NotFound(Fail("NOT_FOUND", "Visit not found."));
        var secret = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes($"prescription-{opdServiceId}-{doctorId}-emr"));
        return Ok(new { success = true, url = $"{WebHost}/OPD/PrintPrescriptionAnonymous?opdServiceId={opdServiceId}&doctorId={doctorId}&secret={Uri.EscapeDataString(secret)}" });
    }

    // GET api/patient-app/links/opd-bill/5 and links/lab-bill/5 - the bill print (EMR.Web page) and its PDF (here)
    [HttpGet("links/opd-bill/{id:int}")]
    public async Task<IActionResult> OpdBillLink(int id)
    {
        var patientId = PatientId;
        if (!await OwnsVisitAsync(id, patientId)) return NotFound(Fail("NOT_FOUND", "Bill not found."));
        return Ok(new { success = true, url = $"{WebHost}/OPD/PrintBillAnonymous?id={id}&secret={Uri.EscapeDataString(BillSecret(id))}",
                        pdfUrl = $"{Host}/api/patient-app/files/opd-bill/{id}?t={Ticket(patientId, $"opd-bill:{id}")}" });
    }

    [HttpGet("links/lab-bill/{id:int}")]
    public async Task<IActionResult> LabBillLink(int id)
    {
        var patientId = PatientId;
        if (!await OwnsLabOrderAsync(id, patientId)) return NotFound(Fail("NOT_FOUND", "Bill not found."));
        return Ok(new { success = true, url = $"{WebHost}/LabOrderBooking/PrintBillAnonymous?labOrderId={id}&secret={Uri.EscapeDataString($"lab_print_{id}")}",
                        pdfUrl = $"{Host}/api/patient-app/files/lab-bill/{id}?t={Ticket(patientId, $"lab-bill:{id}")}" });
    }
}
