using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace EMR.Api.Controllers;

/// <summary>Settings > Hospital Settings: copy every setting of the head office onto a branch (SQLScripts/2318).</summary>
[ApiController]
[Route("api/hospital-settings")]
public class HospitalSettingsCopyController(IDbConnectionFactory db) : ControllerBase
{
    public class CopyRequest
    {
        public int TargetBranchId { get; set; }
        public int? UserId { get; set; }
    }

    public class CopyResult
    {
        public int SettingsId { get; set; }
        public int SourceBranchId { get; set; }
        public string? SourceBranchName { get; set; }
        public int ColumnsCopied { get; set; }
        public string? PreviousValuesJson { get; set; }
    }

    [HttpPost("copy-from-ho")]
    public async Task<IActionResult> Copy([FromBody] CopyRequest req)
    {
        if (req is null || req.TargetBranchId <= 0) return BadRequest(ApiResponse<object>.Fail("Choose the branch."));
        try
        {
            using var con = db.CreateConnection();
            var r = await con.QuerySingleAsync<CopyResult>("dbo.usp_Api_HospitalSettings_CopyFromHO",
                new { req.TargetBranchId, req.UserId }, commandType: CommandType.StoredProcedure);
            return Ok(ApiResponse<CopyResult>.Ok(r));
        }
        catch (SqlException ex) when (ex.Number is >= 51101 and <= 51199)
        {
            return BadRequest(ApiResponse<object>.Fail(ex.Message));
        }
    }
}
