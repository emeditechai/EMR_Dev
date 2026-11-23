using System.Data;
using System.Security.Claims;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace EMR.Api.Controllers;

/// <summary>
/// OPD > Doctor Commission Configuration as profiles (SQLScripts/2518): one scope with a table of share lines
/// (Consultation, Service - all or selected services -, ...). Each line is a DoctorCommissionConfig row; the share
/// calculation is unchanged. Company from the token.
/// </summary>
[ApiController]
[Route("api/doctor-commission-profiles")]
[Produces("application/json")]
public class DoctorCommissionProfilesController(IDbConnectionFactory db) : ControllerBase
{
    public sealed class LineDto
    {
        public int? CommissionConfigId { get; set; }
        public string RevenueType { get; set; } = "Consultation";
        public string CalculationType { get; set; } = "Percentage";
        public string? CommissionBasis { get; set; } = "Net Collected";
        public decimal DoctorShare { get; set; }
        public List<int> ServiceIds { get; set; } = [];
    }

    public sealed class ProfileDto
    {
        public int? ProfileId { get; set; }
        public int? BranchId { get; set; }
        public int? DoctorId { get; set; }
        public int? SpecialityId { get; set; }
        public int? ProcedureId { get; set; }
        public int? ServiceId { get; set; }
        public int? CorporateId { get; set; }
        public int? InsuranceTPAId { get; set; }
        public DateTime? EffectiveFrom { get; set; }
        public DateTime? EffectiveTo { get; set; }
        public bool ApprovalRequired { get; set; } = true;
        public bool IsActive { get; set; } = true;
        public List<LineDto> Lines { get; set; } = [];
    }

    private int CompanyId => int.TryParse(User.FindFirstValue("CompanyId"), out var c) && c > 0 ? c : 1;
    private int? UserId => int.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out var u) && u > 0 ? u : null;

    [HttpGet]
    public async Task<IActionResult> GetList([FromQuery] int? branchId, [FromQuery] int? doctorId, [FromQuery] int? specialityId,
        [FromQuery] bool? isActive, [FromQuery] string? search)
    {
        using var con = db.CreateConnection();
        var rows = (await con.QueryAsync("dbo.usp_Api_DoctorCommissionProfile_List",
            new { CompanyId, BranchId = branchId, DoctorId = doctorId, SpecialityId = specialityId, IsActive = isActive, Search = search },
            commandType: CommandType.StoredProcedure)).Select(r => (IDictionary<string, object?>)r).ToList();
        return Ok(ApiResponse<List<IDictionary<string, object?>>>.Ok(rows));
    }

    [HttpGet("{id:int}")]
    public async Task<IActionResult> GetById(int id)
    {
        using var con = db.CreateConnection();
        using var multi = await con.QueryMultipleAsync("dbo.usp_Api_DoctorCommissionProfile_Get", new { ProfileId = id, CompanyId },
            commandType: CommandType.StoredProcedure);
        var p = await multi.ReadFirstOrDefaultAsync<ProfileDto>();
        if (p is null) return NotFound(ApiResponse.Fail("The commission profile was not found."));
        foreach (var l in await multi.ReadAsync<(int CommissionConfigId, string RevenueType, string CalculationType, string CommissionBasis, decimal DoctorShare, string? ServiceIdsJson)>())
            p.Lines.Add(new LineDto
            {
                CommissionConfigId = l.CommissionConfigId, RevenueType = l.RevenueType, CalculationType = l.CalculationType,
                CommissionBasis = l.CommissionBasis, DoctorShare = l.DoctorShare,
                ServiceIds = string.IsNullOrWhiteSpace(l.ServiceIdsJson) ? [] : System.Text.Json.JsonSerializer.Deserialize<List<int>>(l.ServiceIdsJson) ?? []
            });
        return Ok(ApiResponse<ProfileDto>.Ok(p));
    }

    [HttpPost]
    public async Task<IActionResult> Save([FromBody] ProfileDto p)
    {
        if (p is null) return BadRequest(ApiResponse.Fail("Nothing to save."));
        try
        {
            using var con = db.CreateConnection();
            var id = await con.ExecuteScalarAsync<int>("dbo.usp_Api_DoctorCommissionProfile_Save", new
            {
                p.ProfileId, CompanyId, p.BranchId, p.DoctorId, p.SpecialityId, p.ProcedureId, p.ServiceId, p.CorporateId, p.InsuranceTPAId,
                EffectiveFrom = p.EffectiveFrom?.Date, EffectiveTo = p.EffectiveTo?.Date, p.ApprovalRequired, p.IsActive,
                Lines = System.Text.Json.JsonSerializer.Serialize(p.Lines), UserId
            }, commandType: CommandType.StoredProcedure);
            return Ok(ApiResponse<int>.Ok(id, "Commission profile saved."));
        }
        catch (SqlException ex) when (ex.Number >= 50000)
        {
            return BadRequest(ApiResponse.Fail(ex.Message));
        }
    }

    [HttpDelete("{id:int}")]
    public async Task<IActionResult> Delete(int id)
    {
        using var con = db.CreateConnection();
        var n = await con.ExecuteScalarAsync<int>("dbo.usp_Api_DoctorCommissionProfile_Delete", new { ProfileId = id, CompanyId },
            commandType: CommandType.StoredProcedure);
        return n > 0 ? Ok(ApiResponse<int>.Ok(n)) : NotFound(ApiResponse.Fail("The commission profile was not found."));
    }
}
