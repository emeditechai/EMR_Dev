using System.Data;
using Dapper;
using EMR.Common;

namespace EMR.Web.Services;

/// <summary>
/// Notifications in the patient's language (SQLScripts/2543) for the send paths that run in the background after the request
/// (WhatsApp / e-mail of a bill): the text of the patient's language through usp_Api_NotifyTemplate_Resolve on the sender's own
/// connection (no web request / user token there). Never throws: any problem = null = the message goes as before (English).
/// </summary>
public static class NotifyLanguage
{
    /// <summary>The patient's language (PatientMaster.LanguageId); null when not known.</summary>
    public static async Task<int?> OfPatientAsync(IDbConnection con, int? patientId)
    {
        if (patientId is not > 0) return null;
        try { return await con.QueryFirstOrDefaultAsync<int?>("SELECT LanguageId FROM dbo.PatientMaster WHERE PatientId = @patientId", new { patientId }); }
        catch { return null; }
    }

    /// <summary>The language of the patient of an OPD visit (PatientOPDService); null when not known.</summary>
    public static async Task<int?> OfOpdServiceAsync(IDbConnection con, int opdServiceId)
    {
        if (opdServiceId <= 0) return null;
        try
        {
            return await con.QueryFirstOrDefaultAsync<int?>(
                "SELECT p.LanguageId FROM dbo.PatientOPDService s JOIN dbo.PatientMaster p ON p.PatientId = s.PatientId WHERE s.OPDServiceId = @opdServiceId", new { opdServiceId });
        }
        catch { return null; }
    }

    /// <summary>The language of a membership card's holder (MembershipCard.PrimaryPatientId); null when not known.</summary>
    public static async Task<int?> OfCardHolderAsync(IDbConnection con, int cardId)
    {
        if (cardId <= 0) return null;
        try
        {
            return await con.QueryFirstOrDefaultAsync<int?>(
                "SELECT p.LanguageId FROM dbo.MembershipCard c JOIN dbo.PatientMaster p ON p.PatientId = c.PrimaryPatientId WHERE c.CardId = @cardId", new { cardId });
        }
        catch { return null; }
    }

    /// <summary>The language of the patient of a LAB order (LabOrder.PatientId); null when not known.</summary>
    public static async Task<int?> OfLabOrderAsync(IDbConnection con, int labOrderId)
    {
        if (labOrderId <= 0) return null;
        try
        {
            return await con.QueryFirstOrDefaultAsync<int?>(
                "SELECT p.LanguageId FROM dbo.LabOrder o JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId WHERE o.LabOrderId = @labOrderId", new { labOrderId });
        }
        catch { return null; }
    }

    /// <summary>The language of the patient with this Patient ID (PatientCode) in the branch's company; null when not known.</summary>
    public static async Task<int?> OfPatientCodeAsync(IDbConnection con, int branchId, string? patientCode)
    {
        if (string.IsNullOrWhiteSpace(patientCode)) return null;
        try
        {
            var langs = (await con.QueryAsync<int?>(
                @"SELECT DISTINCT p.LanguageId FROM dbo.PatientMaster p
                  WHERE p.PatientCode = @patientCode AND p.LanguageId IS NOT NULL
                    AND (p.CompanyId IS NULL OR p.CompanyId = (SELECT CompanyId FROM dbo.BranchMaster WHERE BranchID = @branchId))",
                new { patientCode = patientCode.Trim(), branchId })).ToList();
            return langs.Count == 1 ? langs[0] : null;
        }
        catch { return null; }
    }

    /// <summary>The language of the patient with this mobile (pharmacy customers without a patient link); null when none / unclear.</summary>
    public static async Task<int?> OfMobileAsync(IDbConnection con, string? mobile)
    {
        var digits = new string((mobile ?? "").Where(char.IsDigit).ToArray());
        if (digits.Length < 10) return null;
        digits = digits[^10..];
        try
        {
            // only when every patient with that mobile has the same language (family members may share a number)
            var langs = (await con.QueryAsync<int?>("SELECT DISTINCT LanguageId FROM dbo.PatientMaster WHERE RIGHT(PhoneNumber, 10) = @digits AND LanguageId IS NOT NULL", new { digits })).ToList();
            return langs.Count == 1 ? langs[0] : null;
        }
        catch { return null; }
    }

    public static async Task<NotifyTemplateText?> ResolveAsync(IDbConnection con, int branchId, string eventCode, string channel, int? languageId, ILogger? logger = null)
    {
        if (languageId is not > 0) return null;
        try
        {
            var companyId = await con.QueryFirstOrDefaultAsync<int?>("SELECT CompanyId FROM dbo.BranchMaster WHERE BranchID = @branchId", new { branchId }) ?? 1;
            return await con.QueryFirstOrDefaultAsync<NotifyTemplateText>("dbo.usp_Api_NotifyTemplate_Resolve",
                new { CompanyId = companyId, BranchId = branchId, EventCode = eventCode, Channel = channel, LanguageId = languageId }, commandType: CommandType.StoredProcedure);
        }
        catch (Exception ex)
        {
            logger?.LogWarning(ex, "[NOTIFY-LANG] {Event}/{Channel} text for language {Lang} not read - sent in English", eventCode, channel, languageId);
            return null;
        }
    }

    /// <summary>The WhatsApp text in the patient's language, or <paramref name="english"/> (as built today) when there is none.</summary>
    public static async Task<string> WhatsAppAsync(IDbConnection con, int branchId, string eventCode, int? languageId,
        IReadOnlyDictionary<string, string?> values, string english, ILogger? logger = null)
    {
        var t = await ResolveAsync(con, branchId, eventCode, NotifyText.WhatsApp, languageId, logger);
        if (t == null || string.IsNullOrWhiteSpace(t.Body)) return english;
        logger?.LogInformation("[NOTIFY-LANG] {Event} WhatsApp in {Language}", eventCode, t.LanguageName);
        return NotifyText.Fill(t.Body, values);
    }

    /// <summary>The e-mail (subject, HTML body) in the patient's language; null = send the English e-mail as built today.</summary>
    public static async Task<(string Subject, string Html)?> EmailAsync(IDbConnection con, int branchId, string eventCode, int? languageId,
        IReadOnlyDictionary<string, string?> values, string? hospitalName, string? address, ILogger? logger = null)
    {
        var t = await ResolveAsync(con, branchId, eventCode, NotifyText.Email, languageId, logger);
        if (t == null || string.IsNullOrWhiteSpace(t.Body) || string.IsNullOrWhiteSpace(t.Subject)) return null;
        logger?.LogInformation("[NOTIFY-LANG] {Event} e-mail in {Language}", eventCode, t.LanguageName);
        return (NotifyText.Fill(t.Subject, values), NotifyText.EmailHtml(t, values, hospitalName, address));
    }
}
