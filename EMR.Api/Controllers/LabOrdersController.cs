using System.Threading.Tasks;
using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers
{
    [Route("api/[controller]")]
    [ApiController]
    public class LabOrdersController(ILabOrderService labOrderService) : ControllerBase
    {
        [HttpPost]
        public async Task<IActionResult> CreateOrder([FromBody] LabOrderRequest request)
        {
            if (request == null || request.PatientId <= 0 || request.BranchId <= 0 || request.Items.Count == 0)
                return BadRequest("Invalid request.");

            var userIdClaim = User.FindFirst("UserId")?.Value;
            int userId = int.TryParse(userIdClaim, out var id) ? id : 1;

            var response = await labOrderService.CreateOrderAsync(request, userId);
            return Ok(new { isSuccess = true, data = response });
        }

        [HttpGet("available-investigations")]
        public async Task<IActionResult> GetAvailableInvestigations(
            [FromQuery] int branchId,
            [FromQuery] int? departmentId,
            [FromQuery] int? categoryId,
            [FromQuery] int? subCategoryId,
            [FromQuery] string? gender,
            [FromQuery] int? ageInYears)
        {
            if (branchId <= 0) return BadRequest("BranchId is required.");

            var data = await labOrderService.GetAvailableInvestigationsAsync(branchId, departmentId, categoryId, subCategoryId, gender, ageInYears);
            return Ok(data);
        }

        [HttpGet("departments")]
        public async Task<IActionResult> GetDepartments()
        {
            var data = await labOrderService.GetDepartmentsAsync();
            return Ok(data);
        }

        [HttpGet("categories")]
        public async Task<IActionResult> GetCategories([FromQuery] int? departmentId)
        {
            var data = await labOrderService.GetCategoriesAsync(departmentId);
            return Ok(data);
        }

        [HttpGet("sub-categories")]
        public async Task<IActionResult> GetSubCategories([FromQuery] int? categoryId)
        {
            var data = await labOrderService.GetSubCategoriesAsync(categoryId);
            return Ok(data);
        }

        [HttpGet("paged")]
        public async Task<IActionResult> GetPagedOrders(
            [FromQuery] int branchId,
            [FromQuery] DateTime? fromDate,
            [FromQuery] DateTime? toDate,
            [FromQuery] string? search,
            [FromQuery] int pageNumber = 1,
            [FromQuery] int pageSize = 10)
        {
            if (branchId <= 0) return BadRequest("BranchId is required.");

            var data = await labOrderService.GetPagedOrdersAsync(branchId, fromDate, toDate, search, pageNumber, pageSize);
            return Ok(data);
        }

        [HttpGet("{id}")]
        public async Task<IActionResult> GetOrderDetail(int id)
        {
            if (id <= 0) return BadRequest("Valid LabOrderId is required.");

            var data = await labOrderService.GetOrderDetailAsync(id);
            if (data == null) return NotFound("Lab Order not found.");

            return Ok(data);
        }

        [HttpPost("{id}/sample-collection")]
        public async Task<IActionResult> CreateSampleCollection(int id, [FromQuery] int branchId, [FromQuery] int companyId = 1)
        {
            if (id <= 0) return BadRequest("Valid LabOrderId is required.");

            var userIdClaim = User.FindFirst("UserId")?.Value;
            int userId = int.TryParse(userIdClaim, out var uid) ? uid : 1;

            int count = await labOrderService.CreateSampleCollectionAsync(id, branchId, companyId, userId);
            return Ok(new { isSuccess = true, count });
        }
    }
}
