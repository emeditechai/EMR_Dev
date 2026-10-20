using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;
using Microsoft.Data.SqlClient;

namespace EMR.Api.Services;

public interface ICompanyOnboardingService
{
    Task<List<CompanyOnboardTemplate>> TemplatesAsync();
    Task<CompanyOnboardCheck> CheckAsync(string? companyCode, string? branchCode, string? username);
    /// <summary>Creates the company and all it needs in one transaction; Error is set (nothing created) when refused.</summary>
    Task<(CompanyOnboardResult? Result, string? Error)> OnboardAsync(CompanyOnboardRequest request);
}

/// <summary>
/// Settings > Company Master > New Company wizard (SQLScripts/2306): company, Head Office branch, Hospital Settings,
/// navigation copied from a template company, Administrator role and the first user - all or nothing.
/// </summary>
public class CompanyOnboardingService(IDbConnectionFactory connectionFactory) : ICompanyOnboardingService
{
    private const CommandType Sp = CommandType.StoredProcedure;

    public async Task<List<CompanyOnboardTemplate>> TemplatesAsync()
    {
        using var db = connectionFactory.CreateConnection();
        return (await db.QueryAsync<CompanyOnboardTemplate>("dbo.usp_Api_Company_OnboardTemplates", commandType: Sp)).ToList();
    }

    public async Task<CompanyOnboardCheck> CheckAsync(string? companyCode, string? branchCode, string? username)
    {
        using var db = connectionFactory.CreateConnection();
        return await db.QueryFirstAsync<CompanyOnboardCheck>("dbo.usp_Api_Company_OnboardCheck",
            new { CompanyCode = companyCode, BranchCode = branchCode, Username = username }, commandType: Sp);
    }

    public async Task<(CompanyOnboardResult? Result, string? Error)> OnboardAsync(CompanyOnboardRequest r)
    {
        try
        {
            using var db = connectionFactory.CreateConnection();
            var result = await db.QueryFirstAsync<CompanyOnboardResult>("dbo.usp_Api_Company_Onboard", r, commandType: Sp, commandTimeout: 120);
            return (result, null);
        }
        catch (SqlException ex) when (ex.Number is >= 50001 and <= 50099)
        {
            return (null, ex.Message);   // the procedure's own reasons (code / username taken, missing values)
        }
        catch (SqlException ex) when (ex.Number is 2601 or 2627)
        {
            return (null, "A value is already used (company code, branch code or username). Nothing was created.");
        }
    }
}
