using EMR.Api.Models;

namespace EMR.Api.Services.BulkUpload;

/// <summary>
/// Investigation Profile (type 1, linked to a profile-test investigation) and Package (type 2) upload.
/// One row per included test; the header columns identify / describe the profile and are repeated on each row.
/// The rows of a profile are its complete test list (tests left out are removed); a profile whose rows all have
/// "Included Test" blank keeps its current tests. A profile is saved only when all of its rows are valid.
/// </summary>
public class InvestigationProfileBulkHandler(ILabInvestigationProfileService service, ILabInvestigationService investigations, LabBulkLookups lookups) : ILabBulkUploadHandler
{
    private const string CCode = "Profile Code";
    private const string CType = "Profile Type";
    private const string CProfileTest = "Profile Test";
    private const string CName = "Profile / Package Name";
    private const string CMrp = "MRP";
    private const string CDisc = "Discount %";
    private const string CStart = "Effective Start Date";
    private const string CEnd = "Effective End Date";
    private const string CAgeOp = "Age Operator";
    private const string CAge = "Applicable Age";
    private const string CGender = "Applicable Gender";
    private const string CTat = "TAT Hours";
    private const string CNabl = "NABL Accredited";
    private const string CPrintSeq = "Report Print Sequence";
    private const string CStatus = "Status";
    private const string CTest = "Included Test";
    private const string CTestSeq = "Test Sequence";

    private const string RefProfileTest = "REF_ProfileTest";
    private const string RefTest = "REF_Test";

    private const string TypeProfile = "Profile";
    private const string TypePackage = "Package";
    private static readonly string[] Types = [TypeProfile, TypePackage];
    private static readonly string[] Genders = ["All", "Male", "Female"];
    private static readonly string[] AgeOperators = ["Exact", "GreaterEqual", "LessEqual"];

    /// <summary>Header columns: repeated on every row of a profile and must agree.</summary>
    private static readonly string[] HeaderColumns = [CType, CProfileTest, CName, CMrp, CDisc, CStart, CEnd, CAgeOp, CAge, CGender, CTat, CNabl, CPrintSeq, CStatus];

    public string Module => "test-profile";
    public string Title => "Investigation Profile / Package";

    private sealed class PRow
    {
        public required RowReader R { get; init; }
        public string? Code, Type, Name, AgeOp, Gender;
        public LabInvestigationListItem? ProfileTest, Test;
        public decimal? Mrp, Disc;
        public DateTime? Start, End;
        public int? Age, Tat, PrintSeq, TestSeq;
        public bool? Nabl, Status;
    }

    private Dictionary<int, (DateTime? Start, DateTime? End)> _dates = [];

    /// <summary>GetById omits the package dates; take them from the table so updates keep them.</summary>
    private async Task<LabInvestigationProfileFullDetail?> GetFullAsync(int id)
    {
        var full = await service.GetByIdAsync(id);
        if (full != null && _dates.TryGetValue(id, out var d))
        {
            full.Header.Effective_Start_Date = d.Start;
            full.Header.Effective_End_Date = d.End;
        }
        return full;
    }

    private static int TypeValue(string type) => type == TypePackage ? 2 : 1;
    private static string TypeName(int type) => type == 2 ? TypePackage : TypeProfile;

