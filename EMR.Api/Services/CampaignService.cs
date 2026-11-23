using System.Data;
using System.Text.Json;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

/// <summary>Utility > Campaigns (SQLScripts/2299) over the usp_Campaign_* / usp_CampaignTemplate_* procedures.</summary>
public interface ICampaignService
{
    Task<CampaignListResult> ListAsync(int companyId, int branchId, bool allBranches);
    Task<CampaignDetailDto?> GetAsync(int campaignId, int companyId, int branchId, bool allBranches);
    Task<CampaignOptionsResult> OptionsAsync(int companyId);
    Task<CampaignAudienceSummary> AudienceAsync(CampaignAudienceRequest request);
    Task<List<CampaignPersonDto>> SearchAsync(int companyId, string audienceType, string? term);
    /// <summary>Throws <see cref="ArgumentException"/> with a message for the user.</summary>
    Task<CampaignSaveResult> SaveAsync(CampaignSaveRequest request);
    Task<List<CampaignRecipientDto>> RecipientsAsync(int campaignId, int companyId, string? status, string? search);
    Task<int> ActionAsync(CampaignActionRequest request);
    Task<CampaignTemplateDto?> TemplateGetAsync(int templateId, int companyId);
    Task<List<CampaignTemplateRowDto>> TemplateListAsync(int companyId, string audienceType);
    Task<int> TemplateSaveAsync(CampaignTemplateDto template);
    Task<int> TemplateDeleteAsync(int templateId, int companyId);
    Task<List<CampaignRunningDto>> SenderRunningAsync();
    Task<List<CampaignPendingDto>> SenderNextAsync(int campaignId, int batch);
    Task<bool> SenderMarkAsync(CampaignMarkRequest request);
    Task SenderFinishAsync(int campaignId);
    Task OptOutAsync(CampaignOptOutRequest request);
}

public class CampaignService(IDbConnectionFactory connectionFactory) : ICampaignService
{
    private const CommandType Sp = CommandType.StoredProcedure;

    private static string Type(string? t) => t is "U" or "D" ? t : "P";

    public async Task<CampaignListResult> ListAsync(int companyId, int branchId, bool allBranches)
    {
        using var db = connectionFactory.CreateConnection();
        using var multi = await db.QueryMultipleAsync("dbo.usp_Campaign_List", new { CompanyId = companyId, BranchId = branchId, AllBranches = allBranches }, commandType: Sp);
        return new CampaignListResult
        {
            Campaigns = (await multi.ReadAsync<CampaignRowDto>()).ToList(),
            Templates = (await multi.ReadAsync<CampaignTemplateRowDto>()).ToList()
        };
    }

    public async Task<CampaignDetailDto?> GetAsync(int campaignId, int companyId, int branchId, bool allBranches)
    {
        using var db = connectionFactory.CreateConnection();
        return await db.QueryFirstOrDefaultAsync<CampaignDetailDto>("dbo.usp_Campaign_Get",
            new { CampaignId = campaignId, CompanyId = companyId, BranchId = branchId, AllBranches = allBranches }, commandType: Sp);
    }

    public async Task<CampaignOptionsResult> OptionsAsync(int companyId)
    {
        using var db = connectionFactory.CreateConnection();
        using var multi = await db.QueryMultipleAsync("dbo.usp_Campaign_Options", new { CompanyId = companyId }, commandType: Sp);
        return new CampaignOptionsResult
        {
            Branches = (await multi.ReadAsync<CampaignBranchOption>()).ToList(),
            Roles = (await multi.ReadAsync<CampaignOption>()).ToList(),
            Specialities = (await multi.ReadAsync<CampaignOption>()).ToList()
        };
    }

    private async Task<List<CampaignPersonDto>> PeopleAsync(int companyId, string audienceType, CampaignAudienceFilter f, string? search, int top)
    {
        var mode = f.Mode is "FILTER" or "PICK" ? f.Mode : "ALL";
        if (mode == "PICK" && f.Ids.Count == 0) return [];
        using var db = connectionFactory.CreateConnection();
        return (await db.QueryAsync<CampaignPersonDto>("dbo.usp_Campaign_AudienceList", new
        {
            CompanyId = companyId, AudienceType = Type(audienceType), Mode = mode,
            Ids = mode == "PICK" ? string.Join(",", f.Ids.Distinct()) : null,
            f.BranchId, Gender = string.IsNullOrWhiteSpace(f.Gender) ? null : f.Gender, f.AgeFrom, f.AgeTo,
            VisitFrom = f.VisitFrom?.Date, VisitTo = f.VisitTo?.Date, RegisteredFrom = f.RegisteredFrom?.Date, RegisteredTo = f.RegisteredTo?.Date,
            f.RoleId, f.SpecialityId, DoctorKind = f.DoctorKind is "C" or "R" ? f.DoctorKind : null,
            Search = string.IsNullOrWhiteSpace(search) ? null : search.Trim(), Top = top
        }, commandType: Sp, commandTimeout: 120)).ToList();
    }

