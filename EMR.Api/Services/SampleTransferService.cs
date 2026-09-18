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
    public class SampleTransferService(IDbConnectionFactory db) : ISampleTransferService
    {
        public async Task<SampleTransferHeaderListResult> GetEligibleSamplesAsync(
            int sourceBranchId,
            DateTime? fromDate,
            DateTime? toDate,
            string? dateFilterType = "CollectionDate",
            string? transferStatusFilter = "Ready",
            string? search = null,
            int? departmentId = null,
            int? categoryId = null,
            int? subCategoryId = null)
        {
            using var connection = db.CreateConnection();
            using var multi = await connection.QueryMultipleAsync(
                "dbo.usp_SampleTransfer_GetEligibleSamples",
                new
                {
                    SourceBranchId = sourceBranchId,
                    FromDate = fromDate,
                    ToDate = toDate,
                    DateFilterType = string.IsNullOrWhiteSpace(dateFilterType) ? "CollectionDate" : dateFilterType,
                    TransferStatusFilter = string.IsNullOrWhiteSpace(transferStatusFilter) ? "Ready" : transferStatusFilter,
                    Search = search,
                    DepartmentId = departmentId,
                    CategoryId = categoryId,
                    SubCategoryId = subCategoryId
                },
                commandType: CommandType.StoredProcedure
            );

            var stats = await multi.ReadFirstOrDefaultAsync<SampleTransferStatsDto>() ?? new SampleTransferStatsDto();
            var items = (await multi.ReadAsync<SampleTransferEligibleItemDto>()).ToList();

            return new SampleTransferHeaderListResult
            {
                Stats = stats,
                Items = items
            };
        }

        public async Task<ExecuteSampleTransferResponseDto> ExecuteTransferAsync(
            ExecuteSampleTransferRequestDto request,
            int userId)
        {
            if (request.SampleCollectionIds == null || !request.SampleCollectionIds.Any())
            {
                return new ExecuteSampleTransferResponseDto
                {
                    IsSuccess = false,
                    Message = "No sample IDs provided for transfer."
                };
            }

            if (request.SourceBranchId <= 0 || request.TargetBranchId <= 0)
            {
                return new ExecuteSampleTransferResponseDto
                {
                    IsSuccess = false,
                    Message = "Valid source and target branches are required."
                };
            }

            if (request.SourceBranchId == request.TargetBranchId)
            {
                return new ExecuteSampleTransferResponseDto
                {
                    IsSuccess = false,
                    Message = "Source and target branch cannot be the same."
                };
            }

            string idsCsv = string.Join(",", request.SampleCollectionIds);

            using var connection = db.CreateConnection();
            var result = await connection.QueryFirstOrDefaultAsync<dynamic>(
                "dbo.usp_SampleTransfer_ExecuteTransfer",
                new
                {
                    SampleCollectionIds = idsCsv,
                    SourceBranchId = request.SourceBranchId,
                    TargetBranchId = request.TargetBranchId,
                    TransferredBy = userId,
                    TransferRemarks = request.TransferRemarks
                },
                commandType: CommandType.StoredProcedure
            );

            if (result != null)
            {
                return new ExecuteSampleTransferResponseDto
                {
                    IsSuccess = (int)result.IsSuccess == 1,
                    TransferredCount = (int)result.TransferredCount,
                    Message = (string)result.Message
                };
            }

            return new ExecuteSampleTransferResponseDto
            {
                IsSuccess = false,
                Message = "Failed to execute transfer."
            };
        }

        public async Task<List<SampleTransferAuditDto>> GetTransferHistoryAsync(
            int branchId,
            string? mode = "Outgoing",
            DateTime? fromDate = null,
            DateTime? toDate = null,
            string? search = null)
        {
            using var connection = db.CreateConnection();
            var list = await connection.QueryAsync<SampleTransferAuditDto>(
                "dbo.usp_SampleTransfer_GetHistory",
                new
                {
                    BranchId = branchId,
                    Mode = string.IsNullOrWhiteSpace(mode) ? "Outgoing" : mode,
                    FromDate = fromDate,
                    ToDate = toDate,
                    Search = search
                },
                commandType: CommandType.StoredProcedure
            );

            return list.ToList();
        }

        public async Task<SampleTransferReceivableListResult> GetReceivableSamplesAsync(
            int targetBranchId,
            DateTime? fromDate,
            DateTime? toDate,
            string? dateFilterType = "ReceivedDate",
            string? receiveStatusFilter = "Pending",
            string? search = null,
            int? departmentId = null,
            int? categoryId = null,
            int? subCategoryId = null)
        {
            using var connection = db.CreateConnection();
            using var multi = await connection.QueryMultipleAsync(
                "dbo.usp_SampleTransfer_GetReceivableSamples",
                new
                {
                    TargetBranchId = targetBranchId,
                    FromDate = fromDate,
                    ToDate = toDate,
                    DateFilterType = string.IsNullOrWhiteSpace(dateFilterType) ? "ReceivedDate" : dateFilterType,
                    ReceiveStatusFilter = string.IsNullOrWhiteSpace(receiveStatusFilter) ? "Pending" : receiveStatusFilter,
                    Search = search,
                    DepartmentId = departmentId,
                    CategoryId = categoryId,
                    SubCategoryId = subCategoryId
                },
                commandType: CommandType.StoredProcedure
            );

            var stats = await multi.ReadFirstOrDefaultAsync<SampleTransferReceiveStatsDto>() ?? new SampleTransferReceiveStatsDto();
            var items = (await multi.ReadAsync<SampleTransferEligibleItemDto>()).ToList();

            return new SampleTransferReceivableListResult
            {
                Stats = stats,
                Items = items
            };
        }

        public async Task<ReceiveSampleTransferResponseDto> ReceiveSamplesAsync(
            ReceiveSampleTransferRequestDto request,
            int userId)
        {
            if (request.SampleCollectionIds == null || !request.SampleCollectionIds.Any())
            {
                return new ReceiveSampleTransferResponseDto
                {
                    IsSuccess = false,
                    Message = "No sample IDs provided for receiving."
                };
            }

            if (request.TargetBranchId <= 0)
            {
                return new ReceiveSampleTransferResponseDto
                {
                    IsSuccess = false,
                    Message = "Valid target branch is required."
                };
            }

            string idsCsv = string.Join(",", request.SampleCollectionIds);

            using var connection = db.CreateConnection();
            var result = await connection.QueryFirstOrDefaultAsync<dynamic>(
                "dbo.usp_SampleTransfer_ReceiveSamples",
                new
                {
                    SampleCollectionIds = idsCsv,
                    TargetBranchId = request.TargetBranchId,
                    ReceivedBy = userId,
                    ReceiveRemarks = request.ReceiveRemarks
                },
                commandType: CommandType.StoredProcedure
            );

            if (result != null)
            {
                return new ReceiveSampleTransferResponseDto
                {
                    IsSuccess = (int)result.IsSuccess == 1,
                    ReceivedCount = (int)result.ReceivedCount,
                    Message = (string)result.Message
                };
            }

            return new ReceiveSampleTransferResponseDto
            {
                IsSuccess = false,
                Message = "Failed to execute receive operation."
            };
        }

        public async Task<List<TargetBranchOptionDto>> GetTargetBranchesAsync(int currentBranchId)
        {
            using var connection = db.CreateConnection();
            var branches = await connection.QueryAsync<TargetBranchOptionDto>(
                "dbo.usp_SampleTransfer_GetTargetBranches",
                new { CurrentBranchId = currentBranchId },
                commandType: CommandType.StoredProcedure
            );

            return branches.ToList();
        }

        public async Task<List<SampleTransferEligibleItemDto>> GetWorksheetDataAsync(string sampleCollectionIds)
        {
            if (string.IsNullOrWhiteSpace(sampleCollectionIds))
                return new List<SampleTransferEligibleItemDto>();

            using var connection = db.CreateConnection();
            var items = await connection.QueryAsync<SampleTransferEligibleItemDto>(
                "dbo.usp_SampleTransfer_GetWorksheetData",
                new { SampleCollectionIds = sampleCollectionIds },
                commandType: CommandType.StoredProcedure
            );

            return items.ToList();
        }
    }
}