    public async Task<BulkTemplate> BuildTemplateAsync(BulkContext ctx, bool withData)
    {
        var allTests = (await investigations.GetListAsync(null, null, null, null, ctx.CompanyId)).ToList();
        var byId = allTests.ToDictionary(x => x.Test_ID);
        var active = allTests.Where(x => x.Status).OrderBy(x => x.Test_Name).ToList();
        var profileTests = active.Where(x => x.Is_Profile_Test).ToList();

        var t = new BulkTemplate
        {
            SheetName = "TestProfile",
            Columns =
            [
                new() { Header = CCode, Note = "Leave blank to create a new profile/package (code generated, e.g. PRF0013). Fill with an existing code to update it. Same code on every row of that profile.", Width = 13 },
                new() { Header = CType, Required = true, Options = Types, Note = "Profile = fixed test group linked to a profile-test investigation. Package = health checkup bundle.", Width = 11 },
                new() { Header = CProfileTest, RefSheet = RefProfileTest, Note = "Required for Profile (an investigation marked 'Is Profile Test'); one profile per test. Must be blank for Package.", Width = 34 },
                new() { Header = CName, Note = "Required for Package; unique. For Profile it defaults to the Profile Test name. Max 200 characters.", Width = 34 },
                new() { Header = CMrp, Required = true, Kind = BulkColumnKind.Decimal, Max = 1000000, Note = "0–10,00,000.", Width = 10 },
                new() { Header = CDisc, Kind = BulkColumnKind.Decimal, Max = 100, Note = "Package only, 0–100. Default 0.", Width = 10 },
                new() { Header = CStart, AllowNone = true, Kind = BulkColumnKind.Date, Note = "Package only.", Width = 13 },
                new() { Header = CEnd, AllowNone = true, Kind = BulkColumnKind.Date, Note = "Package only. On or after the start date.", Width = 13 },
                new() { Header = CAgeOp, AllowNone = true, Options = AgeOperators, Note = "Exact (=), GreaterEqual (>=), LessEqual (<=). Needs Applicable Age. (None) on both removes the age limit.", Width = 14 },
                new() { Header = CAge, AllowNone = true, Kind = BulkColumnKind.Integer, Max = 150, Note = "Age in years, 0–150. Needs Age Operator.", Width = 11 },
                new() { Header = CGender, Options = Genders, Note = "Default All.", Width = 12 },
                new() { Header = CTat, Kind = BulkColumnKind.Integer, Max = 720, Note = "0–720. Default 24.", Width = 9 },
                new() { Header = CNabl, Options = BulkValues.YesNoOptions, Note = "Default No.", Width = 11 },
                new() { Header = CPrintSeq, Kind = BulkColumnKind.Integer, Min = 1, Max = 999, Note = "1–999. Default 1.", Width = 11 },
                new() { Header = CStatus, Options = BulkValues.StatusOptions, Note = "Default Active.", Width = 10 },
                new() { Header = CTest, RefSheet = RefTest, Note = "One test per row. The rows of a profile are its complete test list. Leave blank (on a single row) to update only the header and keep the current tests.", Width = 40 },
                new() { Header = CTestSeq, Kind = BulkColumnKind.Integer, Min = 1, Max = 999, Note = "Order of the test in the profile, 1–999. Default: row order.", Width = 10 }
            ],
            RefSheets =
            [
                new() { Name = RefProfileTest, Headers = ["Select Value", "Test Code", "Test Name", "MRP"],
                        Rows = profileTests.Select(p => new object?[] { BulkValues.Pick(p.Test_Name, p.Test_Code), p.Test_Code, p.Test_Name, p.MRP }).ToList() },
                new() { Name = RefTest, Headers = ["Select Value", "Test Code", "Test Name", "Department", "Test Category", "Profile Test", "MRP"],
                        Rows = active.Select(a => new object?[] { BulkValues.Pick(a.Test_Name, a.Test_Code), a.Test_Code, a.Test_Name, a.Department_Name, a.Category_Name, BulkValues.YesNo(a.Is_Profile_Test), a.MRP }).ToList() }
            ],
            Notes =
            [
                "One row per included test. Repeat the profile columns (Profile Code … Status) on each row; they must be the same on all rows of a profile.",
                "Rows are grouped by Profile Code; new profiles by Profile Test (Profile) or Profile / Package Name (Package).",
                "The rows of a profile replace its test list: tests not in the file are removed from that profile. To change only the profile details, upload one row with 'Included Test' blank.",
                "A profile is saved only if all of its rows are valid; otherwise all its rows are reported as failed."
            ]
        };

        if (withData)
        {
            _dates = await lookups.ProfileDatesAsync(ctx.CompanyId);
            var headers = await service.GetListAsync(null, null, null, ctx.CompanyId);
            foreach (var h in headers.OrderBy(h => h.Profile_Type).ThenBy(h => h.Profile_Name))
            {
                var full = await GetFullAsync(h.Profile_ID);
                if (full == null) continue;
                var head = full.Header;
                var isPackage = head.Profile_Type == 2;
                object?[] HeaderCells() =>
                [
                    head.Profile_Code, TypeName(head.Profile_Type),
                    head.Test_ID.HasValue && byId.TryGetValue(head.Test_ID.Value, out var pt) ? BulkValues.Pick(pt.Test_Name, pt.Test_Code) : null,
                    head.Profile_Name, head.MRP,
                    isPackage ? head.Discount_Pct : null, isPackage ? head.Effective_Start_Date : null, isPackage ? head.Effective_End_Date : null,
                    string.IsNullOrWhiteSpace(head.Age_Operator) ? null : head.Age_Operator, head.Applicable_Age, head.Applicable_Gender,
                    head.Profile_TAT_Hours, BulkValues.YesNo(head.Profile_NABL_Accredited), head.Report_Print_Sequence, BulkValues.Status(head.Status)
                ];
                if (full.Details.Count == 0)
                    t.DataRows.Add([.. HeaderCells(), null, null]);
                foreach (var d in full.Details.OrderBy(d => d.Sequence))
                    t.DataRows.Add([.. HeaderCells(), BulkValues.Pick(d.Test_Name, d.Test_Code), d.Sequence]);
            }
        }
        return t;
    }

