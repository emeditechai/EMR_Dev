using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[ApiController]
[Route("api/doctor-ip")]
[Produces("application/json")]
public class DoctorIpController(IDoctorIpService service) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> GetList([FromQuery] int? companyId, [FromQuery] int? branchId, [FromQuery] bool? status, [FromQuery] string? search)
        => Ok(ApiResponse<IEnumerable<DoctorIpListItem>>.Ok(await service.GetListAsync(companyId, branchId, status, search)));

    [HttpGet("{id:int}")]
    public async Task<IActionResult> GetById(int id)
    {
        var item = await service.GetByIdAsync(id);
        return item == null
            ? NotFound(ApiResponse<object>.Fail("Doctor IP not found."))
            : Ok(ApiResponse<DoctorIpDetail>.Ok(item));
    }

    [HttpPost]
    public async Task<IActionResult> Save([FromBody] DoctorIpSaveRequest req)
    {
        try
        {
            var id = await service.SaveAsync(req);
            return Ok(ApiResponse<int>.Ok(id, "Doctor IP saved successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpPost("{id:int}/toggle-status")]
    public async Task<IActionResult> ToggleStatus(int id, [FromBody] DoctorIpToggleStatusRequest req)
    {
        if (id != req.Doctor_IP_Hdr_ID) return BadRequest(ApiResponse<object>.Fail("ID mismatch."));
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
    public async Task<IActionResult> Delete(int id, [FromQuery] int? userId)
    {
        try
        {
            await service.DeleteAsync(id, userId);
            return Ok(ApiResponse<bool>.Ok(true, "Doctor IP deleted successfully."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }

    [HttpGet("specialities")]
    public async Task<IActionResult> GetSpecialities([FromQuery] int? companyId)
        => Ok(ApiResponse<IEnumerable<DoctorIpSpeciality>>.Ok(await service.GetSpecialitiesAsync(companyId)));

    [HttpGet("doctors")]
    public async Task<IActionResult> GetDoctors([FromQuery] int specialityId, [FromQuery] int? companyId)
        => Ok(ApiResponse<IEnumerable<DoctorIpLookupItem>>.Ok(await service.GetDoctorsAsync(specialityId, companyId)));

    [HttpGet("items")]
    public async Task<IActionResult> GetItems([FromQuery] int? companyId)
        => Ok(ApiResponse<IEnumerable<DoctorIpItem>>.Ok(await service.GetItemsAsync(companyId)));

    [HttpGet("access/status")]
    public async Task<IActionResult> GetAccessStatus([FromQuery] int companyId, [FromQuery] int userId)
        => Ok(ApiResponse<DoctorIpAccessStatus>.Ok(await service.GetAccessStatusAsync(companyId, userId)));

    [HttpPost("access/verify")]
    public async Task<IActionResult> VerifyAccessCode([FromBody] DoctorIpVerifyCodeRequest req)
        => Ok(ApiResponse<DoctorIpVerifyCodeResult>.Ok(await service.VerifyAccessCodeAsync(req)));

    [HttpPost("access/code")]
    public async Task<IActionResult> SetAccessCode([FromBody] DoctorIpSetCodeRequest req)
    {
        try
        {
            await service.SetAccessCodeAsync(req);
            return Ok(ApiResponse<bool>.Ok(true, "Access code updated."));
        }
        catch (Exception ex)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }
}
