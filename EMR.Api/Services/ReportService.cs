using System.Data;
using Dapper;
using EMR.Api.Models;
using Microsoft.Data.SqlClient;

namespace EMR.Api.Services;

public class ReportService : IReportService
{
    private readonly string _connectionString;

    public ReportService(IConfiguration configuration)
    {
        _connectionString = configuration.GetConnectionString("DefaultConnection") 
            ?? throw new InvalidOperationException("Connection string 'DefaultConnection' not found.");
    }

    public async Task<IEnumerable<DailyCollectionRegisterItem>> GetDailyCollectionRegisterAsync(int? companyId, int branchId, DateTime fromDate, DateTime toDate, bool isDetailed)
    {
        using var connection = new SqlConnection(_connectionString);
        return await connection.QueryAsync<DailyCollectionRegisterItem>(
            "usp_Api_Report_DailyCollectionRegister",
            new { CompanyId = companyId, BranchId = branchId, FromDate = fromDate, ToDate = toDate, IsDetailed = isDetailed },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<IEnumerable<PatientRegisterItem>> GetPatientRegisterAsync(int? companyId, int branchId, DateTime fromDate, DateTime toDate, bool dependentOnly)
    {
        using var connection = new SqlConnection(_connectionString);
        return await connection.QueryAsync<PatientRegisterItem>(
            "usp_Api_Report_PatientRegister",
            new { CompanyId = companyId, BranchId = branchId, FromDate = fromDate, ToDate = toDate, DependentOnly = dependentOnly },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<B2CCollectionRegisterResult> GetLabB2CCollectionRegisterAsync(int branchId, DateTime fromDate, DateTime toDate,
        int? paymentMethodId, int? collectedBy, string? search, int userId, bool isAdmin, bool isSuperAdmin)
    {
        using var connection = new SqlConnection(_connectionString);
        using var multi = await connection.QueryMultipleAsync(
            "dbo.usp_Api_LabReport_B2CCollectionRegister",
            new
            {
                BranchId = branchId,
                FromDate = fromDate.Date,
                ToDate = toDate.Date,
                PaymentMethodId = paymentMethodId is > 0 ? paymentMethodId : null,
                CollectedBy = collectedBy is > 0 ? collectedBy : null,
                Search = string.IsNullOrWhiteSpace(search) ? null : search.Trim(),
                UserId = userId,
                IsAdmin = isAdmin,
                IsSuperAdmin = isSuperAdmin
            },
            commandType: CommandType.StoredProcedure,
            commandTimeout: 60);

        return new B2CCollectionRegisterResult
        {
            Summary = await multi.ReadFirstOrDefaultAsync<B2CCollectionSummary>() ?? new B2CCollectionSummary(),
            ByMode = (await multi.ReadAsync<B2CCollectionModeRow>()).ToList(),
            ByDay = (await multi.ReadAsync<B2CCollectionDayRow>()).ToList(),
            ByCollector = (await multi.ReadAsync<B2CCollectionCollectorRow>()).ToList(),
            Receipts = (await multi.ReadAsync<B2CCollectionReceiptRow>()).ToList(),
            PaymentMethods = (await multi.ReadAsync<B2CCollectionPaymentMethod>()).ToList()
        };
    }

    public async Task<DiscountRegisterResult> GetLabDiscountRegisterAsync(int branchId, DateTime fromDate, DateTime toDate, string? billingType,
        int? approvedBy, int? enteredBy, string? search, int userId, bool isAdmin, bool isSuperAdmin)
    {
        using var connection = new SqlConnection(_connectionString);
        using var multi = await connection.QueryMultipleAsync(
            "dbo.usp_Api_LabReport_DiscountRegister",
            new
            {
                BranchId = branchId,
                FromDate = fromDate.Date,
                ToDate = toDate.Date,
                BillingType = billingType is "B2C" or "B2B" ? billingType : null,
                ApprovedBy = approvedBy is > 0 ? approvedBy : null,
                EnteredBy = enteredBy is > 0 ? enteredBy : null,
                Search = string.IsNullOrWhiteSpace(search) ? null : search.Trim(),
                UserId = userId,
                IsAdmin = isAdmin,
                IsSuperAdmin = isSuperAdmin
            },
            commandType: CommandType.StoredProcedure,
            commandTimeout: 60);

        return new DiscountRegisterResult
        {
            Summary = await multi.ReadFirstOrDefaultAsync<DiscountRegisterSummary>() ?? new DiscountRegisterSummary(),
            ByApprover = (await multi.ReadAsync<DiscountRegisterGroupRow>()).ToList(),
            ByReason = (await multi.ReadAsync<DiscountRegisterGroupRow>()).ToList(),
            ByEnteredBy = (await multi.ReadAsync<DiscountRegisterGroupRow>()).ToList(),
            ByDate = (await multi.ReadAsync<DiscountRegisterGroupRow>()).ToList(),
            Bills = (await multi.ReadAsync<DiscountRegisterBillRow>()).ToList()
        };
    }

    public async Task<LabReportResult> RunLabReportAsync(string storedProcedure, IDictionary<string, object?> parameters)
    {
        using var connection = new SqlConnection(_connectionString);
        using var multi = await connection.QueryMultipleAsync(storedProcedure, new DynamicParameters(parameters),
            commandType: CommandType.StoredProcedure, commandTimeout: 60);

        static Dictionary<string, object?> Row(dynamic r) => new((IDictionary<string, object?>)r);
        var result = new LabReportResult { Summary = (await multi.ReadAsync()).Select(Row).FirstOrDefault() ?? new() };
        result.Groups = (await multi.ReadAsync()).Select(Row).ToList();
        result.Rows = (await multi.ReadAsync()).Select(Row).ToList();
        if (!multi.IsConsumed) result.Options = (await multi.ReadAsync()).Select(Row).ToList();
        return result;
    }
}
