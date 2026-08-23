using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/lab-test-sub-categories")]
[Produces("application/json")]
public class LabTestSubCategoryController(ILabTestSubCategoryService service) : ControllerBase
{
    [HttpGet]
    [ProducesResponseType(typeof(ApiResponse<IEnumerable<LabTestSubCategoryListItem>>), 200)]
    public async Task<IActionResult> GetList(
        [FromQuery] int? branchId,
        [FromQuery] int? categoryId,
        [FromQuery] bool? status,
        [FromQuery] string? search,
        [FromQuery] int? companyId)
    {
        var data = await service.GetListAsync(branchId, categoryId, status, search, companyId);
        return Ok(ApiResponse<IEnumerable<LabTestSubCategoryListItem>>.Ok(data));
    }

    [HttpGet("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<LabTestSubCategoryListItem>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 404)]
    public async Task<IActionResult> GetById(int id)
    {
        var item = await service.GetByIdAsync(id);
        if (item == null)
            return NotFound(ApiResponse<object>.Fail("Lab Test Sub Category record not found."));

        return Ok(ApiResponse<LabTestSubCategoryListItem>.Ok(item));
    }

    [HttpPost]
    [ProducesResponseType(typeof(ApiResponse<int>), 201)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Create([FromBody] LabTestSubCategoryCreateRequest req)
    {
        try
        {
            var newId = await service.CreateAsync(req);
            return CreatedAtAction(nameof(GetById), new { id = newId }, ApiResponse<int>.Ok(newId, "Lab Test Sub Category created successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPut("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Update(int id, [FromBody] LabTestSubCategoryUpdateRequest req)
    {
        if (id != req.SubCategory_ID)
            return BadRequest(ApiResponse<object>.Fail("SubCategory ID mismatch."));

        try
        {
            await service.UpdateAsync(req);
            return Ok(ApiResponse<bool>.Ok(true, "Lab Test Sub Category updated successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPost("{id:int}/toggle-status")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> ToggleStatus(int id, [FromBody] LabTestSubCategoryToggleStatusRequest req)
    {
        if (id != req.SubCategory_ID)
            return BadRequest(ApiResponse<object>.Fail("SubCategory ID mismatch."));

        try
        {
            await service.ToggleStatusAsync(req);
            return Ok(ApiResponse<bool>.Ok(true, "Status updated successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpDelete("{id:int}")]
    [ProducesResponseType(typeof(ApiResponse<bool>), 200)]
    [ProducesResponseType(typeof(ApiResponse<object>), 400)]
    public async Task<IActionResult> Delete(int id)
    {
        try
        {
            await service.DeleteAsync(id);
            return Ok(ApiResponse<bool>.Ok(true, "Lab Test Sub Category deleted successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }
}
