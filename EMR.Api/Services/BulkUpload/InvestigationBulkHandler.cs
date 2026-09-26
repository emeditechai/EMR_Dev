using EMR.Api.Models;

namespace EMR.Api.Services.BulkUpload;

public class InvestigationBulkHandler(ILabInvestigationService service, LabBulkLookups lookups) : ILabBulkUploadHandler
{
    private const string CCode = "Test Code";
    private const string CName = "Test Name";
    private const string CDept = "Department";
    private const string CCat = "Test Category";
    private const string CSub = "Sub Category";
    private const string CSample = "Sample Type";
    private const string CMethod = "Method";
    private const string CUnit = "Result Unit";
    private const string CReporting = "Reporting Type";
    private const string CTat = "TAT Hours";
    private const string CNabl = "NABL Accredited";
    private const string CNablScope = "NABL Scope No";
    private const string COutsourced = "Is Outsourced";
    private const string CProfile = "Is Profile Test";
    private const string CGender = "Applicable Gender";
    private const string CAgeOp = "Age Operator";
    private const string CAge = "Applicable Age";
    private const string CBillable = "Is Billable";
    private const string CFasting = "Fasting Required";
    private const string CQty = "Sample Quantity";
    private const string CQtyUnit = "Sample Quantity Unit";
    private const string CDurValue = "Reported Duration";
    private const string CDurUnit = "Reported Duration Unit";
    private const string CConsent = "Consent Required";
    private const string COvd = "OVD Document";
    private const string CPrescription = "Prescription Required";
    private const string CMrp = "MRP";
    private const string CStatus = "Status";

    private const string RefDept = "REF_Department";
    private const string RefCat = "REF_Category";
    private const string RefSub = "REF_SubCategory";
    private const string RefSample = "REF_SampleType";
    private const string RefMethod = "REF_Method";
    private const string RefUnit = "REF_Unit";

    private static readonly string[] ReportingTypes = ["Numeric", "Text", "Descriptive", "Image", "Template"];
    private static readonly string[] Genders = ["All", "Male", "Female", "Transgender"];
    private static readonly string[] AgeOperators = ["Exact", "GreaterEqual", "LessEqual"];
    private static readonly string[] DurationUnits = ["Days", "Hours", "Months"];

    public string Module => "investigation";
    public string Title => "Investigation";

