using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>
/// Pharmacy > Sales > Sales Dashboard (SQLScripts/2568): sales of a period split into POS (walk-in), Direct (patient /
/// credit customer) and IPD (issues to admitted patients). One stored procedure, six result sets: channel summary,
/// daily trend, collections by mode, top items, the requested page of documents and their totals.
/// </summary>
[ApiController]
[Route("api/pharmacy/sales-dashboard")]
[Produces("application/json")]
public class PharmacySalesDashboardController(IPharmacyProcService ph) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> Get([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] DateTime? from, [FromQuery] DateTime? to,
        [FromQuery] string? channel, [FromQuery] string? search, [FromQuery] int page = 1, [FromQuery] int pageSize = 25)
    {
        var sets = await ph.SetsAsync("dbo.usp_Api_PhSalesDash_Get", new
        {
            CompanyId = companyId, BranchId = branchId, From = from?.Date, To = to?.Date,
            Channel = channel, Search = search, Page = page, PageSize = pageSize
        }, 6);
        return Ok(ApiResponse<List<List<IDictionary<string, object?>>>>.Ok(sets));
    }
}
