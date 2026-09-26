using EMR.Api.Models;
using EMR.Api.Services.BulkUpload;

namespace EMR.Api.Services;

public interface ILabBulkUploadService
{
    bool IsSupported(string module);
    Task<(byte[] Content, string FileName)> BuildTemplateAsync(string module, bool withData, BulkContext ctx);
    Task<LabBulkUploadResult> ImportAsync(string module, Stream file, BulkContext ctx);
}

public class LabBulkUploadService(IEnumerable<ILabBulkUploadHandler> handlers) : ILabBulkUploadService
{
    private ILabBulkUploadHandler Handler(string module) =>
        handlers.FirstOrDefault(h => string.Equals(h.Module, module, StringComparison.OrdinalIgnoreCase))
        ?? throw new ArgumentException($"Unknown bulk upload module '{module}'.");

    public bool IsSupported(string module) => handlers.Any(h => string.Equals(h.Module, module, StringComparison.OrdinalIgnoreCase));

    public async Task<(byte[] Content, string FileName)> BuildTemplateAsync(string module, bool withData, BulkContext ctx)
    {
        var handler = Handler(module);
        var template = await handler.BuildTemplateAsync(ctx, withData);
        var content = BulkExcel.Build(handler.Title, template);
        var fileName = $"{template.SheetName}_{(withData ? "Data" : "Template")}_{DateTime.Now:yyyyMMdd_HHmm}.xlsx";
        return (content, fileName);
    }

    public async Task<LabBulkUploadResult> ImportAsync(string module, Stream file, BulkContext ctx)
    {
        var handler = Handler(module);
        var result = new LabBulkUploadResult { Module = handler.Module, ModuleTitle = handler.Title, DryRun = ctx.DryRun };

        var template = await handler.BuildTemplateAsync(ctx, withData: false);
        var (rows, error) = BulkExcel.Read(file, template);
        if (error != null)
        {
            result.FileError = error;
            return result;
        }

        result.TotalRows = rows.Count;
        await handler.ImportAsync(rows, ctx, result);

        result.Errors = result.Errors.OrderBy(e => e.RowNo).ToList();
        result.ViolationSummary = result.Errors
            .GroupBy(e => e.Rule)
            .Select(g => new LabBulkUploadViolationSummary { Rule = g.Key, Occurrences = g.Count(), RowsAffected = g.Select(e => e.RowNo).Distinct().Count() })
            .OrderByDescending(v => v.Occurrences)
            .ToList();
        return result;
    }
}
