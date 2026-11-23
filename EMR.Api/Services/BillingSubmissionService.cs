using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IBillingSubmissionService
{
    Task<BillingSubmissionClaimResult> ClaimAsync(BillingSubmissionClaimRequest request);
    Task UpdateAsync(BillingSubmissionUpdateRequest request);
    Task ReleaseAsync(Guid requestKey);
}

/// <summary>
/// One bill per booking (SQLScripts/2310): LAB B2C booking / OPD registration claim the booking's request key, record the
/// bill they create, and a retry of the same booking reuses that bill instead of creating a second one.
/// </summary>
public class BillingSubmissionService(IDbConnectionFactory connectionFactory) : IBillingSubmissionService
{
    private const CommandType Sp = CommandType.StoredProcedure;

    public async Task<BillingSubmissionClaimResult> ClaimAsync(BillingSubmissionClaimRequest request)
    {
        using var db = connectionFactory.CreateConnection();
        return await db.QuerySingleAsync<BillingSubmissionClaimResult>("dbo.usp_Api_BillingSubmission_Claim",
            new { request.RequestKey, ModuleCode = request.ModuleCode.Trim().ToUpperInvariant(), request.UserId }, commandType: Sp);
    }

    public async Task UpdateAsync(BillingSubmissionUpdateRequest request)
    {
        using var db = connectionFactory.CreateConnection();
        await db.ExecuteAsync("dbo.usp_Api_BillingSubmission_Update",
            new { request.RequestKey, request.ModuleRefId, request.BillNo, request.PatientId, request.ItemsSignature, Stage = request.Stage.Trim().ToUpperInvariant() },
            commandType: Sp);
    }

    public async Task ReleaseAsync(Guid requestKey)
    {
        using var db = connectionFactory.CreateConnection();
        await db.ExecuteAsync("dbo.usp_Api_BillingSubmission_Release", new { RequestKey = requestKey }, commandType: Sp);
    }
}