    public async Task ImportAsync(IReadOnlyList<BulkRow> rows, BulkContext ctx, LabBulkUploadResult result)
    {
        // All tests (incl. inactive) resolve, so existing profiles re-upload; only active ones can be newly added.
        var allTests = (await investigations.GetListAsync(null, null, null, null, ctx.CompanyId)).ToList();
        var tests = new BulkLookup<LabInvestigationListItem>(allTests, x => x.Test_ID, x => x.Test_Code, x => x.Test_Name);
        var existing = (await service.GetListAsync(null, null, null, ctx.CompanyId)).ToList();
        _dates = await lookups.ProfileDatesAsync(ctx.CompanyId);
        var byCode = existing.GroupBy(h => h.Profile_Code, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);

        // 1. Row parsing
        var parsed = new List<PRow>();
        foreach (var row in rows)
        {
            var r = new RowReader(row);
            var p = new PRow
            {
                R = r,
                Code = r.Text(CCode),
                Type = r.Option(CType, Types),
                ProfileTest = r.Ref(CProfileTest, tests, master: "Profile Test"),
                Name = r.Text(CName, maxLength: 200),
                Mrp = r.Decimal(CMrp, max: 1000000),
                Disc = r.Decimal(CDisc, max: 100),
                Start = r.Date(CStart),
                End = r.Date(CEnd),
                AgeOp = r.Option(CAgeOp, AgeOperators),
                Age = r.Int(CAge, min: 0, max: 150),
                Gender = r.Option(CGender, Genders),
                Tat = r.Int(CTat, min: 0, max: 720),
                Nabl = r.YesNo(CNabl),
                PrintSeq = r.Int(CPrintSeq, min: 1, max: 999),
                Status = r.Status(CStatus),
                Test = r.Ref(CTest, tests, master: "Included Test"),
                TestSeq = r.Int(CTestSeq, min: 1, max: 999)
            };
            if (p.Code != null && !byCode.ContainsKey(p.Code))
                r.Fail(CCode, LabBulkUploadRules.NotFound, $"Profile Code '{p.Code}' does not exist. Leave it blank to create a new profile/package.");
            if (p.ProfileTest != null && !p.ProfileTest.Is_Profile_Test)
                r.Fail(CProfileTest, LabBulkUploadRules.InvalidRef, $"'{p.ProfileTest.Test_Name}' is not marked as a Profile Test in the Investigation master.");
            r.RecordKey = p.Code ?? p.Name ?? p.ProfileTest?.Test_Name ?? string.Empty;
            if (p.Test != null) r.RecordKey += $" / {p.Test.Test_Code}";
            parsed.Add(p);
        }

        // 2. Group rows into profiles
        // Existing: by code. New Package: by name. New Profile: by its Profile Test (or name when the test is missing).
        string? GroupKey(PRow p) =>
            p.Code != null ? $"C|{p.Code.ToUpperInvariant()}"
            : p.Type != TypePackage && p.ProfileTest != null ? $"T|{p.ProfileTest.Test_ID}"
            : p.Name != null ? $"N|{p.Name.Trim().ToUpperInvariant()}"
            : p.ProfileTest != null ? $"T|{p.ProfileTest.Test_ID}"
            : null;

        foreach (var p in parsed.Where(p => GroupKey(p) == null && !p.R.HasErrors))
            p.R.Fail(CCode, LabBulkUploadRules.Required, $"Each row needs a {CCode} (existing profile), a {CProfileTest} (new Profile) or a {CName} (new Package).");

        var seenNames = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var seenTests = new Dictionary<int, int>();
        foreach (var group in parsed.Where(p => GroupKey(p) != null).GroupBy(p => GroupKey(p)!))
            await ImportProfileAsync(group.ToList(), byCode, existing, tests, seenNames, seenTests, ctx, result);

        foreach (var p in parsed.Where(p => GroupKey(p) == null))
            result.AddFailure(p.R);
    }

