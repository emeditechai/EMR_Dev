// A copy of EMR.Web's PatientDocumentService for the patient app (this API): the LAB report, the Image report and the
// LAB / OPD bills as PDFs, from this API's own services (PatientReportData). EMR.Web's copy serves the web portal.
using System.Data.Common;
using System.Security.Claims;
using Dapper;
using EMR.Api.Data;
using EMR.Common;

namespace EMR.Api.PatientApp;

/// <summary>The approved LAB report PDF, or why it cannot be given yet.</summary>
public sealed record PatientReportFile(byte[]? Pdf, string? FileName, string? Message);

/// <summary>One approved test of a bill and the report it prints on: Numeric (Lab Report), Template (Microbiology Report) or Image.</summary>
public sealed record PatientReportTest(long SampleCollectionId, string TestName, string Type);

/// <summary>
/// Whether a LAB bill's report is the patient's to have, by the rules of the patient's WhatsApp copy
/// (LabReportWhatsAppService, usp_LabReportWhatsApp_GetState): every reportable test approved, and for a franchise
/// B2B bill only when the franchise has "Notification Required" on.
/// </summary>
public sealed class PatientReportState
{
    public int TotalTests { get; set; }
    public int ApprovedTests { get; set; }
    public bool IsFinal { get; set; }
    public DateTime? FinalApprovedOn { get; set; }
    public bool IsB2B { get; set; }
    public bool NotificationAllowed { get; set; }
}

/// <summary>
/// What a patient sees of their own LAB bills, shared by the web portal (PatientPortalController) and the patient app
/// (PatientAppController) so both give the same report and the same live stage. Callers check the bill is the patient's.
/// </summary>
public interface IPatientDocumentService
{
    /// <summary>The approved LAB report as e-mailed: paid bills only; the Lab Report, or the Microbiology Report when the bill has only that.
    /// <paramref name="digitalCopy"/>: the patient's own digital copy, which always carries the letterhead (as the WhatsApp copy).</summary>
    Task<PatientReportFile> LabReportAsync(int labOrderId, int patientId, string? type, bool digitalCopy = false, long? sampleId = null);

    /// <summary>The bill's approved tests, each with the report it prints on (the Lab Report Dispatch rule: a Microbiology
    /// test prints on the Microbiology Report whatever its parameters' types; Image tests on the Image report page).</summary>
    Task<List<PatientReportTest>> ApprovedTestsAsync(int labOrderId);

    /// <summary>The approved Image report (one test or every Image test of the bill) as a PDF, drawn with QuestPDF
    /// (PatientPdfDocuments) from what the Image report print page shows - no browser needed on the server.</summary>
    Task<PatientReportFile> ImageReportAsync(int labOrderId, long? sampleId = null);

    /// <summary>The LAB bill as a PDF (the figures of LabOrderBooking/PrintBillAnonymous), drawn with QuestPDF.</summary>
    Task<PatientReportFile> LabBillAsync(int labOrderId);

    /// <summary>The OPD bill as a PDF (the figures of OPD/PrintBillAnonymous), drawn with QuestPDF.</summary>
    Task<PatientReportFile> OpdBillAsync(int opdServiceId);

    /// <summary>The bill's report state for the patient (null when the bill is not found).</summary>
    Task<PatientReportState?> ReportStateAsync(int labOrderId);

    /// <summary>The approved reports the bill has: Numeric (Lab Report) and/or Template (Microbiology Report).</summary>
    Task<List<string>> ReportTypesAsync(int labOrderId);

    /// <summary>The live stage of the patient's LAB bills: the staff Audit History workflow without staff names. Ids not of the patient are skipped.</summary>
    Task<List<object>> LabWorkflowAsync(int patientId, IEnumerable<int> labOrderIds);
}

