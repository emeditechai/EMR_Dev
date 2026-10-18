using Dapper;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Master > Lab Master > Reflex Rules (SQLScripts/2289): when a result meets a rule's condition, LAB Reporting suggests
/// the follow-up test to the pathologist. Standard rules are seeded switched off; pathology reviews and switches them on.
/// </summary>
[Authorize]
public class LabReflexRulesController(IDbConnectionFactory db, IAuditLogService auditLogService) : Controller
{
    public static readonly Dictionary<string, string> Conditions = new()
    {
        ["GT"] = "greater than", ["GTE"] = "at least", ["LT"] = "less than", ["LTE"] = "at most",
        ["BETWEEN"] = "between", ["OUTSIDE"] = "outside", ["FLAG_H"] = "flagged High", ["FLAG_L"] = "flagged Low",
        ["FLAG_ABN"] = "flagged abnormal", ["TEXT"] = "contains text"
    };

    public sealed class RuleRow
    {
        public int Rule_ID { get; set; }
        public int Trigger_Test_ID { get; set; }
        public string TriggerName { get; set; } = "";
        public string TriggerCode { get; set; } = "";
        public string Condition_Type { get; set; } = "";
        public decimal? Value1 { get; set; }
        public decimal? Value2 { get; set; }
        public string? Text_Value { get; set; }
        public string Gender { get; set; } = "All";
        public int Suggest_Test_ID { get; set; }
        public string SuggestName { get; set; } = "";
        public string SuggestCode { get; set; } = "";
        public string? Reason { get; set; }
        public bool Is_Standard { get; set; }
        public bool IsActive { get; set; }
        public int Advised { get; set; }
        public int Dismissed { get; set; }
    }

