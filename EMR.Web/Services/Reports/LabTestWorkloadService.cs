using Dapper;
using EMR.Web.Data;

namespace EMR.Web.Services.Reports;

/// <summary>Filters of LAB > Testwise Workload (bill date range; everything else optional).</summary>
public sealed class TestWorkloadFilter
{
    public DateTime From { get; set; }
    public DateTime To { get; set; }
    /// <summary>null = every branch of the company (Head Office only).</summary>
    public int? BranchId { get; set; }
    public int? DepartmentId { get; set; }
    public int? CategoryId { get; set; }
    public int? SubCategoryId { get; set; }
    public List<int> TestIds { get; set; } = [];
    /// <summary>"B2C", "B2B" or empty for both.</summary>
    public string? BillingType { get; set; }
    public string? Search { get; set; }
}

/// <summary>One test (Investigation Master row) of one bill: a sample collection row, or a whole profile (its own
/// Investigation Master entry) folded from its tests' rows. A package counts as the profiles and tests in it.</summary>
public sealed class TestWorkloadLine
{
    public long SampleCollectionId { get; set; }
    public int LabOrderId { get; set; }
    public string? BillNo { get; set; }
    public string? TokenNo { get; set; }
    public DateTime BillDate { get; set; }
    public DateTime BookedAt { get; set; }
    public bool IsB2B { get; set; }
    public bool IsUrgent { get; set; }
    public string? BranchName { get; set; }
    public int PatientId { get; set; }
    public string? PatientCode { get; set; }
    public string? PatientName { get; set; }
    public string? Gender { get; set; }
    public DateTime? DateOfBirth { get; set; }
    public string? PhoneNumber { get; set; }
    public int TestId { get; set; }
    public string? TestCode { get; set; }
    public string? TestName { get; set; }
    public int TatHours { get; set; }
    public string? DepartmentName { get; set; }
    public string? CategoryName { get; set; }
    public string? SubCategoryName { get; set; }
    public string? ProfileName { get; set; }
    public string? PackageName { get; set; }
    /// <summary>The line stands for a whole profile of the bill (its tests folded into one).</summary>
    public bool IsProfile { get; set; }
    public int? ProfileId { get; set; }
    /// <summary>Tests the profile line was folded from.</summary>
    public int Parts { get; set; } = 1;
    public bool IsOutsourced { get; set; }
    public bool IsCancelled { get; set; }
    public int? CollectionStatusId { get; set; }
    public DateTime? CollectedAt { get; set; }
    public int? ReportStatusId { get; set; }
    public bool HasResult { get; set; }
    public DateTime? ApprovedAt { get; set; }
    public string? AbnormalFlag { get; set; }

    // ── derived, the same wording on screen, Excel and PDF ──
    public int? Age => DateOfBirth is { } dob ? (int)((BillDate.Date - dob.Date).TotalDays / 365.25) : null;
    public string GenderShort => (Gender ?? "").Trim().ToUpperInvariant() switch
    {
        "M" or "MALE" => "Male",
        "F" or "FEMALE" => "Female",
        "" => "",
        _ => "Other"
    };
    public string Source => !string.IsNullOrWhiteSpace(PackageName) ? "Package: " + PackageName : "Direct";
    public bool IsApproved => !IsCancelled && ReportStatusId == 5;
    public bool IsRejected => CollectionStatusId == 4;
    public bool IsAbnormal => AbnormalFlag is "H" or "L" or "Abnormal" or "Critical";
    public double? TatTakenHours => IsApproved && ApprovedAt is { } a ? Math.Max(0, (a - BookedAt).TotalHours) : null;

    public string SampleStatus => IsCancelled ? "Cancelled" : CollectionStatusId switch
    {
        2 => "Collected", 3 => "Re-collect", 4 => "Rejected", _ => "Pending collection"
    };

    public string ReportStatus
    {
        get
        {
            if (IsCancelled) return "Cancelled";
            if (CollectionStatusId is 3 or 4 || ReportStatusId == 4) return "Not reportable";
            return ReportStatusId switch
            {
                5 => "Approved",
                3 => "Validated",
                1 or 2 when HasResult => "Entered",
                _ => CollectionStatusId == 2 ? "Pending entry" : "Awaiting sample"
            };
        }
    }

