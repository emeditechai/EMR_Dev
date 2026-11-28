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
            int userId = (request.CreatedBy.HasValue && request.CreatedBy.Value > 0)
                ? request.CreatedBy.Value
                : (int.TryParse(userIdClaim, out var id) ? id : 1);

            try
            {
                var response = await labOrderService.CreateOrderAsync(request, userId);
                return Ok(new { isSuccess = true, data = response });
            }
            catch (Microsoft.Data.SqlClient.SqlException ex) when ((ex.Number == 50000 && ex.Class == 16) || ex.Number is >= 56402 and <= 56404)
            {
                // a rule of usp_CreateLabOrder, or of the LMP date (usp_LabOrder_SetLmp, 2453) (e.g. an item not on the branch's rate list - script 2199): tell the user why
                return BadRequest(new { message = ex.Message });
            }
        }

        [HttpGet("available-investigations")]
        public async Task<IActionResult> GetAvailableInvestigations(
            [FromQuery] int branchId,
            [FromQuery] int? departmentId,
            [FromQuery] int? categoryId,
            [FromQuery] int? subCategoryId,
            [FromQuery] string? gender,
            [FromQuery] int? ageInYears,
            [FromQuery] string? rateType = "B2C",
            [FromQuery] int? agentId = null)
        {
            if (branchId <= 0) return BadRequest("BranchId is required.");

            var data = await labOrderService.GetAvailableInvestigationsAsync(branchId, departmentId, categoryId, subCategoryId, gender, ageInYears, rateType, agentId);
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
            [FromQuery] int pageSize = 10,
            [FromQuery] bool? isB2B = null,
            [FromQuery] string? dateType = null,
            [FromQuery] string? paymentFilter = null,
            [FromQuery] string? agentType = null,
            [FromQuery] int? agentId = null,
            [FromQuery] int? createdBy = null)
        {
            if (branchId <= 0) return BadRequest("BranchId is required.");

            var data = await labOrderService.GetPagedOrdersAsync(branchId, fromDate, toDate, search, pageNumber, pageSize, isB2B, dateType, paymentFilter, agentType, agentId, createdBy);
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

        /// <summary>LAB B2B: is the partner's rate list a government scheme (Beneficiary ID mandatory)? SQLScripts/2535</summary>
        [HttpGet("b2b-scheme")]
        public async Task<IActionResult> GetB2BScheme([FromQuery] int branchId, [FromQuery] string agentType, [FromQuery] int agentId)
        {
            if (branchId <= 0 || agentId <= 0 || string.IsNullOrWhiteSpace(agentType)) return BadRequest("branchId, agentType and agentId are required.");
            return Ok(await labOrderService.GetB2BSchemeAsync(branchId, agentType, agentId));
        }

        /// <summary>After a B2B order is saved: records its government scheme and Beneficiary ID (SQLScripts/2535).</summary>
        [HttpPost("{id}/scheme")]
        public async Task<IActionResult> SetOrderScheme(int id, [FromBody] LabOrderSchemeRequest request)
        {
            if (id <= 0) return BadRequest("Valid LabOrderId is required.");
            return Ok(new { schemeName = await labOrderService.SetOrderSchemeAsync(id, request?.BeneficiaryId) });
        }

        /// <summary>B2C bill, discount reason "Referred by doctor": is it deducted from the referral doctor (SQLScripts/2569)?
        /// value null clears it. 409 when the bill is B2B or has no referral doctor.</summary>
        [HttpPost("{id}/disc-deducted-from-doctor")]
        public async Task<IActionResult> SetDiscDeductedFromDoctor(int id, [FromBody] LabOrderDiscDeductedRequest request)
        {
            if (id <= 0) return BadRequest("Valid LabOrderId is required.");
            try { return Ok(new { updated = await labOrderService.SetDiscDeductedFromDoctorAsync(id, request?.Value) }); }
            catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 56620) { return Conflict(ex.Message); }
        }

        /// <summary>Order lists: consent needed / already on file, for the given bills (SQLScripts/2553).</summary>
        [HttpGet("consent-status")]
        public async Task<IActionResult> GetConsentStatus([FromQuery] string ids, [FromQuery] int? branchId = null)
        {
            if (string.IsNullOrWhiteSpace(ids)) return Ok(System.Array.Empty<LabOrderConsentStatusDto>());
            return Ok(await labOrderService.GetConsentStatusAsync(ids, branchId));
        }

        /// <summary>FORM F (PC-PNDT) fields of a B2C bill; 404 when the bill has no female consent test (SQLScripts/2554).</summary>
        [HttpGet("{id}/form-f")]
        public async Task<IActionResult> GetFormF(int id, [FromQuery] int? branchId = null)
        {
            if (id <= 0) return BadRequest(new { message = "A valid bill is required." });
            var dto = await labOrderService.GetFormFAsync(id, branchId);
            return dto == null ? NotFound(new { message = "This bill has no test that needs FORM F." }) : Ok(dto);
        }

        /// <summary>Consent uploaded after billing: stores the file path saved by EMR.Web (SQLScripts/2553).</summary>
        [HttpPost("{id}/consent")]
        public async Task<IActionResult> SaveConsent(int id, [FromBody] LabOrderConsentRequest request)
        {
            if (id <= 0 || string.IsNullOrWhiteSpace(request?.ConsentFilePath)) return BadRequest(new { message = "A bill and a consent file are required." });
            try
            {
                await labOrderService.SaveConsentAsync(id, request.ConsentFilePath, request.BranchId, request.UserId);
                return Ok(new { isSuccess = true });
            }
            catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is 56530 or 56531)
            {
                return BadRequest(new { message = ex.Message });
            }
        }

        /// <summary>B2C Order List: can these bookings be rescheduled (SQLScripts/2561).</summary>
        [HttpGet("reschedule-info")]
        public async Task<IActionResult> GetRescheduleInfo([FromQuery] string ids, [FromQuery] int branchId)
        {
            if (string.IsNullOrWhiteSpace(ids) || branchId <= 0) return Ok(System.Array.Empty<LabOrderRescheduleInfoDto>());
            return Ok(await labOrderService.GetRescheduleInfoAsync(ids, branchId));
        }

        /// <summary>Reschedule history of one booking.</summary>
        [HttpGet("{id}/reschedules")]
        public async Task<IActionResult> GetRescheduleHistory(int id, [FromQuery] int branchId)
        {
            if (id <= 0 || branchId <= 0) return BadRequest(new { message = "A bill and a branch are required." });
            return Ok(await labOrderService.GetRescheduleHistoryAsync(id, branchId));
        }

        /// <summary>Moves a B2C booking to a new date / time; a refused rule comes back as 400 with its message.</summary>
        [HttpPost("{id}/reschedule")]
        public async Task<IActionResult> Reschedule(int id, [FromBody] LabOrderRescheduleRequest request)
        {
            if (id <= 0 || request == null || request.BranchId <= 0 || request.UserId <= 0)
                return BadRequest(new { message = "A bill, a branch and a user are required." });
            try
            {
                var result = await labOrderService.RescheduleAsync(id, request);
                return result == null ? BadRequest(new { message = "The booking could not be rescheduled." }) : Ok(result);
            }
            catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is >= 56600 and <= 56619)
            {
                return BadRequest(new { message = ex.Message });
            }
        }

        /// <summary>Records what the patient was sent about a reschedule (WhatsApp / e-mail).</summary>
        [HttpPost("reschedules/{rescheduleId}/notified")]
        public async Task<IActionResult> RescheduleNotified(int rescheduleId, [FromBody] LabOrderRescheduleNotifiedRequest request)
        {
            if (rescheduleId <= 0 || request == null || request.BranchId <= 0) return BadRequest(new { message = "A reschedule and a branch are required." });
            await labOrderService.SetRescheduleNotifiedAsync(rescheduleId, request);
            return Ok(new { isSuccess = true });
        }

        [HttpPost("{id}/sample-collection")]
        public async Task<IActionResult> CreateSampleCollection(int id, [FromQuery] int branchId, [FromQuery] int companyId = 1, [FromQuery] int? userId = null)
        {
            if (id <= 0) return BadRequest("Valid LabOrderId is required.");

            var userIdClaim = User.FindFirst("UserId")?.Value;
            int effectiveUserId = (userId.HasValue && userId.Value > 0)
                ? userId.Value
                : (int.TryParse(userIdClaim, out var uid) ? uid : 1);

            int count = await labOrderService.CreateSampleCollectionAsync(id, branchId, companyId, effectiveUserId);
            return Ok(new { isSuccess = true, count });
        }
    }
}
