using System;
using System.Collections.Generic;
using System.Data;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services
{
    public class LabReportingService(IDbConnectionFactory db) : ILabReportingService
    {
        public async Task<LabReportingHeaderListResult> GetHeaderListAsync(
            int branchId,
            DateTime? fromDate,
            DateTime? toDate,
            string? dateFilterType,
            string? statusFilter,
            string? search,
            int? departmentId = null,
            int? categoryId = null,
            int? subCategoryId = null)
        {
            using var connection = db.CreateConnection();
            using var multi = await connection.QueryMultipleAsync(
                "dbo.usp_LabReporting_GetHeaderList",
                new
                {
                    BranchId = branchId,
                    FromDate = fromDate,
                    ToDate = toDate,
                    DateFilterType = string.IsNullOrWhiteSpace(dateFilterType) ? "BookingDate" : dateFilterType,
                    StatusFilter = string.IsNullOrWhiteSpace(statusFilter) ? "All" : statusFilter,
                    Search = search,
                    DepartmentId = departmentId,
                    CategoryId = categoryId,
                    SubCategoryId = subCategoryId
                },
                commandType: CommandType.StoredProcedure
            );

            var stats = await multi.ReadFirstOrDefaultAsync<LabReportingStatsDto>() ?? new LabReportingStatsDto();
            var headers = (await multi.ReadAsync<LabReportingHeaderDto>()).ToList();

            return new LabReportingHeaderListResult
            {
                Stats = stats,
                Headers = headers
            };
        }

        public async Task<LabReportingOrderDetailDto?> GetDetailAsync(int labOrderId)
        {
            using var connection = db.CreateConnection();
            using var multi = await connection.QueryMultipleAsync(
                "dbo.usp_LabReporting_GetDetail",
                new { LabOrderId = labOrderId },
                commandType: CommandType.StoredProcedure
            );

            var detail = await multi.ReadFirstOrDefaultAsync<LabReportingOrderDetailDto>();
            if (detail == null) return null;

            detail.Items = (await multi.ReadAsync<LabReportingItemDto>()).ToList();
            return detail;
        }

        public async Task<List<LabReportStatusMasterDto>> GetStatusesAsync()
        {
            using var connection = db.CreateConnection();
            var list = await connection.QueryAsync<LabReportStatusMasterDto>(
                "dbo.usp_LabReporting_GetStatuses",
                commandType: CommandType.StoredProcedure
            );
            return list.ToList();
        }

        public async Task<int> SaveEntryAsync(SaveLabReportingRequestDto request, int userId)
        {
            using var connection = db.CreateConnection();
            var jsonOptions = new JsonSerializerOptions
            {
                PropertyNamingPolicy = JsonNamingPolicy.CamelCase
            };
            string entriesJson = JsonSerializer.Serialize(request.Entries ?? new List<LabReportingItemValueDto>(), jsonOptions);

            var count = await connection.ExecuteScalarAsync<int>(
                "dbo.usp_LabReporting_SaveEntry",
                new
                {
                    LabOrderId = request.LabOrderId,
                    ReportStatusId = request.ReportStatusId,
                    UserId = userId,
                    EntriesJson = entriesJson
                },
                commandType: CommandType.StoredProcedure
            );

            return count;
        }
    }
}
