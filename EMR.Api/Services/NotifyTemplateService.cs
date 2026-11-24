using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Common;

namespace EMR.Api.Services;

/// <summary>Notification texts per language (SQLScripts/2543): the template for a patient's language, and the settings page data.</summary>
public interface INotifyTemplateService
{
    /// <summary>The text for the language (branch's own, else the company's); null = none, send as before.</summary>
    Task<NotifyTemplateText?> ResolveAsync(int companyId, int branchId, string eventCode, string channel, int? languageId);
    /// <summary>The WhatsApp text in this patient's language (PatientMaster.LanguageId), or <paramref name="english"/> when there is
    /// none. Never throws: any problem = the English text.</summary>
    Task<string> WhatsAppForPatientAsync(int branchId, string eventCode, int? patientId, IReadOnlyDictionary<string, string?> values, string english);
    Task<List<List<IDictionary<string, object?>>>> LookupsAsync(int companyId);
    Task<List<IDictionary<string, object?>>> ListAsync(int companyId, string? eventCode);
    Task<IDictionary<string, object?>?> SaveAsync(object args);
}

public class NotifyTemplateService(IDbConnectionFactory db, ILogger<NotifyTemplateService> logger) : INotifyTemplateService
{
    public async Task<string> WhatsAppForPatientAsync(int branchId, string eventCode, int? patientId, IReadOnlyDictionary<string, string?> values, string english)
    {
        if (patientId is not > 0) return english;
        try
        {
            using var con = db.CreateConnection();
            var x = await con.QueryFirstOrDefaultAsync<(int? LanguageId, int? CompanyId)>(
                @"SELECT p.LanguageId, (SELECT CompanyId FROM dbo.BranchMaster WHERE BranchID = @branchId) FROM dbo.PatientMaster p WHERE p.PatientId = @patientId",
                new { branchId, patientId });
            var t = await ResolveAsync(x.CompanyId ?? 1, branchId, eventCode, NotifyText.WhatsApp, x.LanguageId);
            if (t == null || string.IsNullOrWhiteSpace(t.Body)) return english;
            logger.LogInformation("[NOTIFY-LANG] {Event} WhatsApp in {Language}", eventCode, t.LanguageName);
            return NotifyText.Fill(t.Body, values);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "[NOTIFY-LANG] {Event} text not read for patient {PatientId} - sent in English", eventCode, patientId);
            return english;
        }
    }

    private static List<IDictionary<string, object?>> AsRows(IEnumerable<dynamic> rows) =>
        rows.Select(r => (IDictionary<string, object?>)(IDictionary<string, object>)r).ToList();

    public async Task<NotifyTemplateText?> ResolveAsync(int companyId, int branchId, string eventCode, string channel, int? languageId)
    {
        if (languageId is not > 0) return null;
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<NotifyTemplateText>("dbo.usp_Api_NotifyTemplate_Resolve",
            new { CompanyId = companyId, BranchId = branchId, EventCode = eventCode, Channel = channel, LanguageId = languageId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<List<List<IDictionary<string, object?>>>> LookupsAsync(int companyId)
    {
        using var con = db.CreateConnection();
        using var m = await con.QueryMultipleAsync("dbo.usp_Api_NotifyTemplate_Lookups", new { CompanyId = companyId }, commandType: CommandType.StoredProcedure);
        var sets = new List<List<IDictionary<string, object?>>>();
        for (var i = 0; i < 3; i++) sets.Add(AsRows(await m.ReadAsync()));
        return sets;
    }

    public async Task<List<IDictionary<string, object?>>> ListAsync(int companyId, string? eventCode)
    {
        using var con = db.CreateConnection();
        return AsRows(await con.QueryAsync("dbo.usp_Api_NotifyTemplate_List", new { CompanyId = companyId, EventCode = eventCode }, commandType: CommandType.StoredProcedure));
    }

    public async Task<IDictionary<string, object?>?> SaveAsync(object args)
    {
        using var con = db.CreateConnection();
        var row = await con.QueryFirstOrDefaultAsync("dbo.usp_Api_NotifyTemplate_Save", args, commandType: CommandType.StoredProcedure);
        return row == null ? null : (IDictionary<string, object?>)(IDictionary<string, object>)row;
    }
}
