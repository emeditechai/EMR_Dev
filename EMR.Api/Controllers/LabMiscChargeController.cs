using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/[controller]")]
public class LabMiscChargeController(ILabMiscChargeService service, ILogger<LabMiscChargeController> logger) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> GetList([FromQuery] bool? status = null, [FromQuery] string? chargeType = null, [FromQuery] string? search = null, [FromQuery] int? companyId = null)
    {
        try
        {
            return Ok(await service.GetListAsync(status, chargeType, search, companyId));
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while fetching Lab Misc Charges");
            return StatusCode(500, new { message = "An internal error occurred while fetching Misc Charges." });
        }
    }

    [HttpGet("{id:int}")]
    public async Task<IActionResult> GetById(int id)
    {
        try
        {
            var item = await service.GetByIdAsync(id);
            return item == null ? NotFound(new { message = $"Misc Charge with ID {id} not found." }) : Ok(item);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while fetching Lab Misc Charge #{Id}", id);
            return StatusCode(500, new { message = "An internal error occurred while fetching the Misc Charge." });
        }
    }

    [HttpPost]
    public async Task<IActionResult> Create([FromBody] LabMiscChargeSaveRequestModel request)
    {
        if (!ModelState.IsValid) return BadRequest(ModelState);
        try
        {
            var newId = await service.CreateAsync(request);
            return CreatedAtAction(nameof(GetById), new { id = newId }, new { id = newId, message = "Misc Charge created successfully." });
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number >= 50000)
        {
            return BadRequest(new { message = ex.Message });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while creating Lab Misc Charge");
            return BadRequest(new { message = "The Misc Charge could not be saved." });
        }
    }

    [HttpPut("{id:int}")]
    public async Task<IActionResult> Update(int id, [FromBody] LabMiscChargeSaveRequestModel request)
    {
        if (id != request.Misc_Charge_ID) return BadRequest(new { message = "ID mismatch." });
        if (!ModelState.IsValid) return BadRequest(ModelState);
        try
        {
            await service.UpdateAsync(request);
            return Ok(new { message = "Misc Charge updated successfully." });
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number >= 50000)
        {
            return BadRequest(new { message = ex.Message });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while updating Lab Misc Charge #{Id}", id);
            return BadRequest(new { message = "The Misc Charge could not be saved." });
        }
    }

    [HttpPatch("{id:int}/toggle-status")]
    public async Task<IActionResult> ToggleStatus(int id, [FromBody] LabMiscChargeToggleStatusRequestModel request)
    {
        if (id != request.Misc_Charge_ID) return BadRequest(new { message = "ID mismatch." });
        try
        {
            await service.ToggleStatusAsync(request);
            return Ok(new { message = "Misc Charge status updated successfully." });
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number >= 50000)
        {
            return BadRequest(new { message = ex.Message });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while toggling status for Lab Misc Charge #{Id}", id);
            return BadRequest(new { message = "The status could not be changed." });
        }
    }

    [HttpDelete("{id:int}")]
    public async Task<IActionResult> Delete(int id, [FromQuery] int? userId = null)
    {
        try
        {
            await service.DeleteAsync(id, userId);
            return Ok(new { message = "Misc Charge deleted successfully." });
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number >= 50000)
        {
            return BadRequest(new { message = ex.Message });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error occurred while deleting Lab Misc Charge #{Id}", id);
            return BadRequest(new { message = "The Misc Charge could not be deleted." });
        }
    }
}
