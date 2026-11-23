using System.Security.Claims;
using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>Lab Serial No on the report entry pages (SQLScripts/2514): one per lab order per report type (LAB / IMAGE / MICRO),
/// required while Hospital Settings > LAB > "Is Lab Serial No Req" is Yes for the branch.</summary>
[ApiController]
[Route("api/lab-serial-no")]
[Produces("application/json")]
public class LabSerialNoController(IIpdProcService procs) : ControllerBase
{
    public sealed class SaveRequest
    {
        public int LabOrderId { get; set; }
        public string ReportType { get; set; } = "";
        public int BranchId { get; set; }
        public string? LabSerialNo { get; set; }
    }

    [HttpGet]
    public async Task<IActionResult> Get([FromQuery] int labOrderId, [FromQuery] string? reportType, [FromQuery] int branchId)
    {
        if (labOrderId <= 0 || branchId <= 0) return BadRequest(ApiResponse.Fail("Lab order and branch are needed."));
        var rows = await procs.RowsAsync("dbo.usp_Api_LabSerialNo_Get", new { LabOrderId = labOrderId, ReportType = reportType, BranchId = branchId });
        return Ok(ApiResponse<IDictionary<string, object?>?>.Ok(rows.FirstOrDefault()));
    }

    [HttpPost]
    public async Task<IActionResult> Save([FromBody] SaveRequest r)
    {
        if (r is null || r.LabOrderId <= 0 || r.BranchId <= 0) return BadRequest(ApiResponse.Fail("Lab order and branch are needed."));
        int? userId = int.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out var u) && u > 0 ? u : null;
        var row = (await procs.RowsAsync("dbo.usp_Api_LabSerialNo_Save",
            new { r.LabOrderId, r.ReportType, r.BranchId, r.LabSerialNo, UserId = userId })).FirstOrDefault();
        var ok = row is not null && row.TryGetValue("Success", out var s) && s is true;
        var msg = row is not null && row.TryGetValue("Message", out var m) ? m as string : null;
        return ok ? Ok(ApiResponse<object?>.Ok(null)) : BadRequest(ApiResponse.Fail(string.IsNullOrWhiteSpace(msg) ? "The Lab Serial No was not saved." : msg));
    }
}
