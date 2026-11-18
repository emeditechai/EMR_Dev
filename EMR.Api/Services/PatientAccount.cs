using System.Data;
using Dapper;

namespace EMR.Api.Services;

/// <summary>
/// Who signs in to the patient app: the patient app signs in with the e-mail or the mobile number of the patient
/// record, not the Patient ID. One e-mail or mobile can belong to several patients - a family registered on the same
/// mobile (Patient Master: head of family = relation Self, RelationId 1). The account is then the head of family; else
/// the patient registered first. The head of family also sees the dependents' records (FamilyIdsAsync).
/// </summary>
public static class PatientAccount
{
    /// <summary>The digits of a mobile number: the last 10 of what was typed (so +91 / 0 prefixes still match).</summary>
    public static string? Mobile(string login)
    {
        var digits = new string(login.Where(char.IsDigit).ToArray());
        return digits.Length >= 10 ? digits[^10..] : null;
    }

    /// <summary>The patient whose account the e-mail or mobile number opens, or null.</summary>
    public static Task<int?> FindAsync(IDbConnection con, string login)
    {
        login = (login ?? "").Trim();
        var email = login.Contains('@') ? login.ToLowerInvariant() : null;
        var mobile = email is null ? Mobile(login) : null;
        if (email is null && mobile is null) return Task.FromResult<int?>(null);
        return con.QueryFirstOrDefaultAsync<int?>(
            @"SELECT TOP 1 PatientId
                FROM dbo.PatientMaster
               WHERE ISNULL(IsActive, 1) = 1
                 AND ((@email IS NOT NULL AND LOWER(LTRIM(RTRIM(EmailId))) = @email)
                   OR (@mobile IS NOT NULL AND LTRIM(RTRIM(PhoneNumber)) = @mobile))
               ORDER BY CASE WHEN RelationId = 1 THEN 0 ELSE 1 END, PatientId", new { email, mobile });
    }

    /// <summary>
    /// The dependents the patient sees: for a head of family, the other active patients registered on the same mobile
    /// in the same company (as Patient Master lists the family); for anyone else, none.
    /// </summary>
    public static async Task<List<int>> FamilyIdsAsync(IDbConnection con, int patientId) =>
        (await con.QueryAsync<int>(
            @"SELECT f.PatientId
                FROM dbo.PatientMaster p
                JOIN dbo.PatientMaster f ON LTRIM(RTRIM(f.PhoneNumber)) = LTRIM(RTRIM(p.PhoneNumber))
                                        AND ISNULL(f.CompanyId, 0) = ISNULL(p.CompanyId, 0) AND f.PatientId <> p.PatientId
                                        AND ISNULL(f.IsActive, 1) = 1
               WHERE p.PatientId = @patientId AND p.RelationId = 1 AND NULLIF(LTRIM(RTRIM(p.PhoneNumber)), '') IS NOT NULL
               ORDER BY f.PatientId", new { patientId })).ToList();
}
