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
            if (!multi.IsConsumed)
            {
                detail.GroupRemarks = (await multi.ReadAsync<LabReportGroupRemarkDto>()).ToList();
            }
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
            string groupRemarksJson = JsonSerializer.Serialize(request.GroupRemarks ?? new List<LabReportGroupRemarkDto>(), jsonOptions);

            var count = await connection.ExecuteScalarAsync<int>(
                "dbo.usp_LabReporting_SaveEntry",
                new
                {
                    LabOrderId = request.LabOrderId,
                    ReportStatusId = request.ReportStatusId,
                    UserId = userId,
                    EntriesJson = entriesJson,
                    GroupRemarksJson = groupRemarksJson
                },
                commandType: CommandType.StoredProcedure
            );

            return count;
        }

        public async Task<int> UpdateSampleStatusAsync(UpdateLabSampleStatusRequestDto request, int userId)
        {
            using var connection = db.CreateConnection();
            var count = await connection.ExecuteScalarAsync<int>(
                "dbo.usp_LabReporting_UpdateSampleStatus",
                new
                {
                    LabOrderId = request.LabOrderId,
                    ProfileId = request.ProfileId,
                    InvestigationId = request.InvestigationId,
                    SampleCollectionId = request.SampleCollectionId,
                    CollectionStatusId = request.CollectionStatusId,
                    RejectionReasonId = request.RejectionReasonId,
                    RejectionReason = request.RejectionReason,
                    UserId = userId
                },
                commandType: CommandType.StoredProcedure
            );

            return count;
        }

        public async Task<List<LabOrderActivityDto>> GetActivityHistoryAsync(int labOrderId)
        {
            using var connection = db.CreateConnection();
            var list = await connection.QueryAsync<LabOrderActivityDto>(
                "dbo.usp_LabOrder_GetActivityHistory",
                new { LabOrderId = labOrderId },
                commandType: CommandType.StoredProcedure
            );
            return list.ToList();
        }

        public async Task<LabReportPrintMetaDto> GetPrintMetaAsync(int labOrderId)
        {
            using var connection = db.CreateConnection();
            using var multi = await connection.QueryMultipleAsync(
                "dbo.usp_LabReporting_GetPrintMeta",
                new { LabOrderId = labOrderId },
                commandType: CommandType.StoredProcedure
            );

            return new LabReportPrintMetaDto
            {
                Samples = (await multi.ReadAsync<LabReportSampleMetaDto>()).ToList(),
                Signatories = (await multi.ReadAsync<LabReportSignatoryDto>()).ToList(),
                ProcessingLab = await multi.ReadFirstOrDefaultAsync<LabReportProcessingLabDto>(),
                Client = await multi.ReadFirstOrDefaultAsync<LabReportClientDto>()
            };
        }
    }
}