    public async Task<BulkTemplate> BuildTemplateAsync(BulkContext ctx, bool withData)
    {
        var depts = await lookups.DepartmentsAsync(ctx.CompanyId);
        var cats = await lookups.CategoriesAsync(ctx.CompanyId);
        var subs = await lookups.SubCategoriesAsync(ctx.CompanyId);
        var samples = await lookups.SampleTypesAsync(ctx.CompanyId);
        var methods = await lookups.MethodsAsync(ctx.CompanyId);
        var units = await lookups.UnitsAsync(ctx.CompanyId);

        var t = new BulkTemplate
        {
            SheetName = "Investigation",
            Columns =
            [
                new() { Header = CCode, Note = "Leave blank to create a new investigation (code is generated, e.g. LAB-00012). Fill with an existing code to update it.", Width = 14 },
                new() { Header = CName, Required = true, Note = "Unique within the department. Max 200 characters.", Width = 36 },
                new() { Header = CDept, RefSheet = RefDept, Note = "Optional: taken from the Test Category when blank. If given, it must match the category's department.", Width = 26 },
                new() { Header = CCat, Required = true, RefSheet = RefCat, Note = "Must belong to the department.", Width = 30 },
                new() { Header = CSub, AllowNone = true, RefSheet = RefSub, Note = "Must belong to the Test Category (see REF_SubCategory).", Width = 30 },
                new() { Header = CSample, AllowNone = true, RefSheet = RefSample, Width = 24 },
                new() { Header = CMethod, AllowNone = true, RefSheet = RefMethod, Note = "Must belong to the same department (see REF_Method).", Width = 26 },
                new() { Header = CUnit, AllowNone = true, RefSheet = RefUnit, Note = "Result unit.", Width = 20 },
                new() { Header = CReporting, Options = ReportingTypes, Note = "Default Numeric.", Width = 14 },
                new() { Header = CTat, Kind = BulkColumnKind.Integer, Max = 720, Note = "Turnaround time in hours, 0–720. Default 24.", Width = 11 },
                new() { Header = CNabl, Options = BulkValues.YesNoOptions, Note = "Default No.", Width = 12 },
                new() { Header = CNablScope, AllowNone = true, Note = "Max 100 characters.", Width = 16 },
                new() { Header = COutsourced, Options = BulkValues.YesNoOptions, Note = "Default No.", Width = 12 },
                new() { Header = CProfile, Options = BulkValues.YesNoOptions, Note = "Default No.", Width = 12 },
                new() { Header = CGender, Options = Genders, Note = "Default All.", Width = 14 },
                new() { Header = CAgeOp, AllowNone = true, Options = AgeOperators, Note = "Exact (=), GreaterEqual (>=), LessEqual (<=). Needs Applicable Age. (None) on both removes the age limit.", Width = 14 },
                new() { Header = CAge, AllowNone = true, Kind = BulkColumnKind.Integer, Max = 150, Note = "Age in years. Needs Age Operator. 0–150.", Width = 12 },
                new() { Header = CBillable, Options = BulkValues.YesNoOptions, Note = "Default Yes. Only billable tests can be added to rate lists.", Width = 11 },
                new() { Header = CFasting, Options = BulkValues.YesNoOptions, Note = "Default No.", Width = 12 },
                new() { Header = CQty, AllowNone = true, Kind = BulkColumnKind.Decimal, Max = 10000, Note = "0–10000.", Width = 12 },
                new() { Header = CQtyUnit, AllowNone = true, RefSheet = RefUnit, Note = "Unit of the sample quantity.", Width = 18 },
                new() { Header = CDurValue, AllowNone = true, Kind = BulkColumnKind.Integer, Min = 1, Max = 365, Note = "Report delivery time value, 1–365.", Width = 12 },
                new() { Header = CDurUnit, Options = DurationUnits, Note = "Default Days.", Width = 12 },
                new() { Header = CConsent, Options = BulkValues.YesNoOptions, Note = "Default No.", Width = 12 },
                new() { Header = COvd, Options = BulkValues.YesNoOptions, Note = "Default No.", Width = 12 },
                new() { Header = CPrescription, Options = BulkValues.YesNoOptions, Note = "Default No.", Width = 13 },
                new() { Header = CMrp, Required = true, Kind = BulkColumnKind.Decimal, Max = 1000000, Note = "Maximum retail price, 0–10,00,000.", Width = 11 },
                new() { Header = CStatus, Options = BulkValues.StatusOptions, Note = "Default Active.", Width = 11 }
            ],
            RefSheets =
            [
                new() { Name = RefDept, Headers = ["Select Value", "Department Code", "Department Name"],
                        Rows = depts.Items.Select(d => new object?[] { depts.Pick(d), d.Code, d.Name }).ToList() },
                new() { Name = RefCat, Headers = ["Select Value", "Category Code", "Category Name", "Department"],
                        Rows = cats.Items.Select(c => new object?[] { cats.Pick(c), c.Code, c.Name, c.DepartmentName }).ToList() },
                new() { Name = RefSub, Headers = ["Select Value", "Sub Category Code", "Sub Category Name", "Test Category", "Department"],
                        Rows = subs.Items.Select(s => new object?[] { subs.Pick(s), s.Code, s.Name, s.CategoryName, s.DepartmentName }).ToList() },
                new() { Name = RefSample, Headers = ["Select Value", "Sample Code", "Sample Name", "Container"],
                        Rows = samples.Items.Select(s => new object?[] { samples.Pick(s), s.Code, s.Name, s.Container }).ToList() },
                new() { Name = RefMethod, Headers = ["Select Value", "Method Code", "Method Name", "Department"],
                        Rows = methods.Items.Select(m => new object?[] { methods.Pick(m), m.Code, m.Name, m.DepartmentName }).ToList() },
                new() { Name = RefUnit, Headers = ["Select Value", "Unit Code", "Unit Name", "Symbol"],
                        Rows = units.Items.Select(u => new object?[] { units.Pick(u), u.Code, u.Name, u.Symbol }).ToList() }
            ]
        };

        if (withData)
        {
            string? Pick<T>(BulkLookup<T> l, int? id, string? fallbackName) where T : class =>
                l.ById(id) is { } item ? l.Pick(item) : fallbackName;

            var existing = await service.GetListAsync(null, null, null, null, ctx.CompanyId);
            t.DataRows.AddRange(existing.OrderBy(i => i.Department_Name).ThenBy(i => i.Category_Name).ThenBy(i => i.Test_Name).Select(i => new object?[]
            {
                i.Test_Code, i.Test_Name,
                BulkValues.Pick(i.Department_Name, i.Department_Code),
                BulkValues.Pick(i.Category_Name, i.Category_Code),
                i.SubCategory_ID.HasValue ? BulkValues.Pick(i.SubCategory_Name ?? "", i.SubCategory_Code) : null,
                Pick(samples, i.Sample_Type_ID, i.Sample_Type_Name),
                Pick(methods, i.Method_ID, i.Method_Name),
                Pick(units, i.Unit_ID, i.Unit_Name),
                i.Reporting_Type, i.TAT_Hours,
                BulkValues.YesNo(i.NABL_Accredited), i.NABL_Scope_No,
                BulkValues.YesNo(i.Is_Outsourced), BulkValues.YesNo(i.Is_Profile_Test),
                i.Applicable_Gender, i.Age_Operator, i.Applicable_Age,
                BulkValues.YesNo(i.Is_Billable), BulkValues.YesNo(i.Is_Fasting_Required),
                i.Sample_Quantity, Pick(units, i.Sample_Quantity_Unit_ID, i.Sample_Quantity_Unit_Name),
                i.Reported_Duration_Value, i.Reported_Duration_Unit,
                BulkValues.YesNo(i.Is_Consent_Required), BulkValues.YesNo(i.OVD_Document), BulkValues.YesNo(i.Prescription_Required),
                i.MRP, BulkValues.Status(i.Status)
            }));
        }
        return t;
    }

