using System.Globalization;
using System.Text.RegularExpressions;
using Dapper;
using EMR.Web.Data;

namespace EMR.Web.Services.Reflex;

/// <summary>A follow-up test a result calls for, on one order.</summary>
public sealed record ReflexSuggestion(
    int RuleId, int TriggerTestId, string TriggerTestName, string TriggerValue, string? TriggerFlag,
    int SuggestTestId, string SuggestTestCode, string SuggestTestName, string? Reason,
    string Status,              // "new" = to decide, "A" = advised, "D" = dismissed
    string? ActionByName, DateTime? ActionDate);

/// <summary>A test the pathologist advised for a patient and that has not been billed since.</summary>
public sealed record ReflexAdvice(
    int RecommendationId, int LabOrderId, string? BillNo, int SuggestTestId, string SuggestTestCode, string SuggestTestName,
    string TriggerTestName, string? TriggerValue, string? Reason, string? AdvisedBy, DateTime AdvisedOn);

public interface ILabReflexService
{
    /// <summary>Reflex suggestions for an order, from its results entered so far (Entered, Validated, Approved).</summary>
    Task<IReadOnlyList<ReflexSuggestion>> GetSuggestionsAsync(int companyId, int labOrderId);

    /// <summary>Records the pathologist's decision: A = advise the follow-up test, D = dismiss. Returns an error or null.</summary>
    Task<string?> RecordAsync(int companyId, int branchId, int userId, int labOrderId, int ruleId, char status, string? note);

    /// <summary>Follow-up tests advised for a patient in the last 90 days that no later bill of theirs contains yet.</summary>
    Task<IReadOnlyList<ReflexAdvice>> GetOpenAdviceAsync(int companyId, int patientId);
}

/// <summary>
/// Reflex testing: rules in dbo.LabReflexRule (Master > Lab Master > Reflex Rules) are checked against the results of an
/// order; the pathologist advises or dismisses what they suggest (dbo.LabReflexRecommendation). An advice changes
/// nothing on the bill, the order or the report - the front desk sees it when the patient is next billed.
/// A test already on the order (alone or inside a profile / package) is never suggested.
/// </summary>
public sealed class LabReflexService(IDbConnectionFactory db) : ILabReflexService
{
    private sealed class Rule
    {
        public int Rule_ID { get; set; }
        public int Trigger_Test_ID { get; set; }
        public string Condition_Type { get; set; } = "";
        public decimal? Value1 { get; set; }
        public decimal? Value2 { get; set; }
        public string? Text_Value { get; set; }
        public string Gender { get; set; } = "All";
        public int Suggest_Test_ID { get; set; }
        public string? Reason { get; set; }
        public string SuggestCode { get; set; } = "";
        public string SuggestName { get; set; } = "";
    }

    private sealed class Result
    {
        public int InvestigationID { get; set; }
        public string? TestValue { get; set; }
        public string? AbnormalFlag { get; set; }
        public string TestName { get; set; } = "";
    }

