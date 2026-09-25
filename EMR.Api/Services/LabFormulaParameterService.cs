using System.Data;
using System.Globalization;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabFormulaParameterService(IDbConnectionFactory db) : ILabFormulaParameterService
{
    public async Task<IEnumerable<LabFormulaParameterListItem>> GetListAsync(bool? status, string? search, int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabFormulaParameterListItem>(
            "usp_Api_LabFormulaParameterMaster_GetList",
            new { Status = status, Search = search, CompanyId = companyId },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<LabFormulaParameterListItem?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<LabFormulaParameterListItem>(
            "usp_Api_LabFormulaParameterMaster_GetById",
            new { Parameter_ID = id },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<int> CreateAsync(LabFormulaParameterCreateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Test_ID", req.Test_ID);
        p.Add("@Formula_Expression", req.Formula_Expression);
        p.Add("@Rounding_Precision", req.Rounding_Precision);
        p.Add("@Validity_Condition", req.Validity_Condition);
        p.Add("@CompanyId", req.CompanyId);
        p.Add("@UserId", req.UserId);
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await con.ExecuteAsync("usp_Api_LabFormulaParameterMaster_Create", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }

    public async Task UpdateAsync(LabFormulaParameterUpdateRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabFormulaParameterMaster_Update",
            new
            {
                Parameter_ID = req.Parameter_ID,
                Test_ID = req.Test_ID,
                Formula_Expression = req.Formula_Expression,
                Rounding_Precision = req.Rounding_Precision,
                Validity_Condition = req.Validity_Condition,
                IsActive = req.IsActive,
                UserId = req.UserId
            },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task ToggleStatusAsync(LabFormulaParameterToggleStatusRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabFormulaParameterMaster_ToggleStatus",
            new
            {
                Parameter_ID = req.Parameter_ID,
                IsActive = req.IsActive,
                UserId = req.UserId
            },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task DeleteAsync(int id)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabFormulaParameterMaster_Delete",
            new { Parameter_ID = id },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<IEnumerable<NumericTestItem>> GetNumericTestsAsync(int? companyId, string? search)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<NumericTestItem>(
            "usp_Api_LabFormulaParameterMaster_GetNumericTests",
            new { CompanyId = companyId, Search = search },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<IEnumerable<LabFormulaForOrderItem>> GetForOrderAsync(int labOrderId, int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabFormulaForOrderItem>(
            "usp_Api_LabFormula_GetForOrder",
            new { LabOrderId = labOrderId, CompanyId = companyId },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<IEnumerable<LabFormulaEvaluationResult>> EvaluateAsync(LabFormulaEvaluateRequest request)
    {
        var formulas = (await GetForOrderAsync(request.LabOrderId, request.CompanyId)).ToList();
        var results = new List<LabFormulaEvaluationResult>();
        if (formulas.Count == 0) return results;

        // Only numbers can feed a formula; anything else (text result, blank) counts as not entered yet.
        var entered = new Dictionary<string, decimal>(StringComparer.OrdinalIgnoreCase);
        foreach (var v in request.Values ?? new List<LabFormulaEntryValue>())
        {
            if (string.IsNullOrWhiteSpace(v.TestCode) || string.IsNullOrWhiteSpace(v.Value)) continue;
            if (decimal.TryParse(v.Value.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d))
                entered[v.TestCode.Trim()] = d;
        }

        foreach (var f in formulas)
        {
            var r = LabFormulaEvaluator.Evaluate(f.FormulaExpression, entered);
            var precision = Math.Clamp(f.RoundingPrecision, 0, 10);
            results.Add(new LabFormulaEvaluationResult
            {
                Parameter_ID = f.Parameter_ID,
                TargetTestCode = f.TargetTestCode,
                TargetTestName = f.TargetTestName,
                FormulaExpression = f.FormulaExpression,
                RoundingPrecision = precision,
                ValidityCondition = f.ValidityCondition,
                Value = r.HasValue
                    ? Math.Round(r.Value, precision, MidpointRounding.AwayFromZero).ToString("F" + precision, CultureInfo.InvariantCulture)
                    : null,
                Message = r.Message ?? (r.MissingCodes.Count > 0 ? "Waiting for " + string.Join(", ", r.MissingCodes) : null),
                UsedCodes = r.UsedCodes.ToList(),
                MissingCodes = r.MissingCodes.ToList()
            });
        }

        return results;
    }
}
