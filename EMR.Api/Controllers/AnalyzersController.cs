using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/[controller]")]
public class AnalyzersController(IAnalyzerService analyzerService) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> GetList(
        [FromQuery] int? departmentId,
        [FromQuery] string? interfaceProtocol,
        [FromQuery] bool? status,
        [FromQuery] string? search,
        [FromQuery] int? companyId)
    {        var items = await analyzerService.GetListAsync(departmentId, interfaceProtocol, status, search, companyId);
        return Ok(items);
    }

    [HttpGet("{id:int}")]
    public async Task<IActionResult> GetById(int id)
    {
        var item = await analyzerService.GetByIdAsync(id);
        if (item is null) return NotFound(new { message = $"Analyzer #{id} not found." });
        return Ok(item);
    }

    [HttpPost]
    public async Task<IActionResult> Create([FromBody] AnalyzerSaveRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Analyzer_Name))
            return BadRequest(new { message = "Analyzer name is required." });



        if (request.Department_ID <= 0)
            return BadRequest(new { message = "Valid department is required." });

        if (string.IsNullOrWhiteSpace(request.Interface_Protocol))
            return BadRequest(new { message = "Interface protocol is required." });

        var newId = await analyzerService.CreateAsync(request);
        return CreatedAtAction(nameof(GetById), new { id = newId }, new { id = newId, message = "Analyzer created successfully." });
    }

    [HttpPut("{id:int}")]
    public async Task<IActionResult> Update(int id, [FromBody] AnalyzerSaveRequest request)
    {
        request.Analyzer_ID = id;
        if (string.IsNullOrWhiteSpace(request.Analyzer_Name))
            return BadRequest(new { message = "Analyzer name is required." });



        if (request.Department_ID <= 0)
            return BadRequest(new { message = "Valid department is required." });

        if (string.IsNullOrWhiteSpace(request.Interface_Protocol))
            return BadRequest(new { message = "Interface protocol is required." });

        var success = await analyzerService.UpdateAsync(request);
        if (!success) return NotFound(new { message = $"Analyzer #{id} not found." });
        return Ok(new { message = "Analyzer updated successfully." });
    }

    [HttpPost("{id:int}/toggle-status")]
    public async Task<IActionResult> ToggleStatus(int id, [FromQuery] int? userId)
    {
        var newStatus = await analyzerService.ToggleStatusAsync(id, userId);
        if (newStatus is null) return NotFound(new { message = $"Analyzer #{id} not found." });
        return Ok(new { status = newStatus.Value, message = $"Analyzer status changed to {(newStatus.Value ? "Active" : "Inactive")}." });
    }

    [HttpDelete("{id:int}")]
    public async Task<IActionResult> Delete(int id)
    {
        var success = await analyzerService.DeleteAsync(id);
        if (!success) return NotFound(new { message = $"Analyzer #{id} not found." });
        return Ok(new { message = "Analyzer deleted successfully." });
    }
}
