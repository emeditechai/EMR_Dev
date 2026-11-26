using System.Security.Claims;
using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

public record DoctorSignatureSetRequest(string? SignaturePath);

/// <summary>
/// Doctor Master - the doctor's signature image name (SQLScripts/2559), used on the IPD discharge prints. The file itself is kept
/// by EMR.Web (App_Data/doctor-signatures); this stores / reads its name. Separate from the pathologist signature of User Master.
/// </summary>
[ApiController]
[Route("api/doctor-signatures")]
[Produces("application/json")]
public class DoctorSignatureController(IIpdProcService db) : ControllerBase
{
    private (int CompanyId, int UserId)? Caller()
    {
        if (!int.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out var userId) || userId <= 0) return null;
        var companyId = int.TryParse(User.FindFirstValue("CompanyId"), out var c) && c > 0 ? c : 1;
        return (companyId, userId);
    }

    [HttpGet("{doctorId:int}")]
    public async Task<IActionResult> Get(int doctorId) => Caller() is { } c
        ? Ok(ApiResponse<IDictionary<string, object?>?>.Ok(await db.RowAsync("dbo.usp_Api_Doctor_SignatureGet", new { c.CompanyId, DoctorId = doctorId })))
        : BadRequest(ApiResponse.Fail("A signed-in user is required."));

    [HttpPost("{doctorId:int}")]
    public async Task<IActionResult> Set(int doctorId, [FromBody] DoctorSignatureSetRequest r) => Caller() is { } c
        ? Ok(ApiResponse<IDictionary<string, object?>?>.Ok(await db.RowAsync("dbo.usp_Api_Doctor_SignatureSet", new { c.CompanyId, c.UserId, DoctorId = doctorId, r.SignaturePath })))
        : BadRequest(ApiResponse.Fail("A signed-in user is required."));
}
