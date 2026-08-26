using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/[controller]")]
public class DiscountTypesController(IDiscountTypeService discountTypeService, ILogger<DiscountTypesController> logger) : ControllerBase
{
    [HttpGet]
    public async Task<ActionResult<IEnumerable<DiscountTypeListItem>>> GetList(
        [FromQuery] int? branchId = null,
        [FromQuery] bool? status = null,
        [FromQuery] string? search = null,
        [FromQuery] int? companyId = null)
    {
        try
        {
            var result = await discountTypeService.GetListAsync(branchId, status, search, companyId);
            return Ok(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error getting discount types list");
            return StatusCode(500, "Internal server error");
        }
    }

    [HttpGet("{id}")]
    public async Task<ActionResult<DiscountTypeDetail>> Get(int id)
    {
        try
        {
            var result = await discountTypeService.GetByIdAsync(id);
            if (result == null)
                return NotFound();

            return Ok(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error getting discount type by id {Id}", id);
            return StatusCode(500, "Internal server error");
        }
    }

    [HttpPost]
    public async Task<ActionResult<int>> Create([FromBody] CreateDiscountTypeRequest request)
    {
        try
        {
            var newId = await discountTypeService.CreateAsync(request, request.UserId);
            return CreatedAtAction(nameof(Get), new { id = newId }, newId);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error creating discount type");
            return StatusCode(500, "Internal server error");
        }
    }

    [HttpPut("{id}")]
    public async Task<IActionResult> Update(int id, [FromBody] UpdateDiscountTypeRequest request)
    {
        try
        {
            if (id != request.DiscountTypeId)
                return BadRequest("ID mismatch");

            var existing = await discountTypeService.GetByIdAsync(id);
            if (existing == null)
                return NotFound();

            await discountTypeService.UpdateAsync(request, request.UserId);
            return NoContent();
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error updating discount type {Id}", id);
            return StatusCode(500, "Internal server error");
        }
    }

    [HttpDelete("{id}")]
    public async Task<IActionResult> Delete(int id)
    {
        try
        {
            var existing = await discountTypeService.GetByIdAsync(id);
            if (existing == null)
                return NotFound();

            await discountTypeService.DeleteAsync(id);
            return NoContent();
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error deleting discount type {Id}", id);
            return StatusCode(500, "Internal server error");
        }
    }
}
