using System.Data.Common;
using System.Security.Claims;
using Dapper;
using EMR.Web.ApiClients;
using EMR.Web.Controllers;
using EMR.Web.Data;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

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

    /// <summary>The approved Image report (one test or every Image test of the bill) as a PDF; <paramref name="pageUrl"/>
    /// is the ticketed patient print page (LabImageReporting/PatientPrint), printed by headless Chrome.</summary>
    Task<PatientReportFile> ImageReportAsync(int labOrderId, string pageUrl);

    /// <summary>The bill's report state for the patient (null when the bill is not found).</summary>
    Task<PatientReportState?> ReportStateAsync(int labOrderId);

    /// <summary>The approved reports the bill has: Numeric (Lab Report) and/or Template (Microbiology Report).</summary>
    Task<List<string>> ReportTypesAsync(int labOrderId);

    /// <summary>The live stage of the patient's LAB bills: the staff Audit History workflow without staff names. Ids not of the patient are skipped.</summary>
    Task<List<object>> LabWorkflowAsync(int patientId, IEnumerable<int> labOrderIds);
}

public sealed class PatientDocumentService(
    ApplicationDbContext dbContext,
    ILabReportPdfService reportPdfService,
    ILabReportingApiClient labReportingApiClient,
    ILabReportDispatchApiClient dispatchApiClient,
    IHtmlPdfRenderer pdfRenderer) : IPatientDocumentService
{
    private const int StatusApproved = 5;

    public async Task<PatientReportState?> ReportStateAsync(int labOrderId) =>
        await dbContext.Database.GetDbConnection().QueryFirstOrDefaultAsync<PatientReportState>(
            "dbo.usp_LabReportWhatsApp_GetState", new { LabOrderId = labOrderId }, commandType: System.Data.CommandType.StoredProcedure);

    public Task<List<string>> ReportTypesAsync(int labOrderId) =>
        reportPdfService.GetPrintableReportTypesAsync(labOrderId, LabReportPrintBuilder.ScopeApproved);

    public async Task<PatientReportFile> LabReportAsync(int labOrderId, int patientId, string? type, bool digitalCopy = false, long? sampleId = null)
    {
        var detail = await labReportingApiClient.GetDetailAsync(labOrderId);
        if (detail == null) return new(null, null, "The report is not available yet.");
        if (detail.BalanceDue > 0)
            return new(null, null, $"Your report will be available once the bill is paid (due Rs. {detail.BalanceDue:N2}).");

        var patient = await dbContext.PatientMasters.Where(p => p.PatientId == patientId).Select(p => new { p.CompanyId }).FirstOrDefaultAsync();
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
        var tests = (await dispatchApiClient.GetBillTestsAsync(labOrderId)).Where(t => t.ReportStatusId == StatusApproved).ToList();
        if (tests.Count == 0) return [];
        var template = await labReportingApiClient.GetDetailAsync(labOrderId, null, LabReportTypes.Template);
        var templateIds = (template?.Items ?? new()).Select(i => i.SamplecollectionID).ToHashSet();
        var numeric = await labReportingApiClient.GetDetailAsync(labOrderId, null, LabReportTypes.Numeric);
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

    public async Task<PatientReportFile> ImageReportAsync(int labOrderId, string pageUrl)
    {
        var detail = await labReportingApiClient.GetDetailAsync(labOrderId);
        if (detail == null) return new(null, null, "The report is not available yet.");
        if (detail.BalanceDue > 0)
            return new(null, null, $"Your report will be available once the bill is paid (due Rs. {detail.BalanceDue:N2}).");
        var pdf = await pdfRenderer.RenderAsync(pageUrl);
        if (pdf is null) return new(null, null, "The report could not be prepared right now. Please try again.");
        return new(pdf, $"{(detail.BillNo ?? $"Report-{labOrderId}").Replace('/', '-')}-Image.pdf", null);
    }

    private static string Safe(string s) => new string(s.Select(ch => char.IsLetterOrDigit(ch) ? ch : '-').ToArray()).Trim('-');

    public async Task<List<object>> LabWorkflowAsync(int patientId, IEnumerable<int> labOrderIds)
    {
        var wanted = labOrderIds.Where(v => v > 0).Distinct().Take(50).ToList();
        var result = new List<object>();
        if (wanted.Count == 0) return result;

        DbConnection con = dbContext.Database.GetDbConnection();
        var own = (await con.QueryAsync<int>("SELECT LabOrderId FROM LabOrder WHERE PatientId = @P AND LabOrderId IN @Ids",
            new { P = patientId, Ids = wanted })).ToHashSet();

        foreach (var id in wanted.Where(own.Contains))
        {
            var wf = System.Text.Json.JsonSerializer.SerializeToElement(await LabReportingController.BuildOrderWorkflowAsync(con, id));
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
}
