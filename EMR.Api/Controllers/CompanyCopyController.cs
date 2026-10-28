using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace EMR.Api.Controllers;

/// <summary>Company > Copy master data (super admin, SQLScripts/2328): preview or copy LAB masters into a company.</summary>
[ApiController]
[Route("api/company-copy")]
public class CompanyCopyController(ICompanyCopyService service) : ControllerBase
{
    [HttpPost("lab-masters")]
    public async Task<IActionResult> LabMasters([FromBody] CompanyCopyRequest request)
    {
        if (request is null || request.SourceCompanyId <= 0 || request.TargetCompanyId <= 0)
            return BadRequest(new { message = "Choose the source company." });
        try
        {
            return Ok(await service.CopyLabMastersAsync(request));
        }
        catch (SqlException ex) when (ex.Number >= 50000)
        {
            return BadRequest(new { message = ex.Message });
        }
    }
}
