using System.Net.Http.Json;
using System.Text.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

/// <summary>EMR.Api api/lab-serial-no (SQLScripts/2514): the Lab Serial No of a lab order on one report entry page.</summary>
public class LabSerialNoApiClient(IHttpClientFactory factory)
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    /// <summary>Report types: LAB (Lab Report Entry), IMAGE (Lab Image Reporting), MICRO (Microbiology Report Entry).</summary>
    public const string Lab = "LAB", Image = "IMAGE", Micro = "MICRO";

    public sealed record SerialInfo(bool Required, string? LabSerialNo);

    /// <summary>Required (branch setting) and the stored serial; a failed call reads as not required.</summary>
    public async Task<SerialInfo> GetAsync(int labOrderId, string reportType, int branchId)
    {
        try
        {
            using var res = await factory.CreateClient("EmrApi").GetAsync("api/lab-serial-no" + IpdApiClient.Q(("labOrderId", labOrderId), ("reportType", reportType), ("branchId", branchId)));
            var body = await res.Content.ReadFromJsonAsync<ApiResponse<JsonElement>>(Json);
            if (!res.IsSuccessStatusCode || body is not { Success: true } || body.Data.ValueKind != JsonValueKind.Object) return new(false, null);
            var d = body.Data;
            var req = d.TryGetProperty("required", out var r) ? r : d.TryGetProperty("Required", out var r2) ? r2 : default;
            var sn = d.TryGetProperty("labSerialNo", out var s) ? s : d.TryGetProperty("LabSerialNo", out var s2) ? s2 : default;
            return new(req.ValueKind == JsonValueKind.True, sn.ValueKind == JsonValueKind.String ? sn.GetString() : null);
        }
        catch { return new(false, null); }
    }

    /// <summary>Stores it; returns null when saved, else the reason (e.g. "Enter the Lab Serial No.").</summary>
    public async Task<string?> SaveAsync(int labOrderId, string reportType, int branchId, string? labSerialNo)
    {
        using var res = await factory.CreateClient("EmrApi").PostAsJsonAsync("api/lab-serial-no",
            new { LabOrderId = labOrderId, ReportType = reportType, BranchId = branchId, LabSerialNo = labSerialNo });
        ApiResponse<JsonElement>? body = null;
        try { body = await res.Content.ReadFromJsonAsync<ApiResponse<JsonElement>>(Json); } catch (JsonException) { }
        return res.IsSuccessStatusCode && body is { Success: true } ? null
            : body?.Message is { Length: > 0 } m ? m : $"The Lab Serial No was not saved ({(int)res.StatusCode}).";
    }
}
