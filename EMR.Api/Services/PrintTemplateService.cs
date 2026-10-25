using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IPrintTemplateService
{
    Task<List<PrintTemplateRow>> ListAsync(int companyId);
    Task<PrintTemplateDetail?> GetAsync(int companyId, int templateId);
    Task<int> SaveAsync(PrintTemplateSaveRequest r);
    Task<int> PublishAsync(PrintTemplateActionRequest r);
    Task RestoreAsync(PrintTemplateActionRequest r);
    Task DeleteAsync(PrintTemplateActionRequest r);
    Task<List<PrintTemplateAssignmentRow>> AssignmentsAsync(int companyId);
    Task AssignAsync(PrintTemplateAssignRequest r);
    Task<PrintTemplateResolved?> ResolveAsync(int branchId, string kind);
}

/// <summary>Utility > Print Templates (SQLScripts/2324): the usp_PrintTpl_* procedures.</summary>
public class PrintTemplateService(IDbConnectionFactory connectionFactory) : IPrintTemplateService
{
    private const CommandType Sp = CommandType.StoredProcedure;

    public async Task<List<PrintTemplateRow>> ListAsync(int companyId)
    {
        using var db = connectionFactory.CreateConnection();
        return (await db.QueryAsync<PrintTemplateRow>("dbo.usp_PrintTpl_List", new { CompanyId = companyId }, commandType: Sp)).ToList();
    }

    public async Task<PrintTemplateDetail?> GetAsync(int companyId, int templateId)
    {
        using var db = connectionFactory.CreateConnection();
        using var multi = await db.QueryMultipleAsync("dbo.usp_PrintTpl_Get", new { CompanyId = companyId, TemplateId = templateId }, commandType: Sp);
        var t = await multi.ReadSingleOrDefaultAsync<PrintTemplateDetail>();
        if (t is null) return null;
        t.Versions = (await multi.ReadAsync<PrintTemplateVersionRow>()).ToList();
        return t;
    }

    public async Task<int> SaveAsync(PrintTemplateSaveRequest r)
    {
        using var db = connectionFactory.CreateConnection();
        return await db.QuerySingleAsync<int>("dbo.usp_PrintTpl_Save",
            new { r.CompanyId, r.TemplateId, r.Kind, r.Name, r.DraftJson, r.UserId }, commandType: Sp);
    }

    public async Task<int> PublishAsync(PrintTemplateActionRequest r)
    {
        using var db = connectionFactory.CreateConnection();
        return await db.QuerySingleAsync<int>("dbo.usp_PrintTpl_Publish", new { r.CompanyId, r.TemplateId, r.UserId }, commandType: Sp);
    }

    public async Task RestoreAsync(PrintTemplateActionRequest r)
    {
        using var db = connectionFactory.CreateConnection();
        await db.ExecuteAsync("dbo.usp_PrintTpl_Restore", new { r.CompanyId, r.TemplateId, r.VersionNo, r.UserId }, commandType: Sp);
    }

    public async Task DeleteAsync(PrintTemplateActionRequest r)
    {
        using var db = connectionFactory.CreateConnection();
        await db.ExecuteAsync("dbo.usp_PrintTpl_Delete", new { r.CompanyId, r.TemplateId, r.UserId }, commandType: Sp);
    }

    public async Task<List<PrintTemplateAssignmentRow>> AssignmentsAsync(int companyId)
    {
        using var db = connectionFactory.CreateConnection();
        return (await db.QueryAsync<PrintTemplateAssignmentRow>("dbo.usp_PrintTpl_Assignments", new { CompanyId = companyId }, commandType: Sp)).ToList();
    }

    public async Task AssignAsync(PrintTemplateAssignRequest r)
    {
        using var db = connectionFactory.CreateConnection();
        await db.ExecuteAsync("dbo.usp_PrintTpl_Assign", new { r.CompanyId, r.BranchId, r.Kind, r.TemplateId, r.UserId }, commandType: Sp);
    }

    public async Task<PrintTemplateResolved?> ResolveAsync(int branchId, string kind)
    {
        using var db = connectionFactory.CreateConnection();
        return await db.QuerySingleOrDefaultAsync<PrintTemplateResolved>("dbo.usp_PrintTpl_Resolve", new { BranchId = branchId, Kind = kind }, commandType: Sp);
    }
}