    private async Task ImportProfileAsync(List<PRow> rows, Dictionary<string, LabInvestigationProfileHeaderListItem> byCode,
        List<LabInvestigationProfileHeaderListItem> existing, BulkLookup<LabInvestigationListItem> tests,
        Dictionary<string, int> seenNames, Dictionary<int, int> seenTests, BulkContext ctx, LabBulkUploadResult result)
    {
        var first = rows[0];

        // Header cells must agree across the profile's rows; the first non-blank value is used.
        string? Signature(PRow p, string col) => p.R.IsNone(col) ? "(none)" : p.R.Text(col)?.Trim().ToUpperInvariant();
        var source = new Dictionary<string, PRow>();
        foreach (var col in HeaderColumns)
        {
            foreach (var p in rows)
            {
                var sig = Signature(p, col);
                if (sig == null) continue;
                if (!source.TryGetValue(col, out var src)) { source[col] = p; continue; }
                if (Signature(src, col) != sig)
                    p.R.Fail(col, LabBulkUploadRules.InvalidValue, $"{col} differs from row {src.R.RowNo} of the same profile. Profile columns must be the same on all its rows.");
            }
        }
        PRow? Src(string col) => source.GetValueOrDefault(col);
        bool IsNone(string col) => Src(col)?.R.IsNone(col) == true;

        var code = first.Code;
        var current = code != null ? byCode.GetValueOrDefault(code) : null;
        var full = current != null ? await GetFullAsync(current.Profile_ID) : null;
        var head = full?.Header;
        var reportOn = first.R;

        // Build the request from the stored profile (update) or defaults (insert), then apply the file.
        var req = head != null ? ToRequest(head, full!.Details) : new LabInvestigationProfileSaveRequest { CompanyId = ctx.CompanyId };
        var before = head != null ? ToRequest(head, full!.Details) : null;

        var type = Src(CType)?.Type;
        if (type == null && head == null) reportOn.Fail(CType, LabBulkUploadRules.Required, $"{CType} is required for a new profile/package.");
        req.Profile_Type = type != null ? TypeValue(type) : req.Profile_Type;
        var isPackage = req.Profile_Type == 2;

        if (IsNone(CProfileTest)) req.Test_ID = null;
        else if (Src(CProfileTest)?.ProfileTest is { } pt) req.Test_ID = pt.Test_ID;
        if (isPackage && req.Test_ID.HasValue)
        {
            if (Src(CProfileTest) != null && !IsNone(CProfileTest))
                reportOn.Fail(CProfileTest, LabBulkUploadRules.InvalidValue, $"{CProfileTest} must be blank for a Package.");
            req.Test_ID = null; // a Package has no profile test (also avoids follow-on uniqueness messages)
        }
        if (!isPackage && !req.Test_ID.HasValue)
            reportOn.Fail(CProfileTest, LabBulkUploadRules.Required, $"{CProfileTest} is required for a Profile.");
        if (req.Test_ID.HasValue && req.Test_ID != before?.Test_ID && tests.ById(req.Test_ID) is { Status: false } inactiveTest)
            reportOn.Fail(CProfileTest, LabBulkUploadRules.InvalidRef, $"'{inactiveTest.Test_Name}' is inactive, so it cannot be linked to a profile.");

        var name = Src(CName)?.Name?.Trim();
        if (name != null) req.Profile_Name = name;
        else if (head == null && !isPackage && req.Test_ID.HasValue) req.Profile_Name = tests.ById(req.Test_ID)?.Test_Name ?? string.Empty;
        if (isPackage && string.IsNullOrWhiteSpace(req.Profile_Name))
            reportOn.Fail(CName, LabBulkUploadRules.Required, "Package Name is required.");

        req.MRP = Src(CMrp)?.Mrp ?? req.MRP;
        if (head == null && Src(CMrp) == null) reportOn.Fail(CMrp, LabBulkUploadRules.Required, $"{CMrp} is required.");

        if (isPackage)
        {
            req.Discount_Pct = Src(CDisc)?.Disc ?? req.Discount_Pct;
            req.Effective_Start_Date = IsNone(CStart) ? null : Src(CStart)?.Start ?? req.Effective_Start_Date;
            req.Effective_End_Date = IsNone(CEnd) ? null : Src(CEnd)?.End ?? req.Effective_End_Date;
            if (req.Effective_Start_Date.HasValue && req.Effective_End_Date.HasValue && req.Effective_End_Date < req.Effective_Start_Date)
                reportOn.Fail(CEnd, LabBulkUploadRules.InvalidValue, $"{CEnd} must be on or after {CStart}.");
        }
        else
        {
            if ((Src(CDisc)?.Disc ?? 0) != 0 || Src(CStart)?.Start != null || Src(CEnd)?.End != null)
                reportOn.Fail(CDisc, LabBulkUploadRules.InvalidValue, $"{CDisc}, {CStart} and {CEnd} apply to Packages only; leave them blank for a Profile.");
            req.Discount_Pct = 0;
            req.Effective_Start_Date = null;
            req.Effective_End_Date = null;
        }

        req.Age_Operator = IsNone(CAgeOp) ? null : Src(CAgeOp)?.AgeOp ?? req.Age_Operator;
        req.Applicable_Age = IsNone(CAge) ? null : Src(CAge)?.Age ?? req.Applicable_Age;
        if (string.IsNullOrEmpty(req.Age_Operator) != !req.Applicable_Age.HasValue)
            reportOn.Fail(CAgeOp, LabBulkUploadRules.InvalidValue, "Age Operator and Applicable Age must be given together (or both left blank).");
        var gender = Src(CGender)?.Gender;
        if (gender != null && !string.Equals(gender, req.Applicable_Gender, StringComparison.OrdinalIgnoreCase)) req.Applicable_Gender = gender;
        req.Profile_TAT_Hours = Src(CTat)?.Tat ?? req.Profile_TAT_Hours;
        req.Profile_NABL_Accredited = Src(CNabl)?.Nabl ?? req.Profile_NABL_Accredited;
        req.Report_Print_Sequence = Src(CPrintSeq)?.PrintSeq ?? req.Report_Print_Sequence;
        req.Status = Src(CStatus)?.Status ?? req.Status;

        // Uniqueness: one profile per profile test, names unique (in the system and in the file).
        var nameKey = req.Profile_Name.Trim();
        var nameClash = existing.FirstOrDefault(h => h.Profile_ID != head?.Profile_ID && string.Equals(h.Profile_Name.Trim(), nameKey, StringComparison.OrdinalIgnoreCase));
        if (nameClash != null && (before == null || !string.Equals(before.Profile_Name.Trim(), nameKey, StringComparison.OrdinalIgnoreCase)))
            reportOn.Fail(CName, LabBulkUploadRules.AlreadyExists, $"'{nameKey}' already exists with code {nameClash.Profile_Code}. Put that code in '{CCode}' to update it.");
        if (seenNames.TryGetValue(nameKey, out var nameRow))
            reportOn.Fail(CName, LabBulkUploadRules.DuplicateInFile, $"'{nameKey}' is already used by the profile starting at row {nameRow}.");
        if (req.Test_ID.HasValue)
        {
            var testClash = existing.FirstOrDefault(h => h.Profile_ID != head?.Profile_ID && h.Test_ID == req.Test_ID);
            if (testClash != null && before?.Test_ID != req.Test_ID)
                reportOn.Fail(CProfileTest, LabBulkUploadRules.AlreadyExists, $"A profile for this test already exists with code {testClash.Profile_Code}. Put that code in '{CCode}' to update it.");
            if (seenTests.TryGetValue(req.Test_ID.Value, out var testRow))
                reportOn.Fail(CProfileTest, LabBulkUploadRules.DuplicateInFile, $"This Profile Test is already used by the profile starting at row {testRow}.");
        }

        // Test list: the rows' tests replace the current list; no test rows keeps it.
        var testRows = rows.Where(p => p.Test != null).ToList();
        if (testRows.Count > 0)
        {
            var currentTestIds = full?.Details.Select(d => d.Test_ID).ToHashSet() ?? [];
            var seenInProfile = new Dictionary<int, int>();
            var details = new List<LabInvestigationProfileDetailInput>();
            var position = 0;
            foreach (var p in testRows)
            {
                position++;
                var test = p.Test!;
                if (!seenInProfile.TryAdd(test.Test_ID, p.R.RowNo))
                    p.R.Fail(CTest, LabBulkUploadRules.DuplicateInFile, $"'{test.Test_Name}' is already in row {seenInProfile[test.Test_ID]} of this profile.");
                else if (!test.Status && !currentTestIds.Contains(test.Test_ID))
                    p.R.Fail(CTest, LabBulkUploadRules.InvalidRef, $"'{test.Test_Name}' is inactive, so it cannot be added to a profile.");
                else
                    details.Add(new LabInvestigationProfileDetailInput
                    {
                        Detail_ID = full?.Details.FirstOrDefault(d => d.Test_ID == test.Test_ID)?.Detail_ID,
                        Test_ID = test.Test_ID,
                        Sequence = p.TestSeq ?? position
                    });
            }
            req.Details = details;
        }
        else if (head == null)
            reportOn.Fail(CTest, LabBulkUploadRules.Required, "At least one Included Test is required for a new profile/package.");

        // All-or-nothing per profile.
        var failedRows = rows.Where(p => p.R.HasErrors).Select(p => p.R.RowNo).ToList();
        if (failedRows.Count > 0)
        {
            foreach (var p in rows)
            {
                if (!p.R.HasErrors)
                    p.R.Fail(string.Empty, LabBulkUploadRules.InvalidValue, $"Profile not saved because row(s) {string.Join(", ", failedRows)} of the same profile have errors.");
                result.AddFailure(p.R);
            }
            return;
        }

        seenNames[nameKey] = first.R.RowNo;
        if (req.Test_ID.HasValue) seenTests[req.Test_ID.Value] = first.R.RowNo;

        if (before != null && BulkValues.SameJson(Normalize(before), Normalize(req)))
        {
            result.Unchanged += rows.Count;
            return;
        }

        if (!ctx.DryRun)
        {
            try
            {
                req.UserId = ctx.UserId;
                await service.SaveAsync(req);
            }
            catch (Exception ex)
            {
                foreach (var p in rows)
                {
                    p.R.Fail(string.Empty, LabBulkUploadRules.SaveFailed, $"Profile could not be saved: {ex.Message}");
                    result.AddFailure(p.R);
                }
                return;
            }
        }
        if (head == null) result.Inserted += rows.Count; else result.Updated += rows.Count;
    }

