using System;
using System.Collections.Generic;
using System.Data;
using System.Linq;
using System.Threading.Tasks;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services
{
    public class SampleCollectionService(IDbConnectionFactory db) : ISampleCollectionService
    {
        public async Task<SampleCollectionHeaderListResult> GetHeaderListAsync(
            int branchId,
            DateTime? fromDate,
            DateTime? toDate,
            string? dateFilterType,
            string? statusFilter,
            string? search)
        {
            using var connection = db.CreateConnection();
            using var multi = await connection.QueryMultipleAsync(
                "dbo.usp_SampleCollection_GetHeaderList",
                new
                {
                    BranchId = branchId,
                    FromDate = fromDate,
                    ToDate = toDate,
                    DateFilterType = string.IsNullOrWhiteSpace(dateFilterType) ? "BookingDate" : dateFilterType,
                    StatusFilter = string.IsNullOrWhiteSpace(statusFilter) ? "All" : statusFilter,
                    Search = search
                },
                commandType: CommandType.StoredProcedure
            );

            var stats = await multi.ReadFirstOrDefaultAsync<SampleCollectionStatsDto>() ?? new SampleCollectionStatsDto();
            var headers = (await multi.ReadAsync<SampleCollectionHeaderDto>()).ToList();

            return new SampleCollectionHeaderListResult
            {
                Stats = stats,
                Headers = headers
            };
        }

        public async Task<SampleCollectionOrderDetailDto?> GetDetailAsync(int labOrderId)
        {
            using var connection = db.CreateConnection();
            using var multi = await connection.QueryMultipleAsync(
                "dbo.usp_SampleCollection_GetDetail",
                new { LabOrderId = labOrderId },
                commandType: CommandType.StoredProcedure
            );

            var detail = await multi.ReadFirstOrDefaultAsync<SampleCollectionOrderDetailDto>();
            if (detail == null) return null;

            detail.Items = (await multi.ReadAsync<SampleCollectionItemDto>()).ToList();
            return detail;
        }

        public async Task<bool> UpdateStatusAsync(UpdateSampleCollectionStatusRequestDto request, int userId)
        {
            using var connection = db.CreateConnection();
            int rows = await connection.ExecuteScalarAsync<int>(
                "dbo.usp_SampleCollection_UpdateStatus",
                new
                {
                    SampleCollectionId = request.SampleCollectionId,
                    CollectionstatusID = request.CollectionstatusID,
                    SampleCollectionDate = request.SampleCollectionDate,
                    SampleCollectionTime = request.SampleCollectionTime,
                    UserId = userId
                },
                commandType: CommandType.StoredProcedure
            );
            return rows > 0;
        }

        public async Task<int> UpdateProfileStatusAsync(UpdateProfileSampleCollectionStatusRequestDto request, int userId)
        {
            using var connection = db.CreateConnection();
            return await connection.ExecuteScalarAsync<int>(
                "dbo.usp_SampleCollection_UpdateProfileStatus",
                new
                {
                    LabOrderId = request.LabOrderId,
                    ProfileId = request.ProfileId,
                    ProfileName = request.ProfileName,
                    CollectionstatusID = request.CollectionstatusID,
                    SampleCollectionDate = request.SampleCollectionDate,
                    SampleCollectionTime = request.SampleCollectionTime,
                    UserId = userId
                },
                commandType: CommandType.StoredProcedure
            );
        }

        public async Task<int> CollectAllAsync(int labOrderId, int userId)
        {
            using var connection = db.CreateConnection();
            return await connection.ExecuteScalarAsync<int>(
                "dbo.usp_SampleCollection_CollectAll",
                new
                {
                    LabOrderId = labOrderId,
                    UserId = userId
                },
                commandType: CommandType.StoredProcedure
            );
        }

        public async Task<int> AutoCollectIfNotMandatoryAsync(int labOrderId, int userId)
        {
            using var connection = db.CreateConnection();
            return await connection.ExecuteScalarAsync<int>(
                "dbo.usp_SampleCollection_AutoCollectIfNoMandatory",
                new
                {
                    LabOrderId = labOrderId,
                    UserId = userId
                },
                commandType: CommandType.StoredProcedure
            );
        }

        public async Task<List<SampleCollectionStatusMasterDto>> GetStatusesAsync()
        {
            using var connection = db.CreateConnection();
            var sql = @"
                SELECT StatusID, StatusCode, StatusName, BadgeClass, DisplayOrder, IsActive
                FROM dbo.SampleCollectionStatus
                WHERE IsActive = 1
                ORDER BY DisplayOrder ASC;";

            var result = await connection.QueryAsync<SampleCollectionStatusMasterDto>(sql);
            return result.ToList();
        }
    }
}
