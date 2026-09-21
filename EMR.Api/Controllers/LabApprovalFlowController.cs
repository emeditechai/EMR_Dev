using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace EMR.Api.Controllers;

/// <summary>Pathologist Approval Flow configuration (Settings). Configuration only - no report reads it yet.</summary>
[ApiController]
[Route("api/lab-approval-flows")]
public class LabApprovalFlowController(ILabApprovalFlowService service, ILogger<LabApprovalFlowController> logger) : ControllerBase
{
    /// <param name="branchScope">Omit = all, 0 = company-wide only, &gt;0 = that branch only.</param>
    [HttpGet]
    public async Task<IActionResult> GetList(
        [FromQuery] int? companyId = null, [FromQuery] int? branchScope = null,
        [FromQuery] int? departmentId = null, [FromQuery] int? categoryId = null,
        [FromQuery] bool? status = null, [FromQuery] string? search = null)
    {
        try
        {
            return Ok(await service.GetListAsync(companyId, branchScope, departmentId, categoryId, status, search));
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while fetching Pathologist Approval Flows");
            return StatusCode(500, new { message = "An internal error occurred while fetching approval flows." });
        }
    }

    [HttpGet("{id:int}")]
    public async Task<IActionResult> GetById(int id)
    {
        try
        {
            var item = await service.GetByIdAsync(id);
            return item == null ? NotFound(new { message = $"Approval flow with ID {id} not found." }) : Ok(item);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while fetching approval flow #{Id}", id);
            return StatusCode(500, new { message = "An internal error occurred while fetching the approval flow." });
        }
    }

    /// <summary>Pathologists that can be chosen for a flow scope (active, with Registration No, matching branch access and covering every chosen department / category). categoryIds is comma-separated.</summary>
    [HttpGet("eligible-approvers")]
    public async Task<IActionResult> GetEligibleApprovers(
        [FromQuery] int companyId, [FromQuery] int? branchId = null,
        [FromQuery] int? departmentId = null, [FromQuery] string? categoryIds = null,
        [FromQuery] bool includeIneligible = false)
    {
        if (companyId <= 0) return BadRequest(new { message = "companyId is required." });

        try
        {
            return Ok(await service.GetEligibleApproversAsync(companyId, branchId, departmentId, categoryIds, includeIneligible));
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while fetching eligible approvers");
            return StatusCode(500, new { message = "An internal error occurred while fetching eligible approvers." });
        }
    }

    /// <summary>The flow that applies to a branch / department / category (Category, then Department, then Branch, then Company default).</summary>
    [HttpGet("resolve")]
    public async Task<IActionResult> Resolve(
        [FromQuery] int companyId, [FromQuery] int? branchId = null,
        [FromQuery] int? departmentId = null, [FromQuery] int? categoryId = null)
    {
        if (companyId <= 0) return BadRequest(new { message = "companyId is required." });

        try
        {
            return Ok(await service.ResolveAsync(companyId, branchId, departmentId, categoryId));
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while resolving the approval flow");
            return StatusCode(500, new { message = "An internal error occurred while resolving the approval flow." });
        }
    }

    [HttpPost]
    public async Task<IActionResult> Create([FromBody] LabApprovalFlowCreateRequestModel request)
    {
        if (!ModelState.IsValid) return BadRequest(ModelState);

        try
        {
            var newId = await service.CreateAsync(request);
            return CreatedAtAction(nameof(GetById), new { id = newId }, new { id = newId, message = "Approval flow created successfully." });
        }
        catch (SqlException ex) when (ex.Class == 16)   // a validation rule raised by the procedure
        {
            return BadRequest(new { message = ex.Message });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while creating an approval flow");
            return StatusCode(500, new { message = "An internal error occurred while creating the approval flow." });
        }
    }

    [HttpPut("{id:int}")]
    public async Task<IActionResult> Update(int id, [FromBody] LabApprovalFlowUpdateRequestModel request)
    {
        if (id != request.Flow_ID) return BadRequest(new { message = "ID mismatch." });
        if (!ModelState.IsValid) return BadRequest(ModelState);

        try
        {
            await service.UpdateAsync(request);
            return Ok(new { message = "Approval flow updated successfully." });
        }
        catch (SqlException ex) when (ex.Class == 16)
        {
            return BadRequest(new { message = ex.Message });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while updating approval flow #{Id}", id);
            return StatusCode(500, new { message = "An internal error occurred while updating the approval flow." });
        }
    }

    [HttpPatch("{id:int}/toggle-status")]
    public async Task<IActionResult> ToggleStatus(int id, [FromBody] LabApprovalFlowToggleStatusRequestModel request)
    {
        if (id != request.Flow_ID) return BadRequest(new { message = "ID mismatch." });

        try
        {
            await service.ToggleStatusAsync(request);
            return Ok(new { message = "Approval flow status updated successfully." });
        }
        catch (SqlException ex) when (ex.Class == 16)
        {
            return BadRequest(new { message = ex.Message });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while toggling approval flow #{Id}", id);
            return StatusCode(500, new { message = "An internal error occurred while updating the approval flow." });
        }
    }

    [HttpDelete("{id:int}")]
    public async Task<IActionResult> Delete(int id, [FromQuery] int? userId = null)
    {
        try
        {
            await service.DeleteAsync(id, userId);
            return Ok(new { message = "Approval flow deleted successfully." });
        }
        catch (SqlException ex) when (ex.Class == 16)
        {
            return BadRequest(new { message = ex.Message });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while deleting approval flow #{Id}", id);
            return StatusCode(500, new { message = "An internal error occurred while deleting the approval flow." });
        }
    }
}
