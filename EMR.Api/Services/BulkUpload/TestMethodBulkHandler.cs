using EMR.Api.Models;

namespace EMR.Api.Services.BulkUpload;

public class TestMethodBulkHandler(ILabTestMethodService service, LabBulkLookups lookups) : ILabBulkUploadHandler
{
    private const string CCode = "Method Code";
    private const string CDept = "Department";
    private const string CName = "Method Name";
    private const string COrder = "Display Order";
    private const string CStatus = "Status";
    private const string RefDept = "REF_Department";

    public string Module => "test-method";
    public string Title => "Test Method";

    public async Task<BulkTemplate> BuildTemplateAsync(BulkContext ctx, bool withData)
    {
        var depts = await lookups.DepartmentsAsync(ctx.CompanyId);
        var t = new BulkTemplate
        {
            SheetName = "TestMethod",
            Columns =
            [
                new() { Header = CCode, Note = "Leave blank to create a new method. Fill with an existing code (e.g. MTH0001) to update it.", Width = 16 },
                new() { Header = CDept, Required = true, RefSheet = RefDept, Note = "Lab department the method belongs to.", Width = 30 },
                new() { Header = CName, Required = true, Note = "Unique within the department. Max 150 characters.", Width = 36 },
                new() { Header = COrder, Kind = BulkColumnKind.Integer, Note = "Sort order. Default 1.", Width = 14 },
                new() { Header = CStatus, Options = BulkValues.StatusOptions, Note = "Default Active.", Width = 12 }
            ],
            RefSheets =
            [
                new() { Name = RefDept, Headers = ["Select Value", "Department Code", "Department Name"],
                        Rows = depts.Items.Select(d => new object?[] { depts.Pick(d), d.Code, d.Name }).ToList() }
            ]
        };

        if (withData)
        {
            var existing = await service.GetListAsync(null, null, null, ctx.CompanyId);
            t.DataRows.AddRange(existing.OrderBy(m => m.Department_Name).ThenBy(m => m.Display_Order).Select(m => new object?[]
            {
                m.Method_Code, BulkValues.Pick(m.Department_Name, m.Department_Code), m.Method_Name, m.Display_Order, BulkValues.Status(m.Status)
            }));
        }
        return t;
    }

    public async Task ImportAsync(IReadOnlyList<BulkRow> rows, BulkContext ctx, LabBulkUploadResult result)
    {
        var depts = await lookups.DepartmentsAsync(ctx.CompanyId);
        var existing = (await service.GetListAsync(null, null, null, ctx.CompanyId)).ToList();
        var byCode = existing.GroupBy(m => m.Method_Code, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);
        var seenCodes = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var seenNames = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);

        foreach (var row in rows)
        {
            var r = new RowReader(row);
            var code = r.Text(CCode);
            LabTestMethodListItem? current = null;
            if (code != null)
            {
                if (!byCode.TryGetValue(code, out current))
                    r.Fail(CCode, LabBulkUploadRules.NotFound, $"Method Code '{code}' does not exist. Leave it blank to create a new method.");
                else if (!seenCodes.TryAdd(code, r.RowNo))
                    r.Fail(CCode, LabBulkUploadRules.DuplicateInFile, $"Method Code '{code}' is already used in row {seenCodes[code]}.");
            }
            var isInsert = code == null;
            var dept = r.Ref(CDept, depts, required: isInsert, master: "Department", current: current?.Department_Code);
            var name = r.Text(CName, required: isInsert, maxLength: 150);
            var order = r.Int(COrder, min: 0);
            var status = r.Status(CStatus);
            r.RecordKey = code ?? name ?? string.Empty;

            if (!r.HasErrors && (isInsert || current != null))
            {
                var deptId = dept?.Id ?? current!.Department_ID;
                var finalName = name ?? current!.Method_Name;
                var key = $"{deptId}|{finalName.Trim()}";
                // Duplicate checks apply to new and renamed rows, so legacy duplicates re-upload unchanged.
                var changed = current == null || current.Department_ID != deptId || !string.Equals(current.Method_Name.Trim(), finalName.Trim(), StringComparison.OrdinalIgnoreCase);
                if (changed && seenNames.TryGetValue(key, out var firstRow))
                    r.Fail(CName, LabBulkUploadRules.DuplicateInFile, $"Method '{finalName}' for this department is already in row {firstRow}.");
                var clash = !changed ? null : existing.FirstOrDefault(m => m.Department_ID == deptId && m.Method_ID != current?.Method_ID
                    && string.Equals(m.Method_Name.Trim(), finalName.Trim(), StringComparison.OrdinalIgnoreCase));
                if (clash != null)
                    r.Fail(CName, LabBulkUploadRules.AlreadyExists, $"Method '{finalName}' already exists in {clash.Department_Name} with code {clash.Method_Code}. Put that code in '{CCode}' to update it.");

                if (!r.HasErrors)
                {
                    seenNames[key] = r.RowNo; // only rows that will be saved claim the name
                    if (isInsert)
                    {
                        await result.SaveRowAsync(r, ctx, true, async () =>
                        {
                            var id = await service.CreateAsync(new LabTestMethodCreateRequest
                            {
                                Department_ID = deptId, Method_Name = finalName, Display_Order = order ?? 1, CompanyId = ctx.CompanyId, UserId = ctx.UserId
                            });
                            if (status == false)
                                await service.ToggleStatusAsync(new LabTestMethodToggleStatusRequest { Method_ID = id, Status = false, UserId = ctx.UserId });
                        });
                    }
                    else
                    {
                        var before = ToUpdate(current!);
                        var req = ToUpdate(current!);
                        req.Department_ID = deptId;
                        req.Method_Name = finalName;
                        req.Display_Order = order ?? req.Display_Order;
                        req.Status = status ?? req.Status;
                        if (BulkValues.SameJson(before, req)) { result.Unchanged++; continue; }
                        req.UserId = ctx.UserId;
                        await result.SaveRowAsync(r, ctx, false, () => service.UpdateAsync(req));
                    }
                    continue;
                }
            }
            result.AddFailure(r);
        }
    }

    private static LabTestMethodUpdateRequest ToUpdate(LabTestMethodListItem m) => new()
    {
        Method_ID = m.Method_ID, Department_ID = m.Department_ID, Method_Name = m.Method_Name, Display_Order = m.Display_Order, Status = m.Status
    };
}
