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

    public async Task<IEnumerable<DailyCollectionRegisterItem>> GetDailyCollectionRegisterAsync(int branchId, DateTime fromDate, DateTime toDate, bool isDetailed)
    {
        using var connection = new SqlConnection(_connectionString);
        return await connection.QueryAsync<DailyCollectionRegisterItem>(
            "usp_Api_Report_DailyCollectionRegister",
            new { BranchId = branchId, FromDate = fromDate, ToDate = toDate, IsDetailed = isDetailed },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<IEnumerable<PatientRegisterItem>> GetPatientRegisterAsync(int branchId, DateTime fromDate, DateTime toDate, bool dependentOnly)
    {
        using var connection = new SqlConnection(_connectionString);
        return await connection.QueryAsync<PatientRegisterItem>(
            "usp_Api_Report_PatientRegister",
            new { BranchId = branchId, FromDate = fromDate, ToDate = toDate, DependentOnly = dependentOnly },
            commandType: CommandType.StoredProcedure
        );
    }
}