    public async Task<IReadOnlyList<ReflexSuggestion>> GetSuggestionsAsync(int companyId, int labOrderId)
    {
        using var con = db.CreateConnection();
        using var grid = await con.QueryMultipleAsync(@"
            -- results entered so far (a draft is not a result yet)
            SELECT led.InvestigationID, led.TestValue, led.AbnormalFlag, m.Test_Name AS TestName
              FROM dbo.labentrydetails led
              JOIN dbo.LabInvestigationMaster m ON m.Test_ID = led.InvestigationID
             WHERE led.LabOrderId = @labOrderId AND led.IsActive = 1 AND led.ReportStatusId >= 2
               AND NULLIF(LTRIM(RTRIM(led.TestValue)), '') IS NOT NULL;

            SELECT p.Gender FROM dbo.LabOrder o JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId WHERE o.LabOrderId = @labOrderId;

            -- every test on the order: billed tests, the tests of billed profiles and packages (one level of nesting)
            ;WITH billed AS (
                SELECT i.Type, i.InvestigationId FROM dbo.LabOrderItem i WHERE i.LabOrderId = @labOrderId AND i.IsActive = 1),
            inside AS (
                SELECT d.Test_ID FROM billed b
                  JOIN dbo.LabInvestigationProfileHeader h ON (b.Type = 'P' AND h.Profile_ID = b.InvestigationId) OR (b.Type = 'I' AND h.Test_ID = b.InvestigationId)
                  JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = h.Profile_ID AND ISNULL(d.IsDeleted, 0) = 0)
            SELECT InvestigationId FROM billed WHERE Type = 'I'
            UNION SELECT Test_ID FROM inside
            UNION SELECT d2.Test_ID FROM inside x
                    JOIN dbo.LabInvestigationProfileHeader h2 ON h2.Test_ID = x.Test_ID
                    JOIN dbo.LabInvestigationProfileDetail d2 ON d2.Profile_ID = h2.Profile_ID AND ISNULL(d2.IsDeleted, 0) = 0;

            SELECT r.Rule_ID, r.Trigger_Test_ID, r.Condition_Type, r.Value1, r.Value2, r.Text_Value, r.Gender, r.Suggest_Test_ID, r.Reason,
                   s.Test_Code AS SuggestCode, s.Test_Name AS SuggestName
              FROM dbo.LabReflexRule r
              JOIN dbo.LabInvestigationMaster s ON s.Test_ID = r.Suggest_Test_ID AND s.Status = 1 AND ISNULL(s.IsDeleted, 0) = 0
             WHERE r.CompanyId = @companyId AND r.IsActive = 1
               AND r.Trigger_Test_ID IN (SELECT InvestigationID FROM dbo.labentrydetails WHERE LabOrderId = @labOrderId AND IsActive = 1);

            SELECT x.Rule_ID, x.Status, x.ActionDate, COALESCE(NULLIF(u.FullName, ''), u.Username) AS ActionByName
              FROM dbo.LabReflexRecommendation x LEFT JOIN dbo.Users u ON u.Id = x.ActionBy
             WHERE x.LabOrderId = @labOrderId;",
            new { companyId, labOrderId });

        var results = (await grid.ReadAsync<Result>()).GroupBy(r => r.InvestigationID).ToDictionary(g => g.Key, g => g.First());
        var gender = (await grid.ReadFirstOrDefaultAsync<string?>())?.Trim();
        var onOrder = (await grid.ReadAsync<int>()).ToHashSet();
        var rules = (await grid.ReadAsync<Rule>()).ToList();
        var decided = (await grid.ReadAsync<(int Rule_ID, string Status, DateTime ActionDate, string? ActionByName)>()).ToDictionary(x => x.Rule_ID);

        var list = new List<ReflexSuggestion>();
        foreach (var rule in rules)
        {
            if (!results.TryGetValue(rule.Trigger_Test_ID, out var res)) continue;
            if (rule.Gender != "All" && !string.Equals(rule.Gender, gender, StringComparison.OrdinalIgnoreCase)) continue;
            var hasDecision = decided.TryGetValue(rule.Rule_ID, out var d);
            // already on the order: nothing to suggest (an earlier decision is still shown)
            if (!hasDecision && onOrder.Contains(rule.Suggest_Test_ID)) continue;
            if (!hasDecision && !Matches(rule, res)) continue;
            list.Add(new ReflexSuggestion(rule.Rule_ID, rule.Trigger_Test_ID, res.TestName, res.TestValue ?? "", res.AbnormalFlag,
                rule.Suggest_Test_ID, rule.SuggestCode, rule.SuggestName, rule.Reason,
                hasDecision ? d.Status : "new", hasDecision ? d.ActionByName : null, hasDecision ? d.ActionDate : null));
        }
        // one line per suggested test: a test advised by two rules is decided once
        return list.GroupBy(s => s.SuggestTestId).Select(g => g.OrderBy(s => s.Status == "new" ? 1 : 0).First()).ToList();
    }

    private static bool Matches(Rule r, Result res)
    {
        var flag = (res.AbnormalFlag ?? "").Trim().ToUpperInvariant();
        switch (r.Condition_Type)
        {
            // flags as Result Entry sets them; a Critical / Panic flag has no direction, so only "abnormal" rules use it
            case "FLAG_H": return flag is "H" or "HH" or "HIGH";
            case "FLAG_L": return flag is "L" or "LL" or "LOW";
            case "FLAG_ABN": return flag is not ("" or "NORMAL" or "N");
            case "TEXT": return !string.IsNullOrWhiteSpace(r.Text_Value)
                                && (res.TestValue ?? "").Contains(r.Text_Value.Trim(), StringComparison.OrdinalIgnoreCase);
        }
        if (!TryNumber(res.TestValue, out var v) || r.Value1 is not decimal a) return false;
        return r.Condition_Type switch
        {
            "GT" => v > a,
            "GTE" => v >= a,
            "LT" => v < a,
            "LTE" => v <= a,
            "BETWEEN" => r.Value2 is decimal b && v >= a && v <= b,
            "OUTSIDE" => r.Value2 is decimal b2 && (v < a || v > b2),
            _ => false
        };
    }

    /// <summary>The number in a result as typed ("8.2", " 126 mg/dL", "&gt;100" - comparison signs are dropped).</summary>
    private static bool TryNumber(string? text, out decimal value)
    {
        value = 0;
        var m = Regex.Match(text ?? "", @"-?\d+(?:\.\d+)?");
        return m.Success && decimal.TryParse(m.Value, NumberStyles.Number, CultureInfo.InvariantCulture, out value);
    }

