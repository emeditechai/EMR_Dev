using System;
using System.Data;
using System.Linq;
using System.Threading.Tasks;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;
using Microsoft.Data.SqlClient;

namespace EMR.Api.Services
{
    public class LabOrderService(IDbConnectionFactory db) : ILabOrderService
    {
        public async Task<LabOrderResponse> CreateOrderAsync(LabOrderRequest request, int userId)
        {
            using var connection = db.CreateConnection();
            
            decimal totalAmount = request.Items.Sum(x => x.Price);

            var itemsTable = new DataTable();
            itemsTable.Columns.Add("InvestigationId", typeof(int));
            itemsTable.Columns.Add("Type", typeof(string));
            itemsTable.Columns.Add("Price", typeof(decimal));
            itemsTable.Columns.Add("IsUrgent", typeof(bool));

            foreach (var item in request.Items)
            {
                var itemType = string.IsNullOrWhiteSpace(item.Type) ? "I" : item.Type.Trim().ToUpperInvariant();
                itemsTable.Rows.Add(item.InvestigationId, itemType, item.Price, item.IsUrgent);
            }

            var p = new DynamicParameters();
            p.Add("@PatientId", request.PatientId);
            p.Add("@BranchId", request.BranchId);
            p.Add("@CreatedBy", userId);
            p.Add("@TotalAmount", totalAmount);
            p.Add("@Items", itemsTable.AsTableValuedParameter("dbo.udt_LabOrderItem"));
            p.Add("@CollectionType", string.IsNullOrWhiteSpace(request.CollectionType) ? "Lab" : request.CollectionType);
            p.Add("@PhlebotomistId", request.PhlebotomistId);
            p.Add("@BookingDate", request.BookingDate);
            p.Add("@LabOrderId", dbType: DbType.Int32, direction: ParameterDirection.Output);
            p.Add("@BillNo", dbType: DbType.String, size: 50, direction: ParameterDirection.Output);

            await connection.ExecuteAsync("dbo.usp_CreateLabOrder", p, commandType: CommandType.StoredProcedure);

            int labOrderId = p.Get<int>("@LabOrderId");
            string billNo = p.Get<string>("@BillNo");

            return new LabOrderResponse
            {
                LabOrderId = labOrderId,
                BillNo = billNo
            };
        }

        private async Task<string> GetNextSequenceAsync(IDbConnection connection, IDbTransaction transaction, string prefix)
        {
            var p = new DynamicParameters();
            p.Add("@Prefix", prefix);
            p.Add("@NextSequence", dbType: DbType.Int32, direction: ParameterDirection.Output);

            await connection.ExecuteAsync("usp_GetNextSequence", p, transaction, commandType: CommandType.StoredProcedure);

            int seq = p.Get<int>("@NextSequence");
            return $"{prefix}{seq:D4}";
        }

        public async Task<IEnumerable<AvailableInvestigationDto>> GetAvailableInvestigationsAsync(int branchId, int? departmentId, int? categoryId, int? subCategoryId, string? gender = null, int? ageInYears = null)
        {
            using var connection = db.CreateConnection();
            return await connection.QueryAsync<AvailableInvestigationDto>(
                "dbo.usp_GetAvailableInvestigations",
                new { BranchId = branchId, DepartmentId = departmentId, CategoryId = categoryId, SubCategoryId = subCategoryId, Gender = gender, AgeInYears = ageInYears },
                commandType: CommandType.StoredProcedure
            );
        }

        public async Task<IEnumerable<DepartmentDto>> GetDepartmentsAsync()
        {
            using var connection = db.CreateConnection();
            return await connection.QueryAsync<DepartmentDto>("dbo.usp_GetLabDepartments", commandType: CommandType.StoredProcedure);
        }

        public async Task<IEnumerable<CategoryDto>> GetCategoriesAsync(int? departmentId = null)
        {
            using var connection = db.CreateConnection();
            return await connection.QueryAsync<CategoryDto>("dbo.usp_GetLabCategories", new { DepartmentId = departmentId }, commandType: CommandType.StoredProcedure);
        }

        public async Task<IEnumerable<SubCategoryDto>> GetSubCategoriesAsync(int? categoryId = null)
        {
            using var connection = db.CreateConnection();
            return await connection.QueryAsync<SubCategoryDto>("dbo.usp_GetLabSubCategories", new { CategoryId = categoryId }, commandType: CommandType.StoredProcedure);
        }

        public async Task<LabOrderPagedResult> GetPagedOrdersAsync(int branchId, DateTime? fromDate, DateTime? toDate, string? search, int pageNumber, int pageSize)
        {
            using var connection = db.CreateConnection();
            using var multi = await connection.QueryMultipleAsync(
                "dbo.usp_LabOrder_GetPagedList",
                new
                {
                    BranchId = branchId,
                    FromDate = fromDate,
                    ToDate = toDate,
                    Search = search,
                    PageNumber = pageNumber,
                    PageSize = pageSize
                },
                commandType: CommandType.StoredProcedure
            );

            var stats = await multi.ReadFirstOrDefaultAsync<LabOrderStatsDto>() ?? new LabOrderStatsDto();
            var items = (await multi.ReadAsync<LabOrderListItemDto>()).ToList();
            int totalCount = items.FirstOrDefault()?.TotalCount ?? 0;

            return new LabOrderPagedResult
            {
                Stats = stats,
                Items = items,
                TotalCount = totalCount,
                Page = pageNumber,
                PageSize = pageSize
            };
        }

        public async Task<LabOrderDetailDto?> GetOrderDetailAsync(int labOrderId)
        {
            using var connection = db.CreateConnection();
            using var multi = await connection.QueryMultipleAsync(
                "dbo.usp_LabOrder_GetDetail",
                new { LabOrderId = labOrderId },
                commandType: CommandType.StoredProcedure
            );

            var detail = await multi.ReadFirstOrDefaultAsync<LabOrderDetailDto>();
            if (detail == null) return null;

            detail.Items = (await multi.ReadAsync<LabOrderItemDetailDto>()).ToList();
            detail.Payments = (await multi.ReadAsync<LabOrderPaymentDetailDto>()).ToList();

            return detail;
        }

        public async Task<int> CreateSampleCollectionAsync(int labOrderId, int branchId, int companyId, int userId)
        {
            using var connection = db.CreateConnection();
            return await connection.QuerySingleOrDefaultAsync<int>(
                "dbo.usp_CreateSampleCollectionFromLabOrder",
                new
                {
                    LabOrderId = labOrderId,
                    BranchId = branchId,
                    CompanyId = companyId,
                    CreatedBy = userId
                },
                commandType: CommandType.StoredProcedure
            );
        }
    }
}