    /// <summary>Within TAT / Delayed (approved), Overdue / In time (still open), or blank (cancelled, rejected).</summary>
    public string TatStatus(DateTime now)
    {
        if (IsCancelled || IsRejected) return "";
        if (TatTakenHours is { } h) return h <= TatHours ? "Within TAT" : "Delayed";
        return (now - BookedAt).TotalHours > TatHours ? "Overdue" : "In time";
    }
}

/// <summary>All workload figures of one test over the period.</summary>
public sealed class TestWorkloadRow
{
    public int TestId { get; set; }
    public string TestCode { get; set; } = "";
    public string TestName { get; set; } = "";
    public string Department { get; set; } = "";
    public string Category { get; set; } = "";
    public string SubCategory { get; set; } = "";
    public int TatHours { get; set; }

    public int Tests { get; set; }
    public int Patients { get; set; }
    public int Bills { get; set; }
    public int Urgent { get; set; }
    public int B2C { get; set; }
    public int B2B { get; set; }
    public bool IsProfile { get; set; }
    /// <summary>Ordered directly on the bill (not as part of a package).</summary>
    public int SingleTest { get; set; }
    public int InPackage { get; set; }

    public int PendingCollection { get; set; }
    public int Collected { get; set; }
    public int ReCollect { get; set; }
    public int Rejected { get; set; }

    public int PendingEntry { get; set; }
    public int Entered { get; set; }
    public int Validated { get; set; }
    public int Approved { get; set; }

    public int Outsourced { get; set; }
    public int Abnormal { get; set; }
    public int Critical { get; set; }
    public double? AvgTatHours { get; set; }
    public int WithinTat { get; set; }
    public int Delayed { get; set; }
    public int Overdue { get; set; }
    public int Cancelled { get; set; }

    // test-wise patient count
    public int Male { get; set; }
    public int Female { get; set; }
    public int OtherGender { get; set; }
    public int Children { get; set; }
    public int Adults { get; set; }
    public int Seniors { get; set; }
    public int RepeatPatients { get; set; }

    public double? TatCompliance => WithinTat + Delayed == 0 ? null : 100.0 * WithinTat / (WithinTat + Delayed);
    public double? ApprovedPercent => Tests == 0 ? null : 100.0 * Approved / Tests;
}

public sealed class TestWorkloadResult
{
    public List<TestWorkloadRow> Rows { get; set; } = [];
    public List<TestWorkloadLine> Lines { get; set; } = [];
    public TestWorkloadRow Total { get; set; } = new();
    /// <summary>Department subtotals worked out from the lines (patients counted once per department, not once per test).</summary>
    public Dictionary<string, TestWorkloadRow> Departments { get; set; } = [];
    public int DistinctTests => Rows.Count;
    public bool Truncated { get; set; }
}

public interface ILabTestWorkloadService
{
    Task<TestWorkloadResult> GetAsync(int companyId, TestWorkloadFilter f);
}

/// <summary>LAB > Testwise Workload (SQLScripts/2296): per test of the Investigation Master, how many patients, bills and
/// tests, where they stand (sample, report, approval), turnaround against the test's TAT, abnormal results.</summary>
public sealed class LabTestWorkloadService(IDbConnectionFactory db) : ILabTestWorkloadService
{
    /// <summary>Lines read for one request; a longer period should be narrowed with the filters.</summary>
    public const int MaxLines = 100_000;