    public async Task<string?> RecordAsync(int companyId, int branchId, int userId, int labOrderId, int ruleId, char status, string? note)
    {
        var current = (await GetSuggestionsAsync(companyId, labOrderId)).FirstOrDefault(s => s.RuleId == ruleId);
        if (current is null) return "This suggestion no longer applies to the order (results changed, or the test is already on it).";

        using var con = db.CreateConnection();
        var patientId = await con.ExecuteScalarAsync<int>("SELECT PatientId FROM dbo.LabOrder WHERE LabOrderId = @labOrderId", new { labOrderId });
        // one decision per rule and order; a later click changes it (advised <-> dismissed)
        await con.ExecuteAsync(@"
            MERGE dbo.LabReflexRecommendation AS t
            USING (SELECT @labOrderId AS LabOrderId, @ruleId AS Rule_ID) AS s ON t.LabOrderId = s.LabOrderId AND t.Rule_ID = s.Rule_ID
            WHEN MATCHED THEN UPDATE SET Status = @status, Note = @note, ActionBy = @userId, ActionDate = GETDATE(), Trigger_Value = @value
            WHEN NOT MATCHED THEN INSERT (CompanyId, BranchId, LabOrderId, PatientId, Rule_ID, Trigger_Test_ID, Trigger_Value, Suggest_Test_ID, Status, Note, ActionBy)
                 VALUES (@companyId, @branchId, @labOrderId, @patientId, @ruleId, @trigger, @value, @suggest, @status, @note, @userId);",
            new
            {
                companyId, branchId, labOrderId, patientId, ruleId, status = status.ToString(), note = string.IsNullOrWhiteSpace(note) ? null : note.Trim(),
                userId, trigger = current.TriggerTestId, value = current.TriggerValue.Length > 100 ? current.TriggerValue[..100] : current.TriggerValue,
                suggest = current.SuggestTestId
            });
        return null;
    }

    public async Task<IReadOnlyList<ReflexAdvice>> GetOpenAdviceAsync(int companyId, int patientId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<ReflexAdvice>(@"
            SELECT x.Recommendation_ID AS RecommendationId, x.LabOrderId, o.BillNo, x.Suggest_Test_ID AS SuggestTestId,
                   s.Test_Code AS SuggestTestCode, s.Test_Name AS SuggestTestName, t.Test_Name AS TriggerTestName,
                   x.Trigger_Value AS TriggerValue, r.Reason, COALESCE(NULLIF(u.FullName, ''), u.Username) AS AdvisedBy, x.ActionDate AS AdvisedOn
              FROM dbo.LabReflexRecommendation x
              JOIN dbo.LabOrder o ON o.LabOrderId = x.LabOrderId
              JOIN dbo.LabInvestigationMaster s ON s.Test_ID = x.Suggest_Test_ID
              JOIN dbo.LabInvestigationMaster t ON t.Test_ID = x.Trigger_Test_ID
              LEFT JOIN dbo.LabReflexRule r ON r.Rule_ID = x.Rule_ID
              LEFT JOIN dbo.Users u ON u.Id = x.ActionBy
             WHERE x.CompanyId = @companyId AND x.PatientId = @patientId AND x.Status = 'A' AND o.IsActive = 1   -- not from a cancelled bill
               AND x.ActionDate >= DATEADD(DAY, -90, GETDATE())
               -- not billed since: no later active order of the patient carries the test (alone or in a profile / package)
               AND NOT EXISTS (
                    SELECT 1 FROM dbo.LabOrder o2
                      JOIN dbo.LabOrderItem i2 ON i2.LabOrderId = o2.LabOrderId AND i2.IsActive = 1
                     WHERE o2.PatientId = x.PatientId AND o2.IsActive = 1 AND o2.LabOrderId <> x.LabOrderId AND o2.OrderDate >= o.OrderDate
                       AND ((i2.Type = 'I' AND i2.InvestigationId = x.Suggest_Test_ID)
                            OR EXISTS (SELECT 1 FROM dbo.LabInvestigationProfileHeader h
                                         JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = h.Profile_ID AND ISNULL(d.IsDeleted, 0) = 0
                                        WHERE d.Test_ID = x.Suggest_Test_ID
                                          AND ((i2.Type = 'P' AND h.Profile_ID = i2.InvestigationId) OR (i2.Type = 'I' AND h.Test_ID = i2.InvestigationId)))))
             ORDER BY x.ActionDate DESC", new { companyId, patientId })).ToList();
    }
}