    private static LabInvestigationProfileSaveRequest ToRequest(LabInvestigationProfileHeaderListItem h, List<LabInvestigationProfileDetailListItem> details) => new()
    {
        Profile_ID = h.Profile_ID, CompanyId = h.CompanyId, Profile_Name = h.Profile_Name, Profile_Type = h.Profile_Type, Test_ID = h.Test_ID,
        MRP = h.MRP, Discount_Pct = h.Discount_Pct, Effective_Start_Date = h.Effective_Start_Date, Effective_End_Date = h.Effective_End_Date,
        Age_Operator = string.IsNullOrWhiteSpace(h.Age_Operator) ? null : h.Age_Operator, Applicable_Age = h.Applicable_Age,
        Applicable_Gender = h.Applicable_Gender, Profile_TAT_Hours = h.Profile_TAT_Hours, Profile_NABL_Accredited = h.Profile_NABL_Accredited,
        Report_Print_Sequence = h.Report_Print_Sequence, Status = h.Status,
        Details = details.Select(d => new LabInvestigationProfileDetailInput { Detail_ID = d.Detail_ID, Test_ID = d.Test_ID, Sequence = d.Sequence }).ToList()
    };

    /// <summary>Comparison form: details in a stable order, without row ids.</summary>
    private static object Normalize(LabInvestigationProfileSaveRequest r) => new
    {
        r.Profile_Name, r.Profile_Type, r.Test_ID, r.MRP, r.Discount_Pct, r.Effective_Start_Date, r.Effective_End_Date, r.Age_Operator,
        r.Applicable_Age, r.Applicable_Gender, r.Profile_TAT_Hours, r.Profile_NABL_Accredited, r.Report_Print_Sequence, r.Status,
        Details = r.Details.OrderBy(d => d.Test_ID).Select(d => new { d.Test_ID, d.Sequence }).ToList()
    };
}