    public async Task<TestWorkloadResult> GetAsync(int companyId, TestWorkloadFilter f)
    {
        using var con = db.CreateConnection();
        var search = string.IsNullOrWhiteSpace(f.Search) ? null : f.Search.Trim();
        var lines = (await con.QueryAsync<TestWorkloadLine>(@"
            SELECT TOP (@max + 1)
                   sc.samplecollectionID AS SampleCollectionId, lo.LabOrderId, lo.BillNo, lo.TokenNo, lo.OrderDate AS BillDate,
                   COALESCE(lo.BookingDate, lo.OrderDate) AS BookedAt,
                   CAST(ISNULL(lo.IsB2B, 0) AS BIT) AS IsB2B, CAST(ISNULL(lo.IsUrgent, 0) AS BIT) AS IsUrgent,
                   br.BranchName,
                   ISNULL(p.PatientId, lo.PatientId) AS PatientId, p.PatientCode,
                   LTRIM(RTRIM(CONCAT(NULLIF(LTRIM(RTRIM(p.Salutation)), '') + ' ', p.FirstName, ' ' + NULLIF(LTRIM(RTRIM(p.MiddleName)), ''), ' ' + NULLIF(LTRIM(RTRIM(p.LastName)), '')))) AS PatientName,
                   p.Gender, p.DateOfBirth, p.PhoneNumber,
                   -- a test of a profile counts as the profile (its own Investigation Master entry): one test per bill
                   t.Test_ID AS TestId, t.Test_Code AS TestCode, t.Test_Name AS TestName,
                   COALESCE(NULLIF(t.TAT_Hours, 0), CASE WHEN ph.Test_ID IS NOT NULL THEN NULLIF(ph.Profile_TAT_Hours, 0) END, 24) AS TatHours,
                   CAST(CASE WHEN ph.Test_ID IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsProfile, sc.ProfileId,
                   dm.DeptName AS DepartmentName, cat.Category_Name AS CategoryName, sub.SubCategory_Name AS SubCategoryName,
                   sc.ProfileName, sc.PackageName,
                   CAST(ISNULL(sc.IsoutSource, 0) AS BIT) AS IsOutsourced,
                   CAST(CASE WHEN ISNULL(sc.Iscancelled, 0) = 1 OR ISNULL(sc.Is_Active, 1) = 0 OR ISNULL(lo.IsActive, 1) = 0 THEN 1 ELSE 0 END AS BIT) AS IsCancelled,
                   sc.CollectionstatusID AS CollectionStatusId,
                   CASE WHEN sc.Samplecollectiondate IS NOT NULL
                        THEN CAST(CAST(sc.Samplecollectiondate AS DATE) AS DATETIME) + CAST(ISNULL(sc.Samplecollectiontime, '00:00') AS DATETIME) END AS CollectedAt,
                   led.ReportStatusId,
                   CAST(CASE WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR LTRIM(RTRIM(ISNULL(led.Template_Html, ''))) <> '' THEN 1 ELSE 0 END AS BIT) AS HasResult,
                   led.Approved_Date AS ApprovedAt, led.AbnormalFlag
              FROM dbo.samplecollection sc
              JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid
              JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
              LEFT JOIN dbo.LabInvestigationProfileHeader ph ON ph.Profile_ID = sc.ProfileId AND ph.Test_ID IS NOT NULL
              LEFT JOIN dbo.LabInvestigationMaster plim ON plim.Test_ID = ph.Test_ID
             CROSS APPLY (SELECT CASE WHEN plim.Test_ID IS NOT NULL THEN plim.Test_ID ELSE lim.Test_ID END AS Test_ID) tid
              JOIN dbo.LabInvestigationMaster t ON t.Test_ID = tid.Test_ID
              LEFT JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
              LEFT JOIN dbo.Branchmaster br ON br.BranchID = lo.BranchId
              LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = t.Department_ID
              LEFT JOIN dbo.LabTestCategoryMaster cat ON cat.Category_ID = t.Category_ID
              LEFT JOIN dbo.LabTestSubCategoryMaster sub ON sub.SubCategory_ID = t.SubCategory_ID
             OUTER APPLY (SELECT TOP 1 l.ReportStatusId, l.TestValue, l.Template_Html, l.Approved_Date, l.AbnormalFlag
                            FROM dbo.labentrydetails l
                           WHERE l.SamplecollectionID = sc.samplecollectionID AND l.IsActive = 1
                           ORDER BY l.LabEntryDetailId DESC) led
             WHERE lo.OrderDate >= @from AND lo.OrderDate < @toExcl
               AND lim.CompanyId = @companyId
               AND (@branchId IS NULL OR lo.BranchId = @branchId)
               AND (@departmentId IS NULL OR t.Department_ID = @departmentId)
               AND (@categoryId IS NULL OR t.Category_ID = @categoryId)
               AND (@subCategoryId IS NULL OR t.SubCategory_ID = @subCategoryId)
               AND (@testIds IS NULL OR t.Test_ID IN (SELECT TRY_CAST(value AS INT) FROM STRING_SPLIT(@testIds, ',')))
               AND (@billing IS NULL OR (@billing = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@billing = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0))
               AND (@search IS NULL OR lo.BillNo LIKE '%' + @search + '%' OR lo.TokenNo LIKE '%' + @search + '%'
                    OR p.PatientCode LIKE '%' + @search + '%' OR p.PhoneNumber LIKE '%' + @search + '%'
                    OR CONCAT(p.FirstName, ' ', p.LastName) LIKE '%' + @search + '%')
             ORDER BY lo.OrderDate, lo.LabOrderId, sc.samplecollectionID",
            new
            {
                max = MaxLines,
                from = f.From.Date,
                toExcl = f.To.Date.AddDays(1),
                companyId,
                branchId = f.BranchId,
                departmentId = f.DepartmentId,
                categoryId = f.CategoryId,
                subCategoryId = f.SubCategoryId,
                testIds = f.TestIds.Count == 0 ? null : string.Join(",", f.TestIds),
                billing = f.BillingType is "B2B" or "B2C" ? f.BillingType : null,
                search
            }, commandTimeout: 120)).ToList();

        var truncated = lines.Count > MaxLines;
        if (truncated) lines.RemoveAt(lines.Count - 1);
        lines = FoldProfiles(lines);

        var now = DateTime.Now;
        var rows = lines.GroupBy(l => l.TestId)
            .Select(g => Aggregate(g.ToList(), now, g.First()))
            .OrderBy(r => r.Department).ThenByDescending(r => r.Tests).ThenBy(r => r.TestName)
            .ToList();
        var total = Aggregate(lines, now, null);
        total.TestName = "Grand total";
        var departments = lines.GroupBy(l => string.IsNullOrWhiteSpace(l.DepartmentName) ? "No department" : l.DepartmentName!)
            .ToDictionary(g => g.Key, g => { var d = Aggregate(g.ToList(), now, null); d.TestName = g.Key + " - subtotal"; d.Department = g.Key; return d; });
        return new TestWorkloadResult { Rows = rows, Lines = lines, Total = total, Departments = departments, Truncated = truncated };
    }

    /// <summary>A profile on a bill is one test: its tests' lines become one line, at the stage all of them have reached
    /// (approved only when every test is approved; a rejected or pending sample of any test shows on the profile).</summary>
    private static List<TestWorkloadLine> FoldProfiles(List<TestWorkloadLine> lines)
    {
        var result = lines.Where(l => !l.IsProfile).ToList();
        foreach (var g in lines.Where(l => l.IsProfile).GroupBy(l => (l.LabOrderId, l.ProfileId, l.PackageName)))
        {
            var all = g.ToList();
            var live = all.Where(l => !l.IsCancelled).ToList();
            var basis = live.Count > 0 ? live : all;
            var f = all[0];
            var allApproved = basis.All(l => l.ReportStatusId == 5);
            result.Add(new TestWorkloadLine
            {
                SampleCollectionId = all.Min(l => l.SampleCollectionId),
                LabOrderId = f.LabOrderId, BillNo = f.BillNo, TokenNo = f.TokenNo, BillDate = f.BillDate, BookedAt = f.BookedAt,
                IsB2B = f.IsB2B, IsUrgent = f.IsUrgent, BranchName = f.BranchName,
                PatientId = f.PatientId, PatientCode = f.PatientCode, PatientName = f.PatientName, Gender = f.Gender,
                DateOfBirth = f.DateOfBirth, PhoneNumber = f.PhoneNumber,
                TestId = f.TestId, TestCode = f.TestCode, TestName = f.TestName, TatHours = f.TatHours,
                DepartmentName = f.DepartmentName, CategoryName = f.CategoryName, SubCategoryName = f.SubCategoryName,
                ProfileName = f.ProfileName, PackageName = f.PackageName, IsProfile = true, ProfileId = f.ProfileId, Parts = basis.Count,
                IsOutsourced = basis.Any(l => l.IsOutsourced),
                IsCancelled = live.Count == 0,
                CollectionStatusId = basis.Any(l => l.CollectionStatusId == 4) ? 4
                                   : basis.Any(l => l.CollectionStatusId == 3) ? 3
                                   : basis.Any(l => l.CollectionStatusId is null or 1) ? 1 : 2,
                CollectedAt = basis.All(l => l.CollectedAt.HasValue) ? basis.Max(l => l.CollectedAt) : null,
                ReportStatusId = basis.Any(l => l.ReportStatusId == 4) ? 4
                               : allApproved ? 5
                               : basis.All(l => l.ReportStatusId is 3 or 5) ? 3
                               : basis.Any(l => l.HasResult) ? 2 : null,
                HasResult = basis.Any(l => l.HasResult),
                ApprovedAt = allApproved ? basis.Max(l => l.ApprovedAt) : null,
                AbnormalFlag = basis.Any(l => l.AbnormalFlag == "Critical") ? "Critical" : basis.Any(l => l.IsAbnormal) ? "Abnormal" : null
            });
        }
        return result.OrderBy(l => l.BillDate).ThenBy(l => l.LabOrderId).ThenBy(l => l.SampleCollectionId).ToList();
    }

    private static TestWorkloadRow Aggregate(List<TestWorkloadLine> all, DateTime now, TestWorkloadLine? test)
    {
        var live = all.Where(l => !l.IsCancelled).ToList();
        var patients = live.GroupBy(l => l.PatientId).Select(g => g.First()).ToList();
        var tat = live.Where(l => l.TatTakenHours.HasValue).Select(l => l.TatTakenHours!.Value).ToList();

        return new TestWorkloadRow
        {
            TestId = test?.TestId ?? 0,
            TestCode = test?.TestCode ?? "",
            TestName = test?.TestName ?? "Total",
            Department = string.IsNullOrWhiteSpace(test?.DepartmentName) ? (test is null ? "" : "No department") : test.DepartmentName!,
            Category = test?.CategoryName ?? "",
            SubCategory = test?.SubCategoryName ?? "",
            TatHours = test?.TatHours ?? 0,
            IsProfile = test?.IsProfile ?? false,

            Tests = live.Count,
            Patients = patients.Count,
            Bills = live.Select(l => l.LabOrderId).Distinct().Count(),
            Urgent = live.Count(l => l.IsUrgent),
            B2C = live.Count(l => !l.IsB2B),
            B2B = live.Count(l => l.IsB2B),
            SingleTest = live.Count(l => string.IsNullOrWhiteSpace(l.PackageName)),
            InPackage = live.Count(l => !string.IsNullOrWhiteSpace(l.PackageName)),

            PendingCollection = live.Count(l => l.CollectionStatusId is null or 1),
            Collected = live.Count(l => l.CollectionStatusId == 2),
            ReCollect = live.Count(l => l.CollectionStatusId == 3),
            Rejected = live.Count(l => l.CollectionStatusId == 4),

            PendingEntry = live.Count(l => l.ReportStatus == "Pending entry"),
            Entered = live.Count(l => l.ReportStatus == "Entered"),
            Validated = live.Count(l => l.ReportStatus == "Validated"),
            Approved = live.Count(l => l.IsApproved),

            Outsourced = live.Count(l => l.IsOutsourced),
            Abnormal = live.Count(l => l.IsAbnormal),
            Critical = live.Count(l => l.AbnormalFlag == "Critical"),
            AvgTatHours = tat.Count == 0 ? null : tat.Average(),
            WithinTat = live.Count(l => l.TatStatus(now) == "Within TAT"),
            Delayed = live.Count(l => l.TatStatus(now) == "Delayed"),
            Overdue = live.Count(l => l.TatStatus(now) == "Overdue"),
            Cancelled = all.Count(l => l.IsCancelled),

            Male = patients.Count(p => p.GenderShort == "Male"),
            Female = patients.Count(p => p.GenderShort == "Female"),
            OtherGender = patients.Count(p => p.GenderShort is "Other" or ""),
            Children = patients.Count(p => p.Age is < 18),
            Adults = patients.Count(p => p.Age is >= 18 and < 60),
            Seniors = patients.Count(p => p.Age is >= 60),
            // a patient tested more than once for this test in the period (for the total: for any one test)
            RepeatPatients = live.GroupBy(l => (l.PatientId, l.TestId)).Where(g => g.Select(x => x.LabOrderId).Distinct().Count() > 1)
                                 .Select(g => g.Key.PatientId).Distinct().Count()
        };
    }
}
