using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/[controller]")]
public class LabSampleRejectionReasonController(ILabSampleRejectionReasonService service, ILogger<LabSampleRejectionReasonController> logger) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> GetList([FromQuery] bool? status = null, [FromQuery] int? sampleTypeId = null, [FromQuery] string? search = null, [FromQuery] int? companyId = null)
    {
        try
        {
            var items = await service.GetListAsync(status, sampleTypeId, search, companyId);
            return Ok(items);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while fetching Lab Sample Rejection Reasons");
            return StatusCode(500, new { message = "An internal error occurred while fetching Lab Sample Rejection Reasons." });
        }
    }

    [HttpGet("{id:int}")]
    public async Task<IActionResult> GetById(int id)
    {
        try
        {
            var item = await service.GetByIdAsync(id);
            if (item == null)
                return NotFound(new { message = $"Lab Sample Rejection Reason with ID {id} not found." });

            return Ok(item);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while fetching Lab Sample Rejection Reason #{Id}", id);
            return StatusCode(500, new { message = "An internal error occurred while fetching the Lab Sample Rejection Reason." });
        }
    }

    [HttpPost]
    public async Task<IActionResult> Create([FromBody] LabSampleRejectionReasonCreateRequestModel request)
    {
        if (!ModelState.IsValid)
            return BadRequest(ModelState);

        try
        {
            var newId = await service.CreateAsync(request);
            return CreatedAtAction(nameof(GetById), new { id = newId }, new { id = newId, message = "Lab Sample Rejection Reason created successfully." });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while creating Lab Sample Rejection Reason");
            return BadRequest(new { message = ex.Message });
        }
    }

    [HttpPut("{id:int}")]
    public async Task<IActionResult> Update(int id, [FromBody] LabSampleRejectionReasonUpdateRequestModel request)
    {
        if (id != request.Reason_ID)
            return BadRequest(new { message = "ID mismatch." });

        if (!ModelState.IsValid)
            return BadRequest(ModelState);

        try
        {
            await service.UpdateAsync(request);
            return Ok(new { message = "Lab Sample Rejection Reason updated successfully." });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while updating Lab Sample Rejection Reason #{Id}", id);
            return BadRequest(new { message = ex.Message });
        }
    }

    [HttpPatch("{id:int}/toggle-status")]
    public async Task<IActionResult> ToggleStatus(int id, [FromBody] LabSampleRejectionReasonToggleStatusRequestModel request)
    {
        if (id != request.Reason_ID)
            return BadRequest(new { message = "ID mismatch." });

        try
        {
            await service.ToggleStatusAsync(request);
            return Ok(new { message = "Lab Sample Rejection Reason status toggled successfully." });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while toggling status for Lab Sample Rejection Reason #{Id}", id);
            return BadRequest(new { message = ex.Message });
        }
    }

    [HttpDelete("{id:int}")]
    public async Task<IActionResult> Delete(int id, [FromQuery] int? userId = null)
    {
        try
        {
            await service.DeleteAsync(id, userId);
            return Ok(new { message = "Lab Sample Rejection Reason deleted successfully." });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while deleting Lab Sample Rejection Reason #{Id}", id);
            return BadRequest(new { message = ex.Message });
        }
    }
}
