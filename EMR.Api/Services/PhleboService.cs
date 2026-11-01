using System.Data;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

/// <summary>Phlebotomist app (SQLScripts/2373, 2374). The rules live in the usp_Phlebo_* procedures.</summary>
public sealed class PhleboService(
    IDbConnectionFactory db,
    IConfiguration configuration,
    IWebHostEnvironment environment,
    IWhatsAppTextSender whatsApp,
    ILogger<PhleboService> logger) : IPhleboService
{
    private static readonly HashSet<string> VisitDocTypes = new(StringComparer.OrdinalIgnoreCase) { "PRESCRIPTION", "CONSENT", "ID_PROOF", "SIGNATURE" };
    private static readonly HashSet<string> DutyDocTypes = new(StringComparer.OrdinalIgnoreCase) { "SELFIE", "VEHICLE", "BAG", "TEMP_GUN", "ODOMETER" };
    private static readonly Dictionary<string, string> ImageTypes = new(StringComparer.OrdinalIgnoreCase) { ["image/jpeg"] = ".jpg", ["image/png"] = ".png" };
    private const long MaxFileBytes = 8 * 1024 * 1024;
    private static readonly TimeSpan OtpLife = TimeSpan.FromMinutes(10);

    public async Task<string> GuardAsync(PhleboCaller c)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleAsync<string>("dbo.usp_Phlebo_Guard", new { c.UserId, c.DeviceId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<string> RegisterDeviceAsync(PhleboCaller c, PhleboDeviceRequest r)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleAsync<string>("dbo.usp_Phlebo_Device_Register",
            new { c.UserId, c.CompanyId, c.DeviceId, r.DeviceName, r.Platform, r.AppVersion }, commandType: CommandType.StoredProcedure);
    }

    public async Task<object?> SessionAsync(PhleboCaller c)
    {
        using var con = db.CreateConnection();
        using var grid = await con.QueryMultipleAsync("dbo.usp_Phlebo_Session_Get", new { c.UserId, c.CompanyId, c.DeviceId }, commandType: CommandType.StoredProcedure);
        var profile = Camel(await grid.ReadFirstOrDefaultAsync());
        return new { profile, photosTaken = (await grid.ReadAsync<string>()).ToList() };
    }

    public async Task<object?> PunchAsync(PhleboCaller c, PhleboPunchRequest r)
    {
        using var con = db.CreateConnection();
        return Camel(await con.QueryFirstOrDefaultAsync("dbo.usp_Phlebo_Attendance_Punch",
            new { c.UserId, c.CompanyId, c.BranchId, r.PunchType, r.ClientEventId, c.DeviceId, r.DeviceTime, r.Latitude, r.Longitude, r.AccuracyM, r.IsMock,
                  r.Temperature, r.FieldStart, r.Reason },
            commandType: CommandType.StoredProcedure));
    }

    public async Task<int> SaveLocationAsync(PhleboCaller c, IReadOnlyList<PhleboLocationPoint> points)
    {
        var json = JsonSerializer.Serialize(points.Select(p => new
        {
            time = p.Time.ToString("yyyy-MM-ddTHH:mm:ss"), lat = p.Lat, lng = p.Lng, accuracy = p.Accuracy, speed = p.Speed, mock = p.Mock
        }));
        using var con = db.CreateConnection();
        return await con.QuerySingleAsync<int>("dbo.usp_Phlebo_Location_Batch", new { c.UserId, Json = json }, commandType: CommandType.StoredProcedure);
    }

    public async Task<int> SaveDocumentAsync(PhleboCaller c, int? visitId, string docType, IFormFile file, string? remarks)
    {
        if (!(visitId is null ? DutyDocTypes : VisitDocTypes).Contains(docType)) throw new PhleboRuleException("This kind of photo is not accepted here.");
        if (file.Length <= 0 || file.Length > MaxFileBytes) throw new PhleboRuleException("The photo must be under 8 MB.");
        if (!ImageTypes.TryGetValue(file.ContentType ?? "", out var extension)) throw new PhleboRuleException("Only JPEG or PNG photos are accepted.");

        var root = configuration["PhleboApp:UploadRoot"];
        if (string.IsNullOrWhiteSpace(root)) root = Path.Combine(environment.ContentRootPath, "App_Data", "PhleboUploads");
        var relative = Path.Combine(DateTime.Now.ToString("yyyy"), DateTime.Now.ToString("MM"), $"{Guid.NewGuid():N}{extension}");
        var full = Path.Combine(root, relative);
        Directory.CreateDirectory(Path.GetDirectoryName(full)!);
        await using (var stream = File.Create(full)) await file.CopyToAsync(stream);

        try
        {
            using var con = db.CreateConnection();
            return await con.QuerySingleAsync<int>("dbo.usp_Phlebo_Document_Save",
                new { c.UserId, c.CompanyId, c.BranchId, VisitId = visitId, DocType = docType.ToUpperInvariant(), FileName = Path.GetFileName(full),
                      FilePath = relative, file.ContentType, FileSize = file.Length, Remarks = remarks },
                commandType: CommandType.StoredProcedure);
        }
        catch
        {
            File.Delete(full);
            throw;
        }
    }

    public async Task<object> VisitsAsync(PhleboCaller c, DateTime? date)
    {
        using var con = db.CreateConnection();
        return Camel(await con.QueryAsync("dbo.usp_Phlebo_Visit_List", new { c.UserId, Date = date?.Date }, commandType: CommandType.StoredProcedure));
    }

    public async Task<object?> VisitAsync(PhleboCaller c, int visitId)
    {
        using var con = db.CreateConnection();
        using var grid = await con.QueryMultipleAsync("dbo.usp_Phlebo_Visit_Get", new { c.UserId, VisitId = visitId }, commandType: CommandType.StoredProcedure);
        var visit = Camel(await grid.ReadFirstOrDefaultAsync());
        var tubes = Camel(await grid.ReadAsync());
        var events = Camel(await grid.ReadAsync());
        var rejectionReasons = Camel(await grid.ReadAsync());
        var documents = Camel(await grid.ReadAsync());
        var charges = Camel(await grid.ReadAsync());
        return new { visit, tubes, events, rejectionReasons, documents, charges };
    }

    public async Task<object?> VisitEventAsync(PhleboCaller c, int visitId, PhleboEventRequest r)
    {
        using var con = db.CreateConnection();
        return Camel(await con.QueryFirstOrDefaultAsync("dbo.usp_Phlebo_Visit_Event",
            new { c.UserId, VisitId = visitId, r.Status, r.ClientEventId, r.DeviceTime, r.Latitude, r.Longitude, r.AccuracyM, r.IsMock, r.Reason },
            commandType: CommandType.StoredProcedure));
    }

    public async Task SendOtpAsync(PhleboCaller c, int visitId)
    {
        var code = RandomNumberGenerator.GetInt32(1000, 10000).ToString();
        using var con = db.CreateConnection();
        var to = await con.QueryFirstOrDefaultAsync<OtpTarget>("dbo.usp_Phlebo_Otp_Save",
            new { c.UserId, VisitId = visitId, OtpHash = HashOtp(visitId, code), Expires = DateTime.Now.Add(OtpLife) }, commandType: CommandType.StoredProcedure);
        if (to is null) throw new PhleboRuleException("The patient has no mobile number.");

        var result = await whatsApp.SendAsync(to.BranchId, to.PhoneNumber,
            $"Dear {to.FirstName}, your home sample collection code is {code}. Share it with the phlebotomist at your door. It is valid for {OtpLife.TotalMinutes:0} minutes.");
        if (result == WhatsAppSendResult.NotConfigured)
            throw new PhleboRuleException("WhatsApp is not set up for this branch. Use the patient's ID proof instead.");
        if (result == WhatsAppSendResult.Failed)
        {
            logger.LogWarning("[PHLEBO] OTP not sent for visit {VisitId}", visitId);
            throw new PhleboRuleException("The code could not be sent. Try again, or use the patient's ID proof.");
        }
    }

    public async Task VerifyAsync(PhleboCaller c, int visitId, PhleboVerifyRequest r)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("dbo.usp_Phlebo_Otp_Verify",
            new { c.UserId, VisitId = visitId, OtpHash = r.Action == "CHECK" ? HashOtp(visitId, r.Code ?? "") : null, r.Reason },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<object?> SamplesAsync(PhleboCaller c, int visitId, PhleboSamplesRequest r)
    {
        var tubes = JsonSerializer.Serialize(r.Tubes.Select(t => new
        {
            sampleCollectionId = t.SampleCollectionId, collected = t.Collected, barcode = t.Barcode, reasonId = t.ReasonId, remarks = t.Remarks
        }));
        using var con = db.CreateConnection();
        return Camel(await con.QueryFirstOrDefaultAsync("dbo.usp_Phlebo_Visit_Samples",
            new { c.UserId, VisitId = visitId, r.ClientEventId, TubesJson = tubes, r.DeviceTime, r.Latitude, r.Longitude, r.AccuracyM, r.IsMock, r.DueReason },
            commandType: CommandType.StoredProcedure));
    }

    public async Task<object?> PaymentAsync(PhleboCaller c, int visitId, PhleboPaymentRequest r)
    {
        using var con = db.CreateConnection();
        return Camel(await con.QueryFirstOrDefaultAsync("dbo.usp_Phlebo_Visit_Payment",
            new { c.UserId, VisitId = visitId, r.ClientEventId, r.MethodCode, r.Amount, r.Reference }, commandType: CommandType.StoredProcedure));
    }

    public async Task<object> SearchTestsAsync(PhleboCaller c, int visitId, string search)
    {
        using var con = db.CreateConnection();
        return Camel(await con.QueryAsync("dbo.usp_Phlebo_Test_Search", new { c.UserId, VisitId = visitId, Search = search }, commandType: CommandType.StoredProcedure));
    }

    public async Task<object?> CreateBillChangeAsync(PhleboCaller c, PhleboBillChangeRequest r)
    {
        var lines = JsonSerializer.Serialize(r.Lines.Select(l => new { action = l.Action, investigationId = l.InvestigationId }));
        using var con = db.CreateConnection();
        using var grid = await con.QueryMultipleAsync("dbo.usp_Phlebo_BillChange_Create",
            new { c.UserId, r.VisitId, r.ClientEventId, r.RequestType, r.Reason, r.Details, LinesJson = lines }, commandType: CommandType.StoredProcedure);
        // with approval off the bill is changed here, and those procedures return result sets first (SQLScripts/2382)
        dynamic? result = null;
        while (!grid.IsConsumed) result = (await grid.ReadAsync()).LastOrDefault();
        return Camel(result);
    }

    public async Task<object> BillChangesAsync(PhleboCaller c, int? visitId)
    {
        using var con = db.CreateConnection();
        return Camel(await con.QueryAsync("dbo.usp_Phlebo_BillChange_List", new { c.UserId, VisitId = visitId }, commandType: CommandType.StoredProcedure));
    }

    public async Task<object?> HandoverAsync(PhleboCaller c, PhleboHandoverRequest r)
    {
        using var con = db.CreateConnection();
        return Camel(await con.QueryFirstOrDefaultAsync("dbo.usp_Phlebo_Handover_Create",
            new { c.UserId, c.CompanyId, c.BranchId, r.ClientEventId, r.ReceiverName, r.TemperatureC, VisitIdsJson = JsonSerializer.Serialize(r.VisitIds) },
            commandType: CommandType.StoredProcedure));
    }

    public async Task<object?> SummaryAsync(PhleboCaller c)
    {
        using var con = db.CreateConnection();
        return Camel(await con.QueryFirstOrDefaultAsync("dbo.usp_Phlebo_Summary", new { c.UserId }, commandType: CommandType.StoredProcedure));
    }

    private static string HashOtp(int visitId, string code) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes($"{visitId}:{code.Trim()}"))).ToLowerInvariant();

    private static Dictionary<string, object?>? Camel(dynamic? row)
    {
        if (row is not IDictionary<string, object?> values) return null;
        return values.ToDictionary(k => JsonNamingPolicy.CamelCase.ConvertName(k.Key), k => k.Value);
    }

    private static List<Dictionary<string, object?>?> Camel(IEnumerable<dynamic> rows) => rows.Select(r => (Dictionary<string, object?>?)Camel(r)).ToList();

    private sealed record OtpTarget(int BranchId, string? PhoneNumber, string? FirstName);
}

/// <summary>A rule refused in the API itself; shown to the phlebotomist like a message from the procedures.</summary>
public sealed class PhleboRuleException(string message) : Exception(message);
