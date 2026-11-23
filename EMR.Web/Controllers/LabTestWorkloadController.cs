using Dapper;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Services.Reports;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Reports > LAB > Testwise Workload (SQLScripts/2296): per test of the Investigation Master over a bill date range - patients,
/// bills and tests, sample and report status, turnaround against the test's TAT, abnormal results - with the test-wise
/// patient count and the patient-wise details; Excel and PDF built on the server.
/// </summary>
[Authorize]
public class LabTestWorkloadController(IDbConnectionFactory db, ILabTestWorkloadService workload) : Controller
{
    /// <summary>Patient-wise lines sent to the screen; the exports always carry all of them.</summary>
    private const int ScreenLines = 3000;

    private bool IsHo => string.Equals(User.FindFirst("IsHOBranch")?.Value, "true", StringComparison.OrdinalIgnoreCase);

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        using var con = db.CreateConnection();
        var companyId = User.GetCompanyId();
        ViewBag.Departments = (await con.QueryAsync<(int Id, string Name)>(@"
            SELECT DISTINCT dm.DeptId, dm.DeptName FROM dbo.DepartmentMaster dm
              JOIN dbo.LabInvestigationMaster lim ON lim.Department_ID = dm.DeptId
             WHERE lim.CompanyId = @companyId AND ISNULL(lim.IsDeleted, 0) = 0
             ORDER BY dm.DeptName", new { companyId })).ToList();
        ViewBag.Branches = IsHo
            ? (await con.QueryAsync<(int Id, string Name)>(
                "SELECT BranchID, BranchName FROM dbo.Branchmaster WHERE CompanyId = @companyId AND IsActive = 1 ORDER BY IsHOBranch DESC, BranchName",
                new { companyId })).ToList()
            : new List<(int, string)>();
        ViewBag.CurrentBranchId = User.GetCurrentBranchId() ?? 0;
        return View();
    }

    [HttpGet]
    public async Task<IActionResult> Categories(int? departmentId)
    {
        using var con = db.CreateConnection();
        var rows = await con.QueryAsync<(int Id, string Name)>(@"
            SELECT Category_ID, Category_Name FROM dbo.LabTestCategoryMaster
             WHERE CompanyId = @companyId AND ISNULL(IsDeleted, 0) = 0 AND (@departmentId IS NULL OR Department_ID = @departmentId)
             ORDER BY Category_Name", new { companyId = User.GetCompanyId(), departmentId });
        return Json(rows.Select(r => new { value = r.Id, text = r.Name }));
    }

    [HttpGet]
    public async Task<IActionResult> SubCategories(int? categoryId)
    {
        if (categoryId is null) return Json(Array.Empty<object>());
        using var con = db.CreateConnection();
        var rows = await con.QueryAsync<(int Id, string Name)>(@"
            SELECT SubCategory_ID, SubCategory_Name FROM dbo.LabTestSubCategoryMaster
             WHERE CompanyId = @companyId AND ISNULL(IsDeleted, 0) = 0 AND Category_ID = @categoryId
             ORDER BY SubCategory_Name", new { companyId = User.GetCompanyId(), categoryId });
        return Json(rows.Select(r => new { value = r.Id, text = r.Name }));
    }

    /// <summary>Tests of the Investigation Master for the Tests filter (Select2 search), within the chosen department /
    /// category / sub category. A profile is listed too and is reported as one test.</summary>
    [HttpGet]
    public async Task<IActionResult> Tests(string? term, int? departmentId, int? categoryId, int? subCategoryId)
    {
        using var con = db.CreateConnection();
        var rows = await con.QueryAsync<(int Id, string Code, string Name, bool IsProfile, int Parts)>(@"
            SELECT TOP 50 lim.Test_ID, lim.Test_Code, lim.Test_Name, CAST(ISNULL(lim.Is_Profile_Test, 0) AS BIT),
                   (SELECT COUNT(*) FROM dbo.LabInvestigationProfileHeader h
                      JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = h.Profile_ID AND ISNULL(d.IsDeleted, 0) = 0
                     WHERE h.Test_ID = lim.Test_ID AND ISNULL(h.IsDeleted, 0) = 0)
              FROM dbo.LabInvestigationMaster lim
             WHERE lim.CompanyId = @companyId AND ISNULL(lim.IsDeleted, 0) = 0
               AND (@departmentId IS NULL OR lim.Department_ID = @departmentId)
               AND (@categoryId IS NULL OR lim.Category_ID = @categoryId)
               AND (@subCategoryId IS NULL OR lim.SubCategory_ID = @subCategoryId)
               AND (@term IS NULL OR lim.Test_Name LIKE '%' + @term + '%' OR lim.Test_Code LIKE @term + '%')
             ORDER BY lim.Test_Name",
            new { companyId = User.GetCompanyId(), departmentId, categoryId, subCategoryId, term = string.IsNullOrWhiteSpace(term) ? null : term.Trim() });
        return Json(new
        {
            results = rows.Select(r => new
            {
                id = r.Id,
                text = r.IsProfile ? $"{r.Name} ({r.Code}) - Profile, {r.Parts} test(s)" : $"{r.Name} ({r.Code})"
            })
        });
    }

    [HttpGet]
    public async Task<IActionResult> Data(string fromDate, string toDate, int? branchId, int? departmentId, int? categoryId, int? subCategoryId,
                                          string? testIds, string? billingType, string? search)
    {
        if (!TryFilter(fromDate, toDate, branchId, departmentId, categoryId, subCategoryId, testIds, billingType, search, out var f, out var error))
            return Json(new { success = false, message = error });
        try
        {
            var r = await workload.GetAsync(User.GetCompanyId(), f);
            var now = DateTime.Now;
            var lines = LabTestWorkloadExport.OrderedLines(r).Take(ScreenLines).Select(l => new
            {
                billDate = l.BillDate.ToString("dd MMM yyyy, hh:mm tt"), billNo = l.BillNo, token = l.TokenNo, billing = l.IsB2B ? "B2B" : "B2C", urgent = l.IsUrgent,
                patientCode = l.PatientCode, patientName = l.PatientName, age = l.Age, gender = l.GenderShort, phone = l.PhoneNumber,
                testId = l.TestId, testCode = l.TestCode, testName = l.TestName, isProfile = l.IsProfile, parts = l.Parts, department = l.DepartmentName, source = l.Source,
                sample = l.SampleStatus, collectedAt = l.CollectedAt?.ToString("dd MMM, hh:mm tt"), report = l.ReportStatus,
                approvedAt = l.IsApproved ? l.ApprovedAt?.ToString("dd MMM, hh:mm tt") : null, tatHours = l.TatHours,
                taken = l.TatTakenHours is null ? null : LabTestWorkloadExport.Hours(l.TatTakenHours), tat = l.TatStatus(now),
                flag = l.IsAbnormal ? l.AbnormalFlag : null, outsourced = l.IsOutsourced, cancelled = l.IsCancelled
            });
            return Json(new
            {
                success = true,
                truncated = r.Truncated,
                maxLines = LabTestWorkloadService.MaxLines,
                totalLines = r.Lines.Count,
                screenLines = Math.Min(ScreenLines, r.Lines.Count),
                distinctTests = r.DistinctTests,
                total = Shape(r.Total),
                departments = r.Departments.ToDictionary(d => d.Key, d => Shape(d.Value)),
                rows = r.Rows.Select(Shape),
                lines
            });
        }
        catch (Exception)
        {
            return Json(new { success = false, message = "The report could not be loaded. Try a shorter period or narrow the filters." });
        }
    }

    [HttpGet]
    public async Task<IActionResult> Export(string format, string? view, string fromDate, string toDate, int? branchId, int? departmentId, int? categoryId,
                                            int? subCategoryId, string? testIds, string? billingType, string? search)
    {
        if (!TryFilter(fromDate, toDate, branchId, departmentId, categoryId, subCategoryId, testIds, billingType, search, out var f, out var error))
            return BadRequest(error);
        var r = await workload.GetAsync(User.GetCompanyId(), f);
        var info = new TestWorkloadExportInfo(await BranchLabelAsync(f.BranchId), f.From, f.To, await FilterLabelsAsync(f),
            User.FindFirst("DisplayName")?.Value ?? User.Identity?.Name ?? "", DateTime.Now);
        var name = $"Testwise_Workload_{f.From:yyyyMMdd}_{f.To:yyyyMMdd}";
        if (string.Equals(format, "pdf", StringComparison.OrdinalIgnoreCase))
        {
            var v = view is LabTestWorkloadExport.ViewPatients or LabTestWorkloadExport.ViewDetails ? view : LabTestWorkloadExport.ViewSummary;
            return File(LabTestWorkloadExport.BuildPdf(r, info, v), "application/pdf", $"{name}_{v}.pdf");
        }
        return File(LabTestWorkloadExport.BuildExcel(r, info), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", name + ".xlsx");
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────────────────────────

    private static object Shape(TestWorkloadRow x) => new
    {
        x.TestId, x.TestCode, x.TestName, x.Department, x.Category, x.SubCategory, x.TatHours,
        x.IsProfile, x.Tests, x.Patients, x.Bills, x.Urgent, x.B2C, x.B2B, x.SingleTest, x.InPackage,
        x.PendingCollection, x.Collected, x.ReCollect, x.Rejected, x.PendingEntry, x.Entered, x.Validated, x.Approved,
        x.Outsourced, x.Abnormal, x.Critical, AvgTat = LabTestWorkloadExport.Hours(x.AvgTatHours), x.AvgTatHours,
        x.WithinTat, x.Delayed, x.Overdue, x.Cancelled, TatCompliance = x.TatCompliance, ApprovedPercent = x.ApprovedPercent,
        x.Male, x.Female, x.OtherGender, x.Children, x.Adults, x.Seniors, x.RepeatPatients
    };

    private bool TryFilter(string fromDate, string toDate, int? branchId, int? departmentId, int? categoryId, int? subCategoryId,
                           string? testIds, string? billingType, string? search, out TestWorkloadFilter f, out string? error)
    {
        f = new TestWorkloadFilter();
        error = null;
        if (!DateTime.TryParse(fromDate, out var from) || !DateTime.TryParse(toDate, out var to))
        { error = "Choose the bill date range."; return false; }
        if (to < from) { error = "The 'To' date is before the 'From' date."; return false; }
        if ((to - from).TotalDays > 366) { error = "Choose a period of one year or less."; return false; }

        f.From = from.Date;
        f.To = to.Date;
        // a Head Office user may pick any branch or all (0); everyone else sees the branch they are signed in to
        f.BranchId = IsHo ? (branchId is > 0 ? branchId : null) : (User.GetCurrentBranchId() ?? -1);
        f.DepartmentId = departmentId is > 0 ? departmentId : null;
        f.CategoryId = categoryId is > 0 ? categoryId : null;
        f.SubCategoryId = subCategoryId is > 0 ? subCategoryId : null;
        f.TestIds = (testIds ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                                   .Select(s => int.TryParse(s, out var i) ? i : 0).Where(i => i > 0).Distinct().Take(200).ToList();
        f.BillingType = billingType is "B2B" or "B2C" ? billingType : null;
        f.Search = string.IsNullOrWhiteSpace(search) ? null : search.Trim()[..Math.Min(100, search.Trim().Length)];
        return true;
    }

    private async Task<string> BranchLabelAsync(int? branchId)
    {
        if (branchId is null) return "All branches";
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<string?>("SELECT BranchName FROM dbo.Branchmaster WHERE BranchID = @branchId", new { branchId }) ?? "";
    }

    private async Task<List<string>> FilterLabelsAsync(TestWorkloadFilter f)
    {
        var list = new List<string>();
        using var con = db.CreateConnection();
        if (f.DepartmentId is { } d) list.Add("Department: " + await con.ExecuteScalarAsync<string?>("SELECT DeptName FROM dbo.DepartmentMaster WHERE DeptId = @d", new { d }));
        if (f.CategoryId is { } c) list.Add("Category: " + await con.ExecuteScalarAsync<string?>("SELECT Category_Name FROM dbo.LabTestCategoryMaster WHERE Category_ID = @c", new { c }));
        if (f.SubCategoryId is { } s) list.Add("Sub category: " + await con.ExecuteScalarAsync<string?>("SELECT SubCategory_Name FROM dbo.LabTestSubCategoryMaster WHERE SubCategory_ID = @s", new { s }));
        if (f.TestIds.Count > 0)
        {
            var names = (await con.QueryAsync<string>(@"SELECT Test_Name + CASE WHEN ISNULL(Is_Profile_Test, 0) = 1 THEN ' (profile)' ELSE '' END
                                                         FROM dbo.LabInvestigationMaster WHERE Test_ID IN @ids ORDER BY Test_Name", new { ids = f.TestIds })).ToList();
            list.Add("Tests: " + (names.Count <= 5 ? string.Join(", ", names) : string.Join(", ", names.Take(5)) + $" +{names.Count - 5} more"));
        }
        if (f.BillingType is not null) list.Add("Billing: " + f.BillingType);
        if (f.Search is not null) list.Add("Search: " + f.Search);
        return list;
    }
}
