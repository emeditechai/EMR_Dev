using System;
using System.Threading.Tasks;
using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging;

namespace EMR.Api.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    public class B2BBillingController(IB2BBillingService service, ILogger<B2BBillingController> logger) : ControllerBase
    {
        private int CurrentUserId => int.TryParse(User.FindFirst("UserId")?.Value, out var id) ? id : 1;

        [HttpGet("partner-credit-status")]
        public async Task<IActionResult> GetPartnerCreditStatus([FromQuery] string agentType, [FromQuery] int agentId, [FromQuery] int? branchId = null)
        {
            if (string.IsNullOrWhiteSpace(agentType) || agentId <= 0)
                return BadRequest(new { message = "Valid AgentType ('F' or 'C') and AgentId are required." });

            try
            {
                var result = await service.GetPartnerCreditStatusAsync(agentType, agentId, branchId);
                return Ok(result);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Error fetching credit status for {AgentType} #{AgentId}", agentType, agentId);
                return StatusCode(500, new { message = "Failed to fetch partner credit status." });
            }
        }

        [HttpPost("wallet-topup")]
        public async Task<IActionResult> TopUpWallet([FromBody] WalletTopUpRequest request)
        {
            if (request == null || request.FranchiseId <= 0 || request.Amount <= 0)
                return BadRequest(new { message = "Valid FranchiseId and positive Amount are required." });

            try
            {
                var result = await service.TopUpWalletAsync(request, CurrentUserId);
                return Ok(result);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Error processing wallet top-up for Franchise #{FranchiseId}", request.FranchiseId);
                return BadRequest(new { message = ex.Message });
            }
        }

        [HttpGet("wallet-statement/{franchiseId:int}")]
        public async Task<IActionResult> GetWalletStatement(int franchiseId, [FromQuery] DateTime? fromDate = null, [FromQuery] DateTime? toDate = null)
        {
            if (franchiseId <= 0)
                return BadRequest(new { message = "Valid FranchiseId is required." });

            try
            {
                var items = await service.GetWalletStatementAsync(franchiseId, fromDate, toDate);
                return Ok(items);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Error fetching wallet statement for Franchise #{FranchiseId}", franchiseId);
                return StatusCode(500, new { message = "Failed to fetch wallet statement." });
            }
        }

        [HttpPost("deduct-wallet")]
        public async Task<IActionResult> DeductWallet([FromBody] DeductWalletRequest request)
        {
            if (request == null || request.LabOrderId <= 0 || request.FranchiseId <= 0 || request.Amount <= 0)
                return BadRequest(new { message = "Invalid wallet deduction request." });

            try
            {
                var result = await service.DeductWalletPaymentAsync(request, CurrentUserId);
                return Ok(result);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Error deducting wallet payment for LabOrderId #{LabOrderId}", request.LabOrderId);
                return BadRequest(new { message = ex.Message });
            }
        }

        [HttpGet("uninvoiced-orders")]
        public async Task<IActionResult> GetUninvoicedOrders(
            [FromQuery] string agentType, 
            [FromQuery] int? agentId = null, 
            [FromQuery] string? agentIds = null, 
            [FromQuery] DateTime? fromDate = null, 
            [FromQuery] DateTime? toDate = null)
        {
            if (string.IsNullOrWhiteSpace(agentType))
                return BadRequest(new { message = "AgentType is required." });

            try
            {
                var orders = await service.GetUninvoicedOrdersAsync(agentType, agentId, agentIds, fromDate, toDate);
                return Ok(orders);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Error fetching uninvoiced orders for {AgentType} #{AgentId}", agentType, agentId);
                return StatusCode(500, new { message = "Failed to fetch uninvoiced orders." });
            }
        }

        [HttpPost("generate-invoice")]
        public async Task<IActionResult> GenerateInvoice([FromBody] GenerateInvoiceRequest request)
        {
            bool hasGroups = request?.PartnerGroups != null && request.PartnerGroups.Any(g => !string.IsNullOrWhiteSpace(g.SelectedOrderIds));
            bool hasSingle = request != null && request.AgentId > 0 && !string.IsNullOrWhiteSpace(request.SelectedOrderIds);

            if (request == null || (!hasGroups && !hasSingle))
                return BadRequest(new { message = "Valid partner and at least one order ID are required." });

            try
            {
                var result = await service.GenerateInvoiceAsync(request, CurrentUserId);
                return Ok(result);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Error generating B2B invoice for {AgentType} #{AgentId}", request?.AgentType, request?.AgentId);
                return BadRequest(new { message = ex.Message });
            }
        }

        [HttpGet("invoices")]
        public async Task<IActionResult> GetInvoiceList(
            [FromQuery] string? agentType = null,
            [FromQuery] int? agentId = null,
            [FromQuery] string? status = null,
            [FromQuery] DateTime? fromDate = null,
            [FromQuery] DateTime? toDate = null,
            [FromQuery] string? search = null,
            [FromQuery] int pageNumber = 1,
            [FromQuery] int pageSize = 10)
        {
            try
            {
                var invoices = await service.GetInvoiceListAsync(agentType, agentId, status, fromDate, toDate, search, pageNumber, pageSize);
                return Ok(invoices);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Error fetching B2B invoice list");
                return StatusCode(500, new { message = "Failed to fetch invoices." });
            }
        }

        [HttpGet("invoices/{id:int}")]
        public async Task<IActionResult> GetInvoiceDetail(int id)
        {
            if (id <= 0) return BadRequest(new { message = "Valid InvoiceId is required." });

            try
            {
                var invoice = await service.GetInvoiceDetailAsync(id);
                if (invoice == null)
                    return NotFound(new { message = $"Invoice #{id} not found." });

                return Ok(invoice);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Error fetching invoice #{Id}", id);
                return StatusCode(500, new { message = "Failed to fetch invoice details." });
            }
        }

        [HttpGet("outstanding-settlement")]
        public async Task<IActionResult> GetOutstandingBillsForSettlement([FromQuery] string agentType, [FromQuery] int agentId)
        {
            if (string.IsNullOrWhiteSpace(agentType) || agentId <= 0)
                return BadRequest(new { message = "Valid AgentType and AgentId are required." });

            try
            {
                var bills = await service.GetOutstandingBillsForSettlementAsync(agentType, agentId);
                return Ok(bills);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Error fetching outstanding bills for settlement for {AgentType} #{AgentId}", agentType, agentId);
                return StatusCode(500, new { message = "Failed to fetch settlement bills." });
            }
        }

        [HttpPost("settle-bills")]
        public async Task<IActionResult> SettleBills([FromBody] B2BSettleBillsRequest request)
        {
            if (request == null || request.AgentId <= 0 || request.PaidAmount <= 0 || request.SelectedBills.Count == 0)
                return BadRequest(new { message = "Invalid settlement request. Partner, PaidAmount, and SelectedBills are required." });

            try
            {
                var result = await service.SettleBillsPaymentAsync(request, CurrentUserId);
                return Ok(result);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Error settling B2B bills for {AgentType} #{AgentId}", request.AgentType, request.AgentId);
                return BadRequest(new { message = ex.Message });
            }
        }

        [HttpGet("settlement-receipt/{receiptNo}")]
        public async Task<IActionResult> GetSettlementReceipt(string receiptNo)
        {
            if (string.IsNullOrWhiteSpace(receiptNo))
                return BadRequest(new { message = "Receipt number is required." });

            try
            {
                var receipt = await service.GetSettlementReceiptAsync(receiptNo);
                if (receipt == null)
                    return NotFound(new { message = "Settlement receipt not found." });

                return Ok(receipt);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Error fetching settlement receipt {ReceiptNo}", receiptNo);
                return StatusCode(500, new { message = "Failed to fetch settlement receipt." });
            }
        }
    }
}
