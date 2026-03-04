using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/paymentsummary")]
public class PaymentSummaryController(IPaymentSummaryService paymentSummaryService) : ControllerBase
{
    // GET /api/paymentsummary?moduleCode=OPD&moduleRefId=123
    [HttpGet]
    public async Task<IActionResult> Get([FromQuery] string moduleCode, [FromQuery] int moduleRefId)
    {
        if (string.IsNullOrWhiteSpace(moduleCode) || moduleRefId <= 0)
            return BadRequest(ApiResponse<PaymentSummaryResult>.Fail("moduleCode and moduleRefId are required."));

        var result = await paymentSummaryService.GetByBillAsync(moduleCode, moduleRefId);

        if (result is null)
            return NotFound(ApiResponse<PaymentSummaryResult>.Fail("Bill not found."));

        return Ok(ApiResponse<PaymentSummaryResult>.Ok(result));
    }
}
