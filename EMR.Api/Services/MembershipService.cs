using System.Data;
using System.Text.Json;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class MembershipService(IDbConnectionFactory db) : IMembershipService
{
    private static readonly JsonSerializerOptions CamelCase = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    // ── Membership Plan master ───────────────────────────────────────────────

    public async Task<IEnumerable<MembershipPlanListItem>> GetPlansAsync(int companyId, bool? status, string? search)
    {
        using var conn = db.CreateConnection();
        return await conn.QueryAsync<MembershipPlanListItem>(
            "dbo.usp_Api_MembershipPlan_GetList",
            new { CompanyId = companyId, Status = status, Search = string.IsNullOrWhiteSpace(search) ? null : search.Trim() },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<MembershipPlanDetail?> GetPlanAsync(int planId, int companyId)
    {
        using var conn = db.CreateConnection();
        using var multi = await conn.QueryMultipleAsync(
            "dbo.usp_Api_MembershipPlan_GetById",
            new { PlanId = planId, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);

        var plan = await multi.ReadFirstOrDefaultAsync<MembershipPlanDetail>();
        var benefits = (await multi.ReadAsync<MembershipPlanBenefit>()).ToList();
        if (plan != null) plan.Benefits = benefits;
        return plan;
    }

    public async Task<MembershipBenefitScopes> GetBenefitScopesAsync(int companyId)
    {
        using var conn = db.CreateConnection();
        using var multi = await conn.QueryMultipleAsync(
            "dbo.usp_Api_MembershipPlan_GetBenefitScopes",
            new { CompanyId = companyId },
            commandType: CommandType.StoredProcedure);

        return new MembershipBenefitScopes
        {
            Departments = (await multi.ReadAsync<MembershipScopeOption>()).ToList(),
            Categories = (await multi.ReadAsync<MembershipScopeOption>()).ToList()
        };
    }

    public async Task<int> SavePlanAsync(MembershipPlanSaveRequest request)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@PlanId", request.PlanId);
        parameters.Add("@CompanyId", request.CompanyId);
        parameters.Add("@PlanName", request.PlanName);
        parameters.Add("@PlanType", request.PlanType);
        parameters.Add("@CardFee", request.CardFee);
        parameters.Add("@GstPercent", request.GstPercent);
        parameters.Add("@ValidityDays", request.ValidityDays);
        parameters.Add("@MaxMembers", request.MaxMembers);
        parameters.Add("@MinAge", request.MinAge);
        parameters.Add("@WelcomePoints", request.WelcomePoints);
        parameters.Add("@PointsEarnPercent", request.PointsEarnPercent);
        parameters.Add("@PointValue", request.PointValue);
        parameters.Add("@MaxRedeemPercent", request.MaxRedeemPercent);
        parameters.Add("@PointsExpiryDays", request.PointsExpiryDays);
        parameters.Add("@FreeHomeCollection", request.FreeHomeCollection);
        parameters.Add("@Terms", request.Terms);
        parameters.Add("@IsActive", request.IsActive);
        parameters.Add("@BenefitsJson", JsonSerializer.Serialize(
            request.Benefits.Select(b => new { b.Scope, b.ScopeRefId, b.DiscountFlag, b.DiscountValue, b.IsExcluded, b.FreeQuantity }), CamelCase));
        parameters.Add("@UserId", request.UserId);

        return await conn.QuerySingleAsync<int>(
            "dbo.usp_Api_MembershipPlan_Save", parameters, commandType: CommandType.StoredProcedure);
    }

    public async Task<bool> DeletePlanAsync(int planId, int companyId, int userId)
    {
        using var conn = db.CreateConnection();
        return await conn.QuerySingleAsync<bool>(
            "dbo.usp_Api_MembershipPlan_Delete",
            new { PlanId = planId, CompanyId = companyId, UserId = userId },
            commandType: CommandType.StoredProcedure);
    }

    // ── Membership Cards ─────────────────────────────────────────────────────

    public async Task<IEnumerable<MembershipPatientSearchItem>> SearchPatientsAsync(int companyId, string search)
    {
        using var conn = db.CreateConnection();
        return await conn.QueryAsync<MembershipPatientSearchItem>(
            "dbo.usp_Api_MembershipCard_PatientSearch",
            new { CompanyId = companyId, Search = search },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<MembershipCardIssueResult> IssueCardAsync(MembershipCardIssueRequest request)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@CompanyId", request.CompanyId);
        parameters.Add("@BranchId", request.BranchId);
        parameters.Add("@PlanId", request.PlanId);
        parameters.Add("@PrimaryPatientId", request.PrimaryPatientId);
        parameters.Add("@ValidFrom", request.ValidFrom?.Date, DbType.Date);
        parameters.Add("@MembersJson", JsonSerializer.Serialize(
            request.Members.Where(m => m.PatientId > 0).Select(m => new { m.PatientId, m.Relation }), CamelCase));
        parameters.Add("@PaymentMethodId", request.PaymentMethodId);
        parameters.Add("@TransactionRef", request.TransactionRef);
        parameters.Add("@Remarks", request.Remarks);
        parameters.Add("@UserId", request.UserId);

        return await conn.QuerySingleAsync<MembershipCardIssueResult>(
            "dbo.usp_Api_MembershipCard_Issue", parameters, commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<MembershipCardListItem>> GetCardsAsync(int companyId, int? branchId, int? planId, string? status, string? search, DateTime? fromDate, DateTime? toDate)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@CompanyId", companyId);
        parameters.Add("@BranchId", branchId);
        parameters.Add("@PlanId", planId);
        parameters.Add("@Status", string.IsNullOrWhiteSpace(status) ? null : status.Trim());
        parameters.Add("@Search", string.IsNullOrWhiteSpace(search) ? null : search.Trim());
        parameters.Add("@FromDate", fromDate?.Date, DbType.Date);
        parameters.Add("@ToDate", toDate?.Date, DbType.Date);

        return await conn.QueryAsync<MembershipCardListItem>(
            "dbo.usp_Api_MembershipCard_GetList", parameters, commandType: CommandType.StoredProcedure);
    }

    public async Task<MembershipCardDetail?> GetCardAsync(int cardId, int companyId)
    {
        using var conn = db.CreateConnection();
        using var multi = await conn.QueryMultipleAsync(
            "dbo.usp_Api_MembershipCard_GetById",
            new { CardId = cardId, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);

        var card = await multi.ReadFirstOrDefaultAsync<MembershipCardDetail>();
        var members = (await multi.ReadAsync<MembershipCardMember>()).ToList();
        var ledger = (await multi.ReadAsync<MembershipLedgerRow>()).ToList();
        var accounting = (await multi.ReadAsync<MembershipAccountingRow>()).ToList();
        if (card != null)
        {
            card.Members = members;
            card.Ledger = ledger;
            card.Accounting = accounting;
        }
        return card;
    }

    public async Task AddMemberAsync(int cardId, MembershipCardAddMemberRequest request)
    {
        using var conn = db.CreateConnection();
        await conn.ExecuteAsync(
            "dbo.usp_Api_MembershipCard_AddMember",
            new { CardId = cardId, request.CompanyId, request.BranchId, request.PatientId, request.Relation, request.UserId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task SetCardStatusAsync(int cardId, MembershipCardStatusRequest request)
    {
        using var conn = db.CreateConnection();
        await conn.ExecuteAsync(
            "dbo.usp_Api_MembershipCard_SetStatus",
            new { CardId = cardId, request.CompanyId, request.BranchId, request.Status, request.Reason, request.UserId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task MarkPrintedAsync(int cardId, int companyId, int userId)
    {
        using var conn = db.CreateConnection();
        await conn.ExecuteAsync(
            "dbo.usp_Api_MembershipCard_MarkPrinted",
            new { CardId = cardId, CompanyId = companyId, UserId = userId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task MarkSentAsync(int cardId, int companyId, string channel)
    {
        using var conn = db.CreateConnection();
        await conn.ExecuteAsync(
            "dbo.usp_Api_MembershipCard_MarkSent",
            new { CardId = cardId, CompanyId = companyId, Channel = channel },
            commandType: CommandType.StoredProcedure);
    }
}