    public sealed class RuleForm
    {
        public int RuleId { get; set; }
        public int TriggerTestId { get; set; }
        public string? ConditionType { get; set; }
        public decimal? Value1 { get; set; }
        public decimal? Value2 { get; set; }
        public string? TextValue { get; set; }
        public string? Gender { get; set; }
        public int SuggestTestId { get; set; }
        public string? Reason { get; set; }
        public bool IsActive { get; set; } = true;
    }

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        using var con = db.CreateConnection();
        var rows = (await con.QueryAsync<RuleRow>(@"
            SELECT r.Rule_ID, r.Trigger_Test_ID, t.Test_Name AS TriggerName, t.Test_Code AS TriggerCode, r.Condition_Type, r.Value1, r.Value2,
                   r.Text_Value, r.Gender, r.Suggest_Test_ID, s.Test_Name AS SuggestName, s.Test_Code AS SuggestCode, r.Reason, r.Is_Standard, r.IsActive,
                   (SELECT COUNT(*) FROM dbo.LabReflexRecommendation x WHERE x.Rule_ID = r.Rule_ID AND x.Status = 'A') AS Advised,
                   (SELECT COUNT(*) FROM dbo.LabReflexRecommendation x WHERE x.Rule_ID = r.Rule_ID AND x.Status = 'D') AS Dismissed
              FROM dbo.LabReflexRule r
              JOIN dbo.LabInvestigationMaster t ON t.Test_ID = r.Trigger_Test_ID
              JOIN dbo.LabInvestigationMaster s ON s.Test_ID = r.Suggest_Test_ID
             WHERE r.CompanyId = @companyId
             ORDER BY r.IsActive DESC, t.Test_Name, r.Rule_ID", new { companyId = User.GetCompanyId() })).ToList();
        return View(rows);
    }

    /// <summary>Tests and profiles for the rule pickers (Select2 search).</summary>
    [HttpGet]
    public async Task<IActionResult> Tests(string? term)
    {
        using var con = db.CreateConnection();
        var rows = await con.QueryAsync<(int Id, string Code, string Name, bool IsProfile)>(@"
            SELECT TOP 30 Test_ID, Test_Code, Test_Name, CAST(ISNULL(Is_Profile_Test, 0) AS bit)
              FROM dbo.LabInvestigationMaster
             WHERE CompanyId = @companyId AND Status = 1 AND ISNULL(IsDeleted, 0) = 0
               AND (@term IS NULL OR Test_Name LIKE '%' + @term + '%' OR Test_Code LIKE @term + '%')
             ORDER BY Test_Name", new { companyId = User.GetCompanyId(), term = string.IsNullOrWhiteSpace(term) ? null : term.Trim() });
        return Json(new { results = rows.Select(r => new { id = r.Id, text = $"{r.Code} - {r.Name}{(r.IsProfile ? " [Profile]" : "")}" }) });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Save([FromForm] RuleForm f)
    {
        var cond = f.ConditionType ?? "";
        var gender = f.Gender is "Male" or "Female" ? f.Gender : "All";
        string? error = null;
        if (f.TriggerTestId <= 0 || f.SuggestTestId <= 0) error = "Choose the result test and the test to suggest.";
        else if (f.TriggerTestId == f.SuggestTestId) error = "The suggested test must differ from the result test.";
        else if (!Conditions.ContainsKey(cond)) error = "Choose a condition.";
        else if (cond is "GT" or "GTE" or "LT" or "LTE" && f.Value1 is null) error = "Enter the value to compare with.";
        else if (cond is "BETWEEN" or "OUTSIDE" && (f.Value1 is null || f.Value2 is null || f.Value2 <= f.Value1)) error = "Enter a range: the second value must be above the first.";
        else if (cond == "TEXT" && string.IsNullOrWhiteSpace(f.TextValue)) error = "Enter the text the result must contain (e.g. Positive).";
        if (error is not null) return Json(new { success = false, message = error });

        var reason = string.IsNullOrWhiteSpace(f.Reason) ? null : f.Reason.Trim()[..Math.Min(250, f.Reason.Trim().Length)];
        var text = cond == "TEXT" ? f.TextValue!.Trim()[..Math.Min(100, f.TextValue.Trim().Length)] : null;
        decimal? v1 = cond is "GT" or "GTE" or "LT" or "LTE" or "BETWEEN" or "OUTSIDE" ? f.Value1 : null;
        decimal? v2 = cond is "BETWEEN" or "OUTSIDE" ? f.Value2 : null;

        using var con = db.CreateConnection();
        var companyId = User.GetCompanyId();
        var bothExist = await con.ExecuteScalarAsync<int>(@"SELECT COUNT(*) FROM dbo.LabInvestigationMaster
            WHERE CompanyId = @companyId AND Test_ID IN (@a, @b) AND ISNULL(IsDeleted, 0) = 0", new { companyId, a = f.TriggerTestId, b = f.SuggestTestId });
        if (bothExist < 2) return Json(new { success = false, message = "A chosen test is not in the investigation master." });

        if (f.RuleId > 0)
        {
            var n = await con.ExecuteAsync(@"
                UPDATE dbo.LabReflexRule SET Trigger_Test_ID = @TriggerTestId, Condition_Type = @cond, Value1 = @v1, Value2 = @v2, Text_Value = @text,
                       Gender = @gender, Suggest_Test_ID = @SuggestTestId, Reason = @reason, IsActive = @IsActive, ModifiedBy = @user, ModifiedDate = GETDATE()
                 WHERE Rule_ID = @RuleId AND CompanyId = @companyId",
                new { f.TriggerTestId, cond, v1, v2, text, gender, f.SuggestTestId, reason, f.IsActive, user = User.GetUserId(), f.RuleId, companyId });
            if (n == 0) return Json(new { success = false, message = "Rule not found." });
        }
        else
        {
            await con.ExecuteAsync(@"
                INSERT dbo.LabReflexRule (CompanyId, Trigger_Test_ID, Condition_Type, Value1, Value2, Text_Value, Gender, Suggest_Test_ID, Reason, Is_Standard, IsActive, CreatedBy)
                VALUES (@companyId, @TriggerTestId, @cond, @v1, @v2, @text, @gender, @SuggestTestId, @reason, 0, @IsActive, @user)",
                new { companyId, f.TriggerTestId, cond, v1, v2, text, gender, f.SuggestTestId, reason, f.IsActive, user = User.GetUserId() });
        }
        await auditLogService.LogAsync("LAB", "LAB.ReflexRule", $"Reflex rule {(f.RuleId > 0 ? "#" + f.RuleId + " updated" : "added")}: test {f.TriggerTestId} {cond} -> test {f.SuggestTestId}.");
        return Json(new { success = true });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Toggle(int id, bool active)
    {
        using var con = db.CreateConnection();
        var n = await con.ExecuteAsync(@"UPDATE dbo.LabReflexRule SET IsActive = @active, ModifiedBy = @user, ModifiedDate = GETDATE()
                                         WHERE Rule_ID = @id AND CompanyId = @companyId", new { active, user = User.GetUserId(), id, companyId = User.GetCompanyId() });
        if (n == 0) return Json(new { success = false, message = "Rule not found." });
        await auditLogService.LogAsync("LAB", "LAB.ReflexRule", $"Reflex rule #{id} switched {(active ? "on" : "off")}.");
        return Json(new { success = true });
    }
}
