using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/lab-rate-cards")]
public class LabRateCardController(ILabRateCardService service) : ControllerBase
{
    [HttpGet]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<LabRateCardHeaderModel>>), 200)]
    public async Task<IActionResult> GetList([FromQuery] string? rateType, [FromQuery] int? branchId, [FromQuery] bool? status, [FromQuery] int companyId = 1)
    {
        var list = await service.GetListAsync(rateType, branchId, status, companyId);
        return Ok(ApiResponse<IEnumerable<LabRateCardHeaderModel>>.Ok(list));
    }

    [HttpGet("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<LabRateCardFullModel>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetById(int id)
    {
        var item = await service.GetByIdAsync(id);
        if (item == null)
            return NotFound(ApiResponse<object>.Fail("Rate Card not found."));

        return Ok(ApiResponse<LabRateCardFullModel>.Ok(item));
    }

    [HttpPost]
    [ProducesResponseType(typeof(ApiResponse<int>), 200)]
    public async Task<IActionResult> Save([FromBody] LabRateCardSaveRequest req)
    {
        try
        {
            var newId = await service.SaveAsync(req);
            return Ok(ApiResponse<int>.Ok(newId, "Rate Card saved successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPatch("{id:int}/status")]
    public async Task<IActionResult> ToggleStatus(int id, [FromBody] LabRateCardToggleStatusRequest req)
    {
        if (id != req.RateCard_ID)
            return BadRequest(ApiResponse<object>.Fail("ID mismatch."));

        try
        {
            await service.ToggleStatusAsync(req);
            return Ok(ApiResponse<bool>.Ok(true, "Status toggled successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpDelete("{id:int}")]
    public async Task<IActionResult> Delete(int id, [FromQuery] int? userId)
    {
        try
        {
            await service.DeleteAsync(id, userId);
            return Ok(ApiResponse<bool>.Ok(true, "Rate Card deleted successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpGet("items")]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<LabItemModel>>), 200)]
    public async Task<IActionResult> GetAllItems([FromQuery] int companyId = 1)
    {
        var list = await service.GetAllItemsAsync(companyId);
        return Ok(ApiResponse<IEnumerable<LabItemModel>>.Ok(list));
    }
}
