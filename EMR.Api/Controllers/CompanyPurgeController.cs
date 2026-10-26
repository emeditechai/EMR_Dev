using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace EMR.Api.Controllers;

/// <summary>Company > Remove data / Delete company (SQLScripts/2337): preview or remove a company's data. Super admin only.</summary>
[ApiController]
[Route("api/company-purge")]
public class CompanyPurgeController(ICompanyPurgeService service) : ControllerBase
{
    private static readonly string[] Levels = ["TRANSACTIONS", "ALL", "DELETE", "BRANCH"];

    [HttpPost]
    public async Task<IActionResult> Purge([FromBody] CompanyPurgeRequest request)
    {
        // the web app forwards the signed-in user's IsSuperAdmin claim on its on-behalf token
        if (!string.Equals(User.FindFirst("IsSuperAdmin")?.Value, "true", StringComparison.OrdinalIgnoreCase))
            return StatusCode(StatusCodes.Status403Forbidden, new { message = "Only a super admin can remove a company's data." });
        if (request is null) return BadRequest(new { message = "Company not found." });
        request.Level = (request.Level ?? "").Trim().ToUpperInvariant();
        if (request.Level == "BRANCH" ? request.BranchId is not > 0 : request.CompanyId <= 0)
            return BadRequest(new { message = request.Level == "BRANCH" ? "Branch not found." : "Company not found." });
        if (!Levels.Contains(request.Level))
            return BadRequest(new { message = "Choose what to remove." });
        try
        {
            return Ok(await service.PurgeAsync(request));
        }
        catch (SqlException ex) when (ex.Number >= 50000)
        {
            return BadRequest(new { message = ex.Message });
        }
    }
}
