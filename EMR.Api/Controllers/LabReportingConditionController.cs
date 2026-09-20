using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/lab-reporting-conditions")]
public class LabReportingConditionController(ILabReportingConditionService service, ILogger<LabReportingConditionController> logger) : ControllerBase
{
    /// <param name="branchScope">Omit = all, 0 = company-wide only, &gt;0 = that branch only.</param>
    [HttpGet]
    public async Task<IActionResult> GetList([FromQuery] bool? status = null, [FromQuery] int? branchScope = null, [FromQuery] string? search = null, [FromQuery] int? companyId = null)
    {
        try
        {
            return Ok(await service.GetListAsync(status, branchScope, search, companyId));
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while fetching Conditions of Reporting");
            return StatusCode(500, new { message = "An internal error occurred while fetching Conditions of Reporting." });
        }
    }

    /// <summary>The conditions to print on a Lab Report for this company + branch (branch-specific if any, else company-wide).</summary>
    [HttpGet("for-report")]
    public async Task<IActionResult> GetForReport([FromQuery] int companyId, [FromQuery] int? branchId = null)
    {
        if (companyId <= 0)
            return BadRequest(new { message = "companyId is required." });

        try
        {
            return Ok(await service.GetForReportAsync(companyId, branchId));
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while resolving report conditions for company {CompanyId} / branch {BranchId}", companyId, branchId);
            return StatusCode(500, new { message = "An internal error occurred while resolving the report conditions." });
        }
    }

    [HttpGet("{id:int}")]
    public async Task<IActionResult> GetById(int id)
    {
        try
        {
            var item = await service.GetByIdAsync(id);
            return item == null ? NotFound(new { message = $"Condition of Reporting with ID {id} not found." }) : Ok(item);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while fetching Condition of Reporting #{Id}", id);
            return StatusCode(500, new { message = "An internal error occurred while fetching the Condition of Reporting." });
        }
    }

    [HttpPost]
    public async Task<IActionResult> Create([FromBody] LabReportingConditionCreateRequestModel request)
    {
        if (!ModelState.IsValid) return BadRequest(ModelState);

        try
        {
            var newId = await service.CreateAsync(request);
            return CreatedAtAction(nameof(GetById), new { id = newId }, new { id = newId, message = "Condition of Reporting created successfully." });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while creating Condition of Reporting");
            return BadRequest(new { message = ex.Message });
        }
    }

    [HttpPut("{id:int}")]
    public async Task<IActionResult> Update(int id, [FromBody] LabReportingConditionUpdateRequestModel request)
    {
        if (id != request.Condition_ID) return BadRequest(new { message = "ID mismatch." });
        if (!ModelState.IsValid) return BadRequest(ModelState);

        try
        {
            await service.UpdateAsync(request);
            return Ok(new { message = "Condition of Reporting updated successfully." });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while updating Condition of Reporting #{Id}", id);
            return BadRequest(new { message = ex.Message });
        }
    }

    [HttpPatch("{id:int}/toggle-status")]
    public async Task<IActionResult> ToggleStatus(int id, [FromBody] LabReportingConditionToggleStatusRequestModel request)
    {
        if (id != request.Condition_ID) return BadRequest(new { message = "ID mismatch." });

        try
        {
            await service.ToggleStatusAsync(request);
            return Ok(new { message = "Condition of Reporting status toggled successfully." });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while toggling status for Condition of Reporting #{Id}", id);
            return BadRequest(new { message = ex.Message });
        }
    }

    [HttpDelete("{id:int}")]
    public async Task<IActionResult> Delete(int id, [FromQuery] int? userId = null)
    {
        try
        {
            await service.DeleteAsync(id, userId);
            return Ok(new { message = "Condition of Reporting deleted successfully." });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while deleting Condition of Reporting #{Id}", id);
            return BadRequest(new { message = ex.Message });
        }
    }
}