    private static bool ValidEmail(string? e) => !string.IsNullOrWhiteSpace(e) && System.Net.Mail.MailAddress.TryCreate(e.Trim(), out _);

    /// <summary>Everyone of the selection with the reason a person is not emailed (null = to be emailed).</summary>
    private static List<(CampaignPersonDto P, string? Skip)> Classify(List<CampaignPersonDto> people)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        return people.Select(p =>
        {
            if (!ValidEmail(p.Email)) return (p, (string?)"No email address");
            if (p.OptedOut) return (p, "Unsubscribed from campaign emails");
            if (!seen.Add(p.Email!.Trim())) return (p, "Same email as another recipient");
            return (p, (string?)null);
        }).ToList();
    }

    public async Task<CampaignAudienceSummary> AudienceAsync(CampaignAudienceRequest request)
    {
        var people = await PeopleAsync(request.CompanyId, request.AudienceType, request.Filter, null, 100_000);
        var c = Classify(people);
        return new CampaignAudienceSummary
        {
            Total = people.Count,
            Reachable = c.Count(x => x.Skip is null),
            NoEmail = c.Count(x => x.Skip == "No email address"),
            Unsubscribed = c.Count(x => x.Skip == "Unsubscribed from campaign emails"),
            SharedEmail = c.Count(x => x.Skip == "Same email as another recipient"),
            Sample = c.Where(x => x.Skip is null).Take(8).Select(x => x.P).ToList()
        };
    }

    public Task<List<CampaignPersonDto>> SearchAsync(int companyId, string audienceType, string? term) =>
        PeopleAsync(companyId, audienceType, new CampaignAudienceFilter(), term, 30);

    /// <summary>The merge field values of one person (Hospital Name is added by the sender from the sending branch).</summary>
    private static Dictionary<string, string?> Fields(string type, CampaignPersonDto p) => type switch
    {
        "P" => new() { ["Name"] = p.Name, ["FirstName"] = p.FirstName, ["PatientCode"] = p.Code },
        "U" => new() { ["Name"] = p.Name, ["FirstName"] = p.FirstName, ["LoginId"] = p.Code },
        _ => new() { ["Name"] = p.Name, ["FirstName"] = p.FirstName, ["Speciality"] = p.Extra }
    };

    public async Task<CampaignSaveResult> SaveAsync(CampaignSaveRequest r)
    {
        var type = Type(r.AudienceType);
        var action = r.Action is "send" or "schedule" ? r.Action : "draft";
        if (string.IsNullOrWhiteSpace(r.Name)) throw new ArgumentException("Give the campaign a name.");
        if (string.IsNullOrWhiteSpace(r.Subject)) throw new ArgumentException("Enter the subject line.");
        if (r.BranchId <= 0) throw new ArgumentException("Choose the branch the emails are sent from.");
        if (action == "schedule" && (r.ScheduledAt is null || r.ScheduledAt < DateTime.Now.AddMinutes(1)))
            throw new ArgumentException("Choose a send time in the future.");

        string? recipientsJson = null;
        int queued = 0, skipped = 0;
        if (action != "draft")
        {
            if (string.IsNullOrWhiteSpace(r.HtmlBody)) throw new ArgumentException("The message is empty.");
            var c = Classify(await PeopleAsync(r.CompanyId, type, r.Filter, null, 100_000));
            queued = c.Count(x => x.Skip is null);
            skipped = c.Count - queued;
            if (queued == 0) throw new ArgumentException("None of the selected people can receive this email (no email address, or unsubscribed).");
            recipientsJson = JsonSerializer.Serialize(c.Select(x => new
            {
                refId = x.P.RefId, name = x.P.Name, email = x.P.Email?.Trim(),
                fieldsJson = JsonSerializer.Serialize(Fields(type, x.P)),
                status = x.Skip is null ? "P" : "X", message = x.Skip
            }));
        }

        using var db = connectionFactory.CreateConnection();
        try
        {
            var id = await db.ExecuteScalarAsync<int>("dbo.usp_Campaign_Save", new
            {
                r.CampaignId, r.CompanyId, r.BranchId, Name = r.Name.Trim(), AudienceType = type, r.TemplateId, Subject = r.Subject.Trim(),
                r.DesignJson, r.HtmlBody, SelectionMode = r.Filter.Mode is "FILTER" or "PICK" ? r.Filter.Mode : "ALL",
                FilterJson = JsonSerializer.Serialize(r.Filter, new JsonSerializerOptions(JsonSerializerDefaults.Web)), r.BaseUrl,
                Status = action switch { "send" => "SENDING", "schedule" => "SCHEDULED", _ => "DRAFT" },
                ScheduledAt = action == "schedule" ? r.ScheduledAt : null, r.UserId, RecipientsJson = recipientsJson
            }, commandType: Sp, commandTimeout: 120);
            return new CampaignSaveResult { CampaignId = id, Queued = queued, Skipped = skipped };
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is 51001 or 51002)
        {
            throw new ArgumentException(ex.Message);
        }
    }

    public async Task<List<CampaignRecipientDto>> RecipientsAsync(int campaignId, int companyId, string? status, string? search)
    {
        using var db = connectionFactory.CreateConnection();
        return (await db.QueryAsync<CampaignRecipientDto>("dbo.usp_Campaign_Recipients", new
        {
            CampaignId = campaignId, CompanyId = companyId, Status = status is "S" or "F" or "X" or "P" ? status : null,
            Search = string.IsNullOrWhiteSpace(search) ? null : search.Trim()
        }, commandType: Sp)).ToList();
    }

    public async Task<int> ActionAsync(CampaignActionRequest r)
    {
        using var db = connectionFactory.CreateConnection();
        return await db.ExecuteScalarAsync<int>("dbo.usp_Campaign_Action",
            new { r.CampaignId, r.CompanyId, Action = r.Action.ToUpperInvariant(), r.UserId }, commandType: Sp);
    }

    public async Task<CampaignTemplateDto?> TemplateGetAsync(int templateId, int companyId)
    {
        using var db = connectionFactory.CreateConnection();
        return await db.QueryFirstOrDefaultAsync<CampaignTemplateDto>("dbo.usp_CampaignTemplate_Get", new { TemplateId = templateId, CompanyId = companyId }, commandType: Sp);
    }

    public async Task<List<CampaignTemplateRowDto>> TemplateListAsync(int companyId, string audienceType)
    {
        using var db = connectionFactory.CreateConnection();
        return (await db.QueryAsync<CampaignTemplateRowDto>("dbo.usp_CampaignTemplate_List", new { CompanyId = companyId, AudienceType = Type(audienceType) }, commandType: Sp)).ToList();
    }

    public async Task<int> TemplateSaveAsync(CampaignTemplateDto t)
    {
        if (string.IsNullOrWhiteSpace(t.Name)) throw new ArgumentException("Give the template a name.");
        if (string.IsNullOrWhiteSpace(t.Subject)) throw new ArgumentException("Enter the subject line.");
        using var db = connectionFactory.CreateConnection();
        try
        {
            return await db.ExecuteScalarAsync<int>("dbo.usp_CampaignTemplate_Save", new
            {
                t.TemplateId, t.CompanyId, Name = t.Name.Trim(), AudienceType = Type(t.AudienceType), Subject = t.Subject.Trim(), t.DesignJson, t.IsActive, t.UserId
            }, commandType: Sp);
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 51011)
        {
            throw new ArgumentException(ex.Message);
        }
    }

    public async Task<int> TemplateDeleteAsync(int templateId, int companyId)
    {
        using var db = connectionFactory.CreateConnection();
        return await db.ExecuteScalarAsync<int>("dbo.usp_CampaignTemplate_Delete", new { TemplateId = templateId, CompanyId = companyId }, commandType: Sp);
    }

    public async Task<List<CampaignRunningDto>> SenderRunningAsync()
    {
        using var db = connectionFactory.CreateConnection();
        return (await db.QueryAsync<CampaignRunningDto>("dbo.usp_Campaign_SenderRunning", commandType: Sp)).ToList();
    }

    public async Task<List<CampaignPendingDto>> SenderNextAsync(int campaignId, int batch)
    {
        using var db = connectionFactory.CreateConnection();
        return (await db.QueryAsync<CampaignPendingDto>("dbo.usp_Campaign_SenderNext", new { CampaignId = campaignId, Batch = Math.Clamp(batch, 1, 500) }, commandType: Sp)).ToList();
    }

    public async Task<bool> SenderMarkAsync(CampaignMarkRequest r)
    {
        using var db = connectionFactory.CreateConnection();
        var msg = r.Message is { Length: > 500 } ? r.Message[..500] : r.Message;
        return await db.ExecuteScalarAsync<bool?>("dbo.usp_Campaign_SenderMark",
            new { r.RecipientId, Status = r.Status == "S" ? "S" : "F", Message = msg }, commandType: Sp) ?? false;
    }

    public async Task SenderFinishAsync(int campaignId)
    {
        using var db = connectionFactory.CreateConnection();
        await db.ExecuteAsync("dbo.usp_Campaign_SenderFinish", new { CampaignId = campaignId }, commandType: Sp);
    }

    public async Task OptOutAsync(CampaignOptOutRequest r)
    {
        using var db = connectionFactory.CreateConnection();
        await db.ExecuteAsync("dbo.usp_Campaign_OptOut", new { r.CompanyId, r.Email, r.CampaignId }, commandType: Sp);
    }
}
