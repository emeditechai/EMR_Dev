using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/[controller]")]
public class LabFranchiseController(ILabFranchiseService service, ILogger<LabFranchiseController> logger) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> GetList(
        [FromQuery] bool? status = null, 
        [FromQuery] bool? isActive = null, 
        [FromQuery] string? search = null, 
        [FromQuery] int? companyId = null,
        [FromQuery] int? franchiseType = null,
        [FromQuery] int? parentBranchId = null)
    {
        try
        {
            var items = await service.GetListAsync(status, isActive, search, companyId, franchiseType, parentBranchId);
            return Ok(items);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while fetching Lab Franchises");
            return StatusCode(500, new { message = "An internal error occurred while fetching Lab Franchises." });
        }
    }

    [HttpGet("{id:int}")]
    public async Task<IActionResult> GetById(int id)
    {
        try
        {
            var item = await service.GetByIdAsync(id);
            if (item == null)
                return NotFound(new { message = $"Lab Franchise with ID {id} not found." });

            return Ok(item);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while fetching Lab Franchise #{Id}", id);
            return StatusCode(500, new { message = "An internal error occurred while fetching the Lab Franchise." });
        }
    }

    [HttpPost]
    public async Task<IActionResult> Create([FromBody] LabFranchiseCreateRequestModel request)
    {
        if (!ModelState.IsValid)
            return BadRequest(ModelState);

        try
        {
            var newId = await service.CreateAsync(request);
            return CreatedAtAction(nameof(GetById), new { id = newId }, new { id = newId, message = "Lab Franchise created successfully." });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while creating Lab Franchise");
            return BadRequest(new { message = ex.Message });
        }
    }

    [HttpPut("{id:int}")]
    public async Task<IActionResult> Update(int id, [FromBody] LabFranchiseUpdateRequestModel request)
    {
        if (id != request.Franchise_ID)
            return BadRequest(new { message = "ID mismatch." });

        if (!ModelState.IsValid)
            return BadRequest(ModelState);

        try
        {
            await service.UpdateAsync(request);
            return Ok(new { message = "Lab Franchise updated successfully." });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while updating Lab Franchise #{Id}", id);
            return BadRequest(new { message = ex.Message });
        }
    }

    [HttpPatch("{id:int}/toggle-status")]
    public async Task<IActionResult> ToggleStatus(int id, [FromBody] LabFranchiseToggleStatusRequestModel request)
    {
        if (id != request.Franchise_ID)
            return BadRequest(new { message = "ID mismatch." });

        try
        {
            await service.ToggleStatusAsync(request);
            return Ok(new { message = "Lab Franchise active status updated successfully." });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while toggling status for Lab Franchise #{Id}", id);
            return BadRequest(new { message = ex.Message });
        }
    }

    [HttpPatch("{id:int}/toggle-suspension")]
    public async Task<IActionResult> ToggleSuspension(int id, [FromBody] LabFranchiseToggleSuspensionRequestModel request)
    {
        if (id != request.Franchise_ID)
            return BadRequest(new { message = "ID mismatch." });

        try
        {
            await service.ToggleSuspensionAsync(request);
            return Ok(new { message = "Lab Franchise suspension status updated successfully." });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while toggling suspension for Lab Franchise #{Id}", id);
            return BadRequest(new { message = ex.Message });
        }
    }

    [HttpDelete("{id:int}")]
    public async Task<IActionResult> Delete(int id, [FromQuery] int? userId = null)
    {
        try
        {
            await service.DeleteAsync(id, userId);
            return Ok(new { message = "Lab Franchise deleted successfully." });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while deleting Lab Franchise #{Id}", id);
            return BadRequest(new { message = ex.Message });
        }
    }
}