public sealed class PatientDocumentService(
    IDbConnectionFactory db,
    ILabReportPdfService reportPdfService,
    PatientReportData data) : IPatientDocumentService
{
    private const int StatusApproved = 5;

    public async Task<PatientReportState?> ReportStateAsync(int labOrderId) =>
        await db.CreateConnection().QueryFirstOrDefaultAsync<PatientReportState>(
            "dbo.usp_LabReportWhatsApp_GetState", new { LabOrderId = labOrderId }, commandType: System.Data.CommandType.StoredProcedure);

    public Task<List<string>> ReportTypesAsync(int labOrderId) =>
        reportPdfService.GetPrintableReportTypesAsync(labOrderId, LabReportPrintBuilder.ScopeApproved);

    public async Task<PatientReportFile> LabReportAsync(int labOrderId, int patientId, string? type, bool digitalCopy = false, long? sampleId = null)
    {
        var detail = await data.GetDetailAsync(labOrderId);
        if (detail == null) return new(null, null, "The report is not available yet.");
        if (detail.BalanceDue > 0)
            return new(null, null, $"Your report will be available once the bill is paid (due Rs. {detail.BalanceDue:N2}).");

        var patient = await db.CreateConnection().QueryFirstOrDefaultAsync<(int? CompanyId, int _)?>("SELECT CompanyId, 0 FROM dbo.PatientMaster WHERE PatientId = @Id", new { Id = patientId });
        var user = new ClaimsPrincipal(new ClaimsIdentity(new[]
        {
            new Claim("DisplayName", "Patient Portal"),
            new Claim("CompanyId", (patient?.CompanyId ?? 1).ToString())
        }, "PatientPortal"));

        var types = type is LabReportTypes.Numeric or LabReportTypes.Template
            ? new[] { type } : new[] { LabReportTypes.Numeric, LabReportTypes.Template };
        foreach (var t in types)
        {
            var rvm = await reportPdfService.BuildAsync(labOrderId, user, LabReportPrintBuilder.ScopeApproved, t,
                sampleId is { } one ? new[] { one } : null);
            if (rvm == null || rvm.IncludedTestCount == 0) continue;
            rvm.ShowLetterhead = digitalCopy || (rvm.FranchiseHeaderRequired ?? true);
            rvm.PrintSequence = 1;
            var pdf = LabReportPdfDocument.Generate(rvm, reportPdfService.LoadLogo(rvm.HospitalLogoPath));
            var name = (detail.BillNo ?? $"Report-{labOrderId}").Replace('/', '-');
            var test = sampleId is null ? "" : $"-{Safe(rvm.Sections.SelectMany(x => x.Groups).SelectMany(g => g.Rows).FirstOrDefault()?.TestName ?? sampleId.ToString()!)}";
            return new(pdf, $"{name}{(t == LabReportTypes.Template ? "-Micro" : "")}{test}.pdf", null);
        }
        return new(null, null, sampleId is null ? "No test of this bill has been approved yet. Please check again later." : "This test is not approved yet.");
    }

    public async Task<List<PatientReportTest>> ApprovedTestsAsync(int labOrderId)
    {
        var tests = (await data.GetBillTestsAsync(labOrderId)).Where(t => t.ReportStatusId == StatusApproved).ToList();
        if (tests.Count == 0) return [];
        var template = await data.GetDetailAsync(labOrderId, null, LabReportTypes.Template);
        var templateIds = (template?.Items ?? new()).Select(i => i.SamplecollectionID).ToHashSet();
        var numeric = await data.GetDetailAsync(labOrderId, null, LabReportTypes.Numeric);
        var numericIds = (numeric?.Items ?? new()).Select(i => i.SamplecollectionID).ToHashSet();

        var list = new List<PatientReportTest>();
        foreach (var t in tests)
        {
            var type = templateIds.Contains(t.SamplecollectionID) ? LabReportTypes.Template
                : string.Equals(t.ReportingType?.Trim(), ImageType, StringComparison.OrdinalIgnoreCase) ? ImageType
                : numericIds.Contains(t.SamplecollectionID) ? LabReportTypes.Numeric
                : null;   // a report type with no print format yet (as on Lab Report Dispatch)
            if (type != null) list.Add(new(t.SamplecollectionID, t.TestName, type));
        }
        return list;
    }

    public const string ImageType = "Image";

    public async Task<PatientReportFile> ImageReportAsync(int labOrderId, long? sampleId = null)
    {
        var detail = await data.GetDetailAsync(labOrderId, null, ImageType);
        if (detail == null) return new(null, null, "The report is not available yet.");
        if (detail.BalanceDue > 0)
            return new(null, null, $"Your report will be available once the bill is paid (due Rs. {detail.BalanceDue:N2}).");

        // as LabImageReporting/PatientPrint: the bill's Image tests (or the one asked for), approved only
        var items = (detail.Items ?? new())
            .Where(i => string.Equals(i.ReportingType?.Trim(), ImageType, StringComparison.OrdinalIgnoreCase))
            .Where(i => sampleId is null || i.SamplecollectionID == sampleId)
            .ToList();
        if (items.Count == 0 || items.Any(i => i.ReportStatusId != StatusApproved))
            return new(null, null, sampleId is null ? "The report is not approved yet. Please check again later." : "This test is not approved yet.");

        var signatories = new List<PdfSignatory>();
        try
        {
            foreach (var l in await data.GetSignoffPanelAsync(labOrderId, detail.BranchId, reportingType: ImageType) ?? new())
                if (!string.IsNullOrWhiteSpace(l.FullName))
                    signatories.Add(new(l.FullName!, l.LevelTitle, l.RegistrationNo,
                        string.IsNullOrWhiteSpace(l.SignaturePath) ? null : reportPdfService.LoadSignature(l.SignaturePath)));
        }
        catch { /* the report prints without the sign-off names */ }

        var report = new PdfImageReport
        {
            Patient =
            [
                ("Patient", detail.PatientName), ("Patient ID", detail.PatientCode),
                ("Age / Sex", string.Join(" / ", new[] { detail.Age is { } a ? $"{a} Y" : null, detail.Gender }.Where(x => !string.IsNullOrWhiteSpace(x)))),
                ("Referred by", detail.ReferralDoctorName)
            ],
            Order =
            [
                ("Bill No", detail.BillNo), ("Bill date", detail.OrderDate.ToString("dd/MMM/yyyy HH:mm")),
                ("Approved", detail.ApprovedDate?.ToString("dd/MMM/yyyy HH:mm")), ("Branch", detail.BranchName)
            ],
            Sections = items.Select(i => new PdfReportSection(i.TestName, i.TemplateHtml)).ToList(),
            Signatories = signatories
        };
        var pdf = PatientPdfDocuments.ImageReport(await LetterheadAsync(detail.BranchId), report);
        var test = sampleId is null ? "" : $"-{Safe(items[0].TestName)}";
        return new(pdf, $"{(detail.BillNo ?? $"Report-{labOrderId}").Replace('/', '-')}-Image{test}.pdf", null);
    }

    public async Task<PatientReportFile> LabBillAsync(int labOrderId)
    {
        if (await LabBillPrintBuilder.BuildAnonymousAsync(data.GetOrderDetailAsync, db.CreateConnection(), labOrderId) is not { } built)
            return new(null, null, "The bill was not found.");
        var (vm, branchId) = built;

        var totals = new List<PdfAmount> { new("Gross amount", vm.GrossAmount) };
        if (vm.CancelledAmount != 0) totals.Add(new("Less: cancelled tests", -vm.CancelledAmount));
        if (vm.DiscountAmount != 0) totals.Add(new("Less: discount", -vm.DiscountAmount));
        if (vm.MembershipDiscountAmount != 0) totals.Add(new("Less: membership benefit", -vm.MembershipDiscountAmount));
        if (vm.PointsRedeemedAmount != 0) totals.Add(new($"Less: points redeemed ({vm.PointsRedeemed:0.##})", -vm.PointsRedeemedAmount));
        if (vm.MiscGstAmount != 0) totals.Add(new("GST on charges", vm.MiscGstAmount));
        if (vm.RoundOffAmount != 0) totals.Add(new("Round off", vm.RoundOffAmount));
        totals.Add(new("Net amount", vm.GrandTotal, true));
        totals.Add(new("Received", vm.ReceivedAmount));
        if (vm.RefundedAmount != 0) totals.Add(new("Refunded", vm.RefundedAmount));
        totals.Add(new("Balance", vm.Balance, true));

        var bill = new PdfBill
        {
            Title = "LAB Bill",
            Patient =
            [
                ("Patient", vm.PatientName), ("Patient ID", vm.PatientCode),
                ("Age / Sex", string.Join(" / ", new[] { vm.FormattedAge, vm.Gender }.Where(x => !string.IsNullOrWhiteSpace(x)))),
                ("Mobile", vm.PhoneNumber), ("Referred by", vm.ReferralDoctorName)
            ],
            Bill =
            [
                ("Bill No", vm.BillNo), ("Bill date", vm.CreatedDate.ToString("dd/MMM/yyyy HH:mm")), ("Token", vm.TokenNo),
                ("Collection", vm.CollectionType), ("Branch", vm.BranchName), ("Billed by", vm.CreatedByName ?? vm.CreatedByUsername)
            ],
            ItemHeader = "Investigation",
            Lines = vm.LineItems.Select(l => new PdfBillLine(l.TestName ?? "", string.Join(" · ", new[] { l.TestCode, l.SampleType }.Where(x => !string.IsNullOrWhiteSpace(x))),
                l.MRP, l.DiscountAmount, !l.IsActive)).ToList(),
            Totals = totals,
            Payments = vm.Payments.Select(p => new PdfBillPayment(p.MethodName ?? "Payment",
                string.Join(" · ", new[] { p.ReceiptNo, p.ModeDetails }.Where(x => !string.IsNullOrWhiteSpace(x))), p.PaymentDate, p.PaidAmount)).ToList(),
            AmountInWords = vm.ReceivedAmount > 0 ? vm.AmountInWords : null,
            Status = !vm.IsActive ? "CANCELLED" : vm.PaymentStatus switch { "P" => "PAID", "R" => "PARTLY PAID", _ => "UNPAID" },
            PrintedBy = "Patient app"
        };
        return new(PatientPdfDocuments.Bill(await LetterheadAsync(branchId), bill), $"{(vm.BillNo ?? $"LabBill-{labOrderId}").Replace('/', '-')}.pdf", null);
    }

    public async Task<PatientReportFile> OpdBillAsync(int opdServiceId)
    {
        var d = await data.GetServiceBookingAsync(opdServiceId);
        if (d == null) return new(null, null, "The bill was not found.");
        var branchId = await db.CreateConnection().QueryFirstOrDefaultAsync<int?>("SELECT BranchId FROM dbo.PatientOPDService WHERE OPDServiceId = @Id", new { Id = opdServiceId }) ?? 1;
        var pay = await GetPaymentForBillAsync("OPD", opdServiceId);

        var gross = d.Items.Sum(i => i.ServiceCharges);
        var totals = new List<PdfAmount> { new("Gross amount", pay?.SubTotal is > 0 ? pay.SubTotal : gross) };
        if (pay != null)
        {
            if (pay.DiscountAmount != 0) totals.Add(new("Less: discount", -pay.DiscountAmount));
            var gst = pay.TotalCgstAmount + pay.TotalSgstAmount + pay.TotalIgstAmount;
            if (gst != 0) totals.Add(new("GST", gst));
            if (pay.RoundOffAmount != 0) totals.Add(new("Round off", pay.RoundOffAmount));
            totals.Add(new("Net amount", pay.NetAmount, true));
            totals.Add(new("Received", pay.TotalPaid));
            totals.Add(new("Balance", pay.BalanceDue, true));
        }
        else totals.Add(new("Net amount", d.TotalAmount, true));

        var bill = new PdfBill
        {
            Title = "OPD Bill",
            Patient =
            [
                ("Patient", d.PatientName), ("Patient ID", d.PatientCode),
                ("Age / Sex", string.Join(" / ", new[] { d.FormattedAge, d.Gender }.Where(x => !string.IsNullOrWhiteSpace(x)))),
                ("Mobile", d.PhoneNumber), ("Doctor", d.ConsultingDoctorName)
            ],
            Bill =
            [
                ("Bill No", d.OPDBillNo), ("Bill date", d.CreatedDate.ToString("dd/MMM/yyyy HH:mm")),
                ("Visit", d.VisitDate.ToString("dd/MMM/yyyy") + (d.AppointmentTime is { } t ? $" {DateTime.Today.Add(t):hh:mm tt}" : "")),
                ("Token", d.TokenNo), ("Billed by", d.CreatedByUser)
            ],
            ItemHeader = "Service",
            Lines = d.Items.Select(i => new PdfBillLine(i.ItemName ?? "", string.Join(" · ", new[] { i.ServiceType, i.IsGstRequired && i.GstPercentage > 0 ? $"GST {i.GstPercentage:0.##}%" : null }.Where(x => !string.IsNullOrWhiteSpace(x))),
                i.ServiceCharges, 0, false)).ToList(),
            Totals = totals,
            Payments = (pay?.Rows ?? new()).Select(p => new PdfBillPayment(p.MethodName,
                string.Join(" · ", new[] { p.ReceiptNo, p.TransactionRef, p.UPIRefNo, p.CardLast4 is { Length: > 0 } c ? $"card ••{c}" : null, p.ChequeNo }.Where(x => !string.IsNullOrWhiteSpace(x))), null, p.PaidAmount)).ToList(),
            Status = string.Equals(d.Status, "Cancelled", StringComparison.OrdinalIgnoreCase) ? "CANCELLED"
                : pay?.PaymentStatus switch { "P" => "PAID", "R" => "PARTLY PAID", "U" => "UNPAID", _ => null },
            PrintedBy = "Patient app"
        };
        return new(PatientPdfDocuments.Bill(await LetterheadAsync(branchId), bill), $"{(d.OPDBillNo ?? $"OpdBill-{opdServiceId}").Replace('/', '-')}.pdf", null);
    }

    private async Task<PdfLetterhead> LetterheadAsync(int branchId)
    {
        using var con = db.CreateConnection();
        var s = await ReportSiteRows.SettingsAsync(con, branchId) ?? await ReportSiteRows.SettingsAsync(con, branchId, activeOnly: false);
        var nabh = string.IsNullOrWhiteSpace(s?.NabhStatus) ? null
            : $"{s!.NabhStatus}{(string.IsNullOrWhiteSpace(s.NabhCertificateNo) ? "" : $" · {s.NabhCertificateNo}")}";
        return new(s?.HospitalName ?? "eMeditech Hospital", s?.HospitalType, s?.Address, s?.ContactNumber1, s?.EmailAddress, s?.Website,
            s?.RegistrationNumber, s?.GSTCode, nabh, reportPdfService.LoadLogo(s?.LogoPath));
    }

    private static string Safe(string s) => new string(s.Select(ch => char.IsLetterOrDigit(ch) ? ch : '-').ToArray()).Trim('-');

    public async Task<List<object>> LabWorkflowAsync(int patientId, IEnumerable<int> labOrderIds)
    {
        var wanted = labOrderIds.Where(v => v > 0).Distinct().Take(50).ToList();
        var result = new List<object>();
        if (wanted.Count == 0) return result;

        DbConnection con = (DbConnection)db.CreateConnection();
        var own = (await con.QueryAsync<int>("SELECT LabOrderId FROM LabOrder WHERE PatientId = @P AND LabOrderId IN @Ids",
            new { P = patientId, Ids = wanted })).ToHashSet();

        foreach (var id in wanted.Where(own.Contains))
        {
            var wf = System.Text.Json.JsonSerializer.SerializeToElement(await EMR.Common.LabOrderWorkflow.BuildAsync(con, id));
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
        return result;
    }

    // EMR.Web PaymentService.GetPaymentForBillAsync: the bill's payment header, receipts and lines
    public async Task<BillPaymentSummary?> GetPaymentForBillAsync(string moduleCode, int moduleRefId)
    {
        using var con = db.CreateConnection();

        var header = await con.QuerySingleOrDefaultAsync(@"
            SELECT PaymentHeaderId,
                   SubTotal, 
                   HeaderDiscountType AS DiscountType, 
                   HeaderDiscountValue AS DiscountValue, 
                   HeaderDiscountAmount AS DiscountAmount,
                   RoundOffAmount,
                   TotalCgstAmount, TotalSgstAmount, TotalIgstAmount,
                   NetAmount, TotalPaid, BalanceDue, PaymentStatus, 
                   LastModifiedDate AS PaidOn
            FROM PaymentHeader 
            WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1", 
            new { ModuleCode = moduleCode, ModuleRefId = moduleRefId });

        if (header == null) return null;

        var rows = await con.QueryAsync<BillPaymentRow>(@"
            SELECT
                pm.MethodName,
                pd.PaidAmount,
                pd.TransactionRef,
                pd.ChequeNo,
                pd.BankName,
                pd.UPIRefNo,
                pd.CardLast4,
                pd.ReceiptNo
            FROM PaymentDetail pd
            INNER JOIN PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
            WHERE pd.PaymentHeaderId = @HeaderId AND pd.IsActive = 1
            ORDER BY pd.PaymentDetailId",
            new { HeaderId = (int)header.PaymentHeaderId });

        var lineItems = await con.QueryAsync<BillPaymentLineItem>(@"
            SELECT ModuleLineRefId, CgstAmount, SgstAmount, IgstAmount, NetLineAmount
            FROM PaymentLineItem
            WHERE PaymentHeaderId = @HeaderId AND IsActive = 1",
            new { HeaderId = (int)header.PaymentHeaderId });

        return new BillPaymentSummary
        {
            SubTotal       = (decimal)header.SubTotal,
            DiscountType   = (string?)header.DiscountType,
            DiscountValue  = (decimal)header.DiscountValue,
            DiscountAmount = (decimal)header.DiscountAmount,
            RoundOffAmount = (decimal)header.RoundOffAmount,
            TotalCgstAmount= (decimal)header.TotalCgstAmount,
            TotalSgstAmount= (decimal)header.TotalSgstAmount,
            TotalIgstAmount= (decimal)header.TotalIgstAmount,
            NetAmount      = (decimal)header.NetAmount,
            TotalPaid      = (decimal)header.TotalPaid,
            BalanceDue     = (decimal)header.BalanceDue,
            PaymentStatus  = (string)header.PaymentStatus,
            PaidOn         = (DateTime?)header.PaidOn,
            Rows           = rows.ToList(),
            LineItems      = lineItems.ToList()
        };
    }
}
