using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class DoctorCommissionService(IDbConnectionFactory db) : IDoctorCommissionService
{
    // 1. Visit Process Config
    public async Task<IEnumerable<DoctorVisitProcessConfigDto>> GetProcessConfigsAsync(
        int? branchId = null, int? specialityId = null, int? doctorId = null,
        string? visitType = null, bool? isActive = null, string? search = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DoctorVisitProcessConfigDto>(
            "dbo.usp_Api_DoctorVisitProcessConfig_GetList",
            new { BranchId = branchId, SpecialityId = specialityId, DoctorId = doctorId, VisitType = visitType, IsActive = isActive, Search = search, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<DoctorVisitProcessConfigDto?> GetProcessConfigByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<DoctorVisitProcessConfigDto>(
            "dbo.usp_Api_DoctorVisitProcessConfig_GetById",
            new { ProcessConfigId = id },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> SaveProcessConfigAsync(DoctorVisitProcessConfigSaveRequest request)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int>(
            "dbo.usp_Api_DoctorVisitProcessConfig_Save",
            new
            {
                request.ProcessConfigId,
                request.CompanyId,
                request.BranchId,
                request.SpecialityId,
                request.DoctorId,
                request.VisitType,
                request.PaymentTiming,
                request.VitalsRequired,
                request.DiagnosisRequired,
                request.Icd10Required,
                request.ProcedureAllowed,
                request.BillingRequired,
                request.PaymentBeforeClosure,
                request.EffectiveFrom,
                request.EffectiveTo,
                request.IsActive,
                request.UserId
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<bool> DeleteProcessConfigAsync(int id)
    {
        using var con = db.CreateConnection();
        var rows = await con.ExecuteScalarAsync<int>(
            "dbo.usp_Api_DoctorVisitProcessConfig_Delete",
            new { ProcessConfigId = id },
            commandType: CommandType.StoredProcedure);
        return rows > 0;
    }

    // 2. Doctor Commission Config
    public async Task<IEnumerable<DoctorCommissionConfigDto>> GetCommissionConfigsAsync(
        int? branchId = null, int? doctorId = null, int? specialityId = null,
        string? revenueType = null, bool? isActive = null, string? search = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DoctorCommissionConfigDto>(
            "dbo.usp_Api_DoctorCommissionConfig_GetList",
            new { BranchId = branchId, DoctorId = doctorId, SpecialityId = specialityId, RevenueType = revenueType, IsActive = isActive, Search = search, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<DoctorCommissionConfigDto?> GetCommissionConfigByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<DoctorCommissionConfigDto>(
            "dbo.usp_Api_DoctorCommissionConfig_GetById",
            new { CommissionConfigId = id },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> SaveCommissionConfigAsync(DoctorCommissionConfigSaveRequest request)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int>(
            "dbo.usp_Api_DoctorCommissionConfig_Save",
            new
            {
                request.CommissionConfigId,
                request.CompanyId,
                request.BranchId,
                request.DoctorId,
                request.SpecialityId,
                request.RevenueType,
                request.CalculationType,
                request.CommissionBasis,
                request.DoctorShare,
                request.ProcedureId,
                request.ServiceId,
                request.CorporateId,
                request.InsuranceTPAId,
                request.ApprovalRequired,
                request.EffectiveFrom,
                request.EffectiveTo,
                request.IsActive,
                request.UserId
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<bool> DeleteCommissionConfigAsync(int id)
    {
        using var con = db.CreateConnection();
        var rows = await con.ExecuteScalarAsync<int>(
            "dbo.usp_Api_DoctorCommissionConfig_Delete",
            new { CommissionConfigId = id },
            commandType: CommandType.StoredProcedure);
        return rows > 0;
    }

    // 3. Doctor Disbursal Workbench
    public async Task<IEnumerable<DoctorDisbursalDto>> GetDisbursalsAsync(
        int? branchId = null, int? doctorId = null, string? settlementPeriod = null,
        string? approvalStatus = null, string? paymentStatus = null,
        DateTime? fromDate = null, DateTime? toDate = null, string? search = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DoctorDisbursalDto>(
            "dbo.usp_Api_DoctorDisbursal_GetList",
            new { BranchId = branchId, DoctorId = doctorId, SettlementPeriod = settlementPeriod, ApprovalStatus = approvalStatus, PaymentStatus = paymentStatus, FromDate = fromDate, ToDate = toDate, Search = search, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<DoctorDisbursalDetailDto?> GetDisbursalByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        using var multi = await con.QueryMultipleAsync(
            "dbo.usp_Api_DoctorDisbursal_GetById",
            new { DisbursalId = id },
            commandType: CommandType.StoredProcedure);

        var item = await multi.ReadFirstOrDefaultAsync<DoctorDisbursalDetailDto>();
        if (item is not null)
        {
            var adjustments = await multi.ReadAsync<DoctorBillingAdjustmentDto>();
            item.Adjustments = adjustments.AsList();
        }
        return item;
    }

    public async Task<int> CalculateDisbursalsAsync(DoctorDisbursalCalculateRequest request)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int>(
            "dbo.usp_Api_DoctorDisbursal_CalculateForVisits",
            new
            {
                request.BranchId,
                request.DoctorId,
                request.FromDate,
                request.ToDate,
                request.SettlementPeriod,
                request.UserId,
                request.CompanyId
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<bool> UpdateAdjustmentAsync(DoctorDisbursalAdjustmentRequest request)
    {
        using var con = db.CreateConnection();
        var rows = await con.ExecuteScalarAsync<int>(
            "dbo.usp_Api_DoctorDisbursal_UpdateAdjustment",
            new
            {
                request.DisbursalId,
                request.AdjustmentType,
                request.AdjustmentAmount,
                request.Reason,
                request.UserId
            },
            commandType: CommandType.StoredProcedure);
        return rows > 0;
    }

    public async Task<bool> UpdateStatusAsync(DoctorDisbursalStatusRequest request)
    {
        using var con = db.CreateConnection();
        var rows = await con.ExecuteScalarAsync<int>(
            "dbo.usp_Api_DoctorDisbursal_UpdateStatus",
            new
            {
                request.DisbursalId,
                request.ApprovalStatus,
                request.DisbursalNotes,
                request.UserId
            },
            commandType: CommandType.StoredProcedure);
        return rows > 0;
    }

    public async Task<bool> BulkApproveAsync(DoctorDisbursalBulkApproveRequest request)
    {
        using var con = db.CreateConnection();
        var rows = await con.ExecuteScalarAsync<int>(
            "dbo.usp_Api_DoctorDisbursal_BulkApprove",
            new { request.DisbursalIds, request.UserId },
            commandType: CommandType.StoredProcedure);
        return rows > 0;
    }

    public async Task<bool> ProcessPayoutAsync(DoctorDisbursalPayoutRequest request)
    {
        using var con = db.CreateConnection();
        var rows = await con.ExecuteScalarAsync<int>(
            "dbo.usp_Api_DoctorDisbursal_ProcessPayout",
            new
            {
                request.DisbursalId,
                request.PaymentMethod,
                request.PaymentReference,
                request.PaidDate,
                request.DisbursalNotes,
                request.UserId
            },
            commandType: CommandType.StoredProcedure);
        return rows > 0;
    }

    // 4. Financial Reports (RPT-01 to RPT-08)
    public async Task<IEnumerable<VisitPaymentStatusReportItemDto>> GetVisitPaymentStatusReportAsync(
        int? branchId = null, int? doctorId = null, DateTime? fromDate = null, DateTime? toDate = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<VisitPaymentStatusReportItemDto>(
            "dbo.usp_Api_Report_VisitPaymentStatus",
            new { BranchId = branchId, DoctorId = doctorId, FromDate = fromDate, ToDate = toDate, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<OutstandingByVisitReportItemDto>> GetOutstandingByVisitReportAsync(
        int? branchId = null, int? doctorId = null, DateTime? fromDate = null, DateTime? toDate = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<OutstandingByVisitReportItemDto>(
            "dbo.usp_Api_Report_OutstandingByVisit",
            new { BranchId = branchId, DoctorId = doctorId, FromDate = fromDate, ToDate = toDate, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<DoctorCommissionReportItemDto>> GetDoctorCommissionReportAsync(
        int? branchId = null, int? doctorId = null, string? settlementPeriod = null, DateTime? fromDate = null, DateTime? toDate = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DoctorCommissionReportItemDto>(
            "dbo.usp_Api_Report_DoctorCommission",
            new { BranchId = branchId, DoctorId = doctorId, SettlementPeriod = settlementPeriod, FromDate = fromDate, ToDate = toDate, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<DoctorDisbursalRegisterItemDto>> GetDoctorDisbursalRegisterAsync(
        int? branchId = null, int? doctorId = null, string? settlementPeriod = null, string? paymentStatus = null, DateTime? fromDate = null, DateTime? toDate = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DoctorDisbursalRegisterItemDto>(
            "dbo.usp_Api_Report_DoctorDisbursalRegister",
            new { BranchId = branchId, DoctorId = doctorId, SettlementPeriod = settlementPeriod, PaymentStatus = paymentStatus, FromDate = fromDate, ToDate = toDate, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<PaymentTransactionReportItemDto>> GetPaymentTransactionsReportAsync(
        int? branchId = null, int? paymentMethodId = null, DateTime? fromDate = null, DateTime? toDate = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<PaymentTransactionReportItemDto>(
            "dbo.usp_Api_Report_PaymentTransactions",
            new { BranchId = branchId, PaymentMethodId = paymentMethodId, FromDate = fromDate, ToDate = toDate, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<BillingAdjustmentReportItemDto>> GetBillingAdjustmentsReportAsync(
        int? branchId = null, int? doctorId = null, DateTime? fromDate = null, DateTime? toDate = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<BillingAdjustmentReportItemDto>(
            "dbo.usp_Api_Report_BillingAdjustments",
            new { BranchId = branchId, DoctorId = doctorId, FromDate = fromDate, ToDate = toDate, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<RefundReversalReportItemDto>> GetRefundReversalsReportAsync(
        int? branchId = null, DateTime? fromDate = null, DateTime? toDate = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<RefundReversalReportItemDto>(
            "dbo.usp_Api_Report_RefundReversals",
            new { BranchId = branchId, FromDate = fromDate, ToDate = toDate, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<DoctorSettlementSummaryItemDto>> GetDoctorSettlementSummaryAsync(
        int? branchId = null, int? doctorId = null, string? settlementPeriod = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DoctorSettlementSummaryItemDto>(
            "dbo.usp_Api_Report_DoctorSettlementSummary",
            new { BranchId = branchId, DoctorId = doctorId, SettlementPeriod = settlementPeriod, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }
}