    public async Task ImportAsync(IReadOnlyList<BulkRow> rows, BulkContext ctx, LabBulkUploadResult result)
    {
        var depts = await lookups.DepartmentsAsync(ctx.CompanyId);
        var cats = await lookups.CategoriesAsync(ctx.CompanyId);
        var subs = await lookups.SubCategoriesAsync(ctx.CompanyId);
        var samples = await lookups.SampleTypesAsync(ctx.CompanyId);
        var methods = await lookups.MethodsAsync(ctx.CompanyId);
        var units = await lookups.UnitsAsync(ctx.CompanyId);

        var existing = (await service.GetListAsync(null, null, null, null, ctx.CompanyId)).ToList();
        var byCode = existing.GroupBy(i => i.Test_Code, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);
        var seenCodes = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var seenNames = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);

        foreach (var row in rows)
        {
            var r = new RowReader(row);
            var code = r.Text(CCode);
            LabInvestigationListItem? current = null;
            if (code != null)
            {
                if (!byCode.TryGetValue(code, out current))
                    r.Fail(CCode, LabBulkUploadRules.NotFound, $"Test Code '{code}' does not exist. Leave it blank to create a new investigation.");
                else if (!seenCodes.TryAdd(code, r.RowNo))
                    r.Fail(CCode, LabBulkUploadRules.DuplicateInFile, $"Test Code '{code}' is already used in row {seenCodes[code]}.");
            }
            var isInsert = code == null;

            var name = r.Text(CName, required: isInsert, maxLength: 200);
            var dept = r.Ref(CDept, depts, master: "Department", current: current?.Department_Code);
            var cat = r.Ref(CCat, cats, required: isInsert, master: "Test Category", current: current?.Category_Code);
            var sub = r.Ref(CSub, subs, master: "Sub Category", current: current?.SubCategory_Code);
            var sample = r.Ref(CSample, samples, master: "Sample Type", current: current?.Sample_Type_Name);
            var method = r.Ref(CMethod, methods, master: "Method", current: current?.Method_Name);
            var unit = r.Ref(CUnit, units, master: "Unit", current: current?.Unit_Name);
            var reporting = r.Option(CReporting, ReportingTypes);
            var tat = r.Int(CTat, min: 0, max: 720);
            var nabl = r.YesNo(CNabl);
            var nablScope = r.Text(CNablScope, maxLength: 100);
            var outsourced = r.YesNo(COutsourced);
            var profile = r.YesNo(CProfile);
            var gender = r.Option(CGender, Genders);
            var ageOp = r.Option(CAgeOp, AgeOperators);
            var age = r.Int(CAge, min: 0, max: 150);
            var billable = r.YesNo(CBillable);
            var fasting = r.YesNo(CFasting);
            var qty = r.Decimal(CQty, max: 10000);
            var qtyUnit = r.Ref(CQtyUnit, units, master: "Unit", current: current?.Sample_Quantity_Unit_Name);
            var durValue = r.Int(CDurValue, min: 1, max: 365);
            var durUnit = r.Option(CDurUnit, DurationUnits);
            var consent = r.YesNo(CConsent);
            var ovd = r.YesNo(COvd);
            var prescription = r.YesNo(CPrescription);
            var mrp = r.Decimal(CMrp, required: isInsert, max: 1000000);
            var status = r.Status(CStatus);
            r.RecordKey = code ?? name ?? string.Empty;

            if (r.HasErrors || (!isInsert && current == null))
            {
                result.AddFailure(r);
                continue;
            }

            var req = current != null ? ToUpdate(current) : new LabInvestigationUpdateRequest { Status = true, Is_Billable = true, TAT_Hours = 24 };
            var before = current != null ? ToUpdate(current) : null;

            // Hierarchy: Department ← Category ← Sub Category; Method ← Department.
            // Checked for new rows and for rows that change a link, so untouched legacy records still re-upload.
            req.Category_ID = cat?.Id ?? req.Category_ID;
            req.Department_ID = dept?.Id ?? (cat != null ? cat.DepartmentId : req.Department_ID);
            var deptOrCatChanged = before == null || before.Department_ID != req.Department_ID || before.Category_ID != req.Category_ID;
            var catRef = cats.ById(req.Category_ID);
            if (deptOrCatChanged && catRef != null && catRef.DepartmentId != req.Department_ID)
                r.Fail(CCat, LabBulkUploadRules.MismatchedRef, $"Test Category '{catRef.Name}' belongs to {catRef.DepartmentName}, not to the selected department.");

            req.SubCategory_ID = r.IsNone(CSub) ? null : sub?.Id ?? (before != null && before.Category_ID != req.Category_ID ? null : req.SubCategory_ID);
            var subRef = subs.ById(req.SubCategory_ID);
            if ((deptOrCatChanged || before!.SubCategory_ID != req.SubCategory_ID) && subRef != null && subRef.CategoryId != req.Category_ID)
                r.Fail(CSub, LabBulkUploadRules.MismatchedRef, $"Sub Category '{subRef.Name}' belongs to {subRef.CategoryName}, not to the selected Test Category.");

            req.Method_ID = r.IsNone(CMethod) ? null : method?.Id ?? req.Method_ID;
            var methodRef = methods.ById(req.Method_ID);
            if ((deptOrCatChanged || before!.Method_ID != req.Method_ID) && methodRef != null && methodRef.DepartmentId != req.Department_ID)
                r.Fail(CMethod, LabBulkUploadRules.MismatchedRef, $"Method '{methodRef.Name}' belongs to {methodRef.DepartmentName}, not to the selected department.");

            req.Test_Name = name ?? req.Test_Name;
            req.Sample_Type_ID = r.IsNone(CSample) ? null : sample?.Id ?? req.Sample_Type_ID;
            req.Unit_ID = r.IsNone(CUnit) ? null : unit?.Id ?? req.Unit_ID;
            req.Reporting_Type = Keep(reporting, req.Reporting_Type)!;
            req.TAT_Hours = tat ?? req.TAT_Hours;
            req.NABL_Accredited = nabl ?? req.NABL_Accredited;
            req.NABL_Scope_No = r.IsNone(CNablScope) ? null : nablScope ?? req.NABL_Scope_No;
            req.Is_Outsourced = outsourced ?? req.Is_Outsourced;
            req.Is_Profile_Test = profile ?? req.Is_Profile_Test;
            req.Applicable_Gender = Keep(gender, req.Applicable_Gender)!;
            req.Age_Operator = r.IsNone(CAgeOp) ? null : Keep(ageOp, req.Age_Operator);
            req.Applicable_Age = r.IsNone(CAge) ? null : age ?? req.Applicable_Age;
            req.Is_Billable = billable ?? req.Is_Billable;
            req.Is_Fasting_Required = fasting ?? req.Is_Fasting_Required;
            req.Sample_Quantity = r.IsNone(CQty) ? null : qty ?? req.Sample_Quantity;
            req.Sample_Quantity_Unit_ID = r.IsNone(CQtyUnit) ? null : qtyUnit?.Id ?? req.Sample_Quantity_Unit_ID;
            req.Reported_Duration_Value = r.IsNone(CDurValue) ? null : durValue ?? req.Reported_Duration_Value;
            req.Reported_Duration_Unit = Keep(durUnit, req.Reported_Duration_Unit);
            req.Is_Consent_Required = consent ?? req.Is_Consent_Required;
            req.OVD_Document = ovd ?? req.OVD_Document;
            req.Prescription_Required = prescription ?? req.Prescription_Required;
            req.MRP = mrp ?? req.MRP;
            req.Status = status ?? req.Status;

            if (string.IsNullOrEmpty(req.Age_Operator) != !req.Applicable_Age.HasValue)
                r.Fail(CAgeOp, LabBulkUploadRules.InvalidValue, "Age Operator and Applicable Age must be given together (or both left blank).");

            var key = $"{req.Department_ID}|{req.Test_Name.Trim()}";
            if (seenNames.TryGetValue(key, out var firstRow))
                r.Fail(CName, LabBulkUploadRules.DuplicateInFile, $"Test '{req.Test_Name}' for this department is already in row {firstRow}.");
            var nameOrDeptChanged = before == null || before.Department_ID != req.Department_ID
                                    || !string.Equals(before.Test_Name.Trim(), req.Test_Name.Trim(), StringComparison.OrdinalIgnoreCase);
            var clash = !nameOrDeptChanged ? null : existing.FirstOrDefault(i => i.Department_ID == req.Department_ID && i.Test_ID != current?.Test_ID
                && string.Equals(i.Test_Name.Trim(), req.Test_Name.Trim(), StringComparison.OrdinalIgnoreCase));
            if (clash != null)
                r.Fail(CName, LabBulkUploadRules.AlreadyExists, $"Test '{req.Test_Name}' already exists in {clash.Department_Name} with code {clash.Test_Code}. Put that code in '{CCode}' to update it.");

            if (r.HasErrors)
            {
                result.AddFailure(r);
                continue;
            }

            seenNames[key] = r.RowNo; // only rows that will be saved claim the name
            if (isInsert)
            {
                await result.SaveRowAsync(r, ctx, true, () => service.CreateAsync(ToCreate(req, ctx)));
            }
            else
            {
                if (BulkValues.SameJson(before, req)) { result.Unchanged++; continue; }
                req.UserId = ctx.UserId;
                await result.SaveRowAsync(r, ctx, false, () => service.UpdateAsync(req));
            }
        }
    }

    /// <summary>Option value from the file, unless it only differs from the stored value by case.</summary>
    private static string? Keep(string? fromFile, string? stored) =>
        fromFile == null || string.Equals(fromFile, stored, StringComparison.OrdinalIgnoreCase) ? stored : fromFile;

    private static LabInvestigationUpdateRequest ToUpdate(LabInvestigationListItem i) => new()
    {
        Test_ID = i.Test_ID, Department_ID = i.Department_ID, Category_ID = i.Category_ID, SubCategory_ID = i.SubCategory_ID,
        Sample_Type_ID = i.Sample_Type_ID, Method_ID = i.Method_ID, Unit_ID = i.Unit_ID, Test_Name = i.Test_Name,
        Reporting_Type = i.Reporting_Type, TAT_Hours = i.TAT_Hours ?? 24, NABL_Accredited = i.NABL_Accredited, NABL_Scope_No = i.NABL_Scope_No,
        Is_Outsourced = i.Is_Outsourced, Is_Profile_Test = i.Is_Profile_Test, Applicable_Gender = i.Applicable_Gender, Is_Billable = i.Is_Billable,
        Age_Operator = string.IsNullOrWhiteSpace(i.Age_Operator) ? null : i.Age_Operator, Applicable_Age = i.Applicable_Age,
        Is_Fasting_Required = i.Is_Fasting_Required, Sample_Quantity = i.Sample_Quantity, Sample_Quantity_Unit_ID = i.Sample_Quantity_Unit_ID,
        Reported_Duration_Value = i.Reported_Duration_Value, Reported_Duration_Unit = i.Reported_Duration_Unit, Is_Consent_Required = i.Is_Consent_Required,
        OVD_Document = i.OVD_Document, Prescription_Required = i.Prescription_Required, MRP = i.MRP, Status = i.Status
    };

    private static LabInvestigationCreateRequest ToCreate(LabInvestigationUpdateRequest u, BulkContext ctx) => new()
    {
        CompanyId = ctx.CompanyId, Department_ID = u.Department_ID, Category_ID = u.Category_ID, SubCategory_ID = u.SubCategory_ID,
        Sample_Type_ID = u.Sample_Type_ID, Method_ID = u.Method_ID, Unit_ID = u.Unit_ID, Test_Name = u.Test_Name,
        Reporting_Type = u.Reporting_Type, TAT_Hours = u.TAT_Hours, NABL_Accredited = u.NABL_Accredited, NABL_Scope_No = u.NABL_Scope_No,
        Is_Outsourced = u.Is_Outsourced, Is_Profile_Test = u.Is_Profile_Test, Applicable_Gender = u.Applicable_Gender, Is_Billable = u.Is_Billable,
        Age_Operator = u.Age_Operator, Applicable_Age = u.Applicable_Age, Is_Fasting_Required = u.Is_Fasting_Required,
        Sample_Quantity = u.Sample_Quantity, Sample_Quantity_Unit_ID = u.Sample_Quantity_Unit_ID,
        Reported_Duration_Value = u.Reported_Duration_Value, Reported_Duration_Unit = u.Reported_Duration_Unit,
        Is_Consent_Required = u.Is_Consent_Required, OVD_Document = u.OVD_Document, Prescription_Required = u.Prescription_Required,
        MRP = u.MRP, Status = u.Status, UserId = ctx.UserId
    };
}
