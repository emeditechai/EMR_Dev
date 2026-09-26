using EMR.Api.Models;

namespace EMR.Api.Services.BulkUpload;

public class SubCategoryBulkHandler(ILabTestSubCategoryService service, LabBulkLookups lookups) : ILabBulkUploadHandler
{
    private const string CCode = "Sub Category Code";
    private const string CCategory = "Test Category";
    private const string CName = "Sub Category Name";
    private const string COrder = "Display Order";
    private const string CStatus = "Status";
    private const string RefCategory = "REF_Category";

    public string Module => "sub-category";
    public string Title => "Test Sub Category";

    public async Task<BulkTemplate> BuildTemplateAsync(BulkContext ctx, bool withData)
    {
        var cats = await lookups.CategoriesAsync(ctx.CompanyId);
        var t = new BulkTemplate
        {
            SheetName = "SubCategory",
            Columns =
            [
                new() { Header = CCode, Note = "Leave blank to create a new sub category. Fill with an existing code (e.g. LSUBCAT0001) to update it.", Width = 18 },
                new() { Header = CCategory, Required = true, RefSheet = RefCategory, Note = "Parent test category. The department is taken from the category.", Width = 34 },
                new() { Header = CName, Required = true, Note = "Unique within the category. Max 150 characters.", Width = 36 },
                new() { Header = COrder, Kind = BulkColumnKind.Integer, Note = "Sort order. Default 1.", Width = 14 },
                new() { Header = CStatus, Options = BulkValues.StatusOptions, Note = "Default Active.", Width = 12 }
            ],
            RefSheets =
            [
                new() { Name = RefCategory, Headers = ["Select Value", "Category Code", "Category Name", "Department"],
                        Rows = cats.Items.Select(c => new object?[] { cats.Pick(c), c.Code, c.Name, c.DepartmentName }).ToList() }
            ]
        };

        if (withData)
        {
            var existing = await service.GetListAsync(null, null, null, ctx.CompanyId);
            t.DataRows.AddRange(existing.OrderBy(s => s.Category_Name).ThenBy(s => s.Display_Order).Select(s => new object?[]
            {
                s.SubCategory_Code, BulkValues.Pick(s.Category_Name, s.Category_Code), s.SubCategory_Name, s.Display_Order, BulkValues.Status(s.Status)
            }));
        }
        return t;
    }

    public async Task ImportAsync(IReadOnlyList<BulkRow> rows, BulkContext ctx, LabBulkUploadResult result)
    {
        var cats = await lookups.CategoriesAsync(ctx.CompanyId);
        var existing = (await service.GetListAsync(null, null, null, ctx.CompanyId)).ToList();
        var byCode = existing.GroupBy(s => s.SubCategory_Code, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);
        var seenCodes = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var seenNames = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);

        foreach (var row in rows)
        {
            var r = new RowReader(row);
            var code = r.Text(CCode);
            LabTestSubCategoryListItem? current = null;
            if (code != null)
            {
                if (!byCode.TryGetValue(code, out current))
                    r.Fail(CCode, LabBulkUploadRules.NotFound, $"Sub Category Code '{code}' does not exist. Leave it blank to create a new sub category.");
                else if (!seenCodes.TryAdd(code, r.RowNo))
                    r.Fail(CCode, LabBulkUploadRules.DuplicateInFile, $"Sub Category Code '{code}' is already used in row {seenCodes[code]}.");
            }
            var isInsert = code == null;
            var cat = r.Ref(CCategory, cats, required: isInsert, master: "Test Category", current: current?.Category_Code);
            var name = r.Text(CName, required: isInsert, maxLength: 150);
            var order = r.Int(COrder, min: 0);
            var status = r.Status(CStatus);
            r.RecordKey = code ?? name ?? string.Empty;

            if (!r.HasErrors && (isInsert || current != null))
            {
                var catId = cat?.Id ?? current!.Category_ID;
                var finalName = name ?? current!.SubCategory_Name;
                var key = $"{catId}|{finalName.Trim()}";
                // Duplicate checks apply to new and renamed rows, so legacy duplicates re-upload unchanged.
                var changed = current == null || current.Category_ID != catId || !string.Equals(current.SubCategory_Name.Trim(), finalName.Trim(), StringComparison.OrdinalIgnoreCase);
                if (changed && seenNames.TryGetValue(key, out var firstRow))
                    r.Fail(CName, LabBulkUploadRules.DuplicateInFile, $"Sub category '{finalName}' for this category is already in row {firstRow}.");
                var clash = !changed ? null : existing.FirstOrDefault(s => s.Category_ID == catId && s.SubCategory_ID != current?.SubCategory_ID
                    && string.Equals(s.SubCategory_Name.Trim(), finalName.Trim(), StringComparison.OrdinalIgnoreCase));
                if (clash != null)
                    r.Fail(CName, LabBulkUploadRules.AlreadyExists, $"Sub category '{finalName}' already exists under {clash.Category_Name} with code {clash.SubCategory_Code}. Put that code in '{CCode}' to update it.");

                if (!r.HasErrors)
                {
                    seenNames[key] = r.RowNo; // only rows that will be saved claim the name
                    if (isInsert)
                    {
                        await result.SaveRowAsync(r, ctx, true, async () =>
                        {
                            var id = await service.CreateAsync(new LabTestSubCategoryCreateRequest
                            {
                                Category_ID = catId, SubCategory_Name = finalName, Display_Order = order ?? 1, CompanyId = ctx.CompanyId, UserId = ctx.UserId
                            });
                            if (status == false)
                                await service.ToggleStatusAsync(new LabTestSubCategoryToggleStatusRequest { SubCategory_ID = id, Status = false, UserId = ctx.UserId });
                        });
                    }
                    else
                    {
                        var before = ToUpdate(current!);
                        var req = ToUpdate(current!);
                        req.Category_ID = catId;
                        req.SubCategory_Name = finalName;
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

    private static LabTestSubCategoryUpdateRequest ToUpdate(LabTestSubCategoryListItem s) => new()
    {
        SubCategory_ID = s.SubCategory_ID, Category_ID = s.Category_ID, SubCategory_Name = s.SubCategory_Name, Display_Order = s.Display_Order, Status = s.Status
    };
}
