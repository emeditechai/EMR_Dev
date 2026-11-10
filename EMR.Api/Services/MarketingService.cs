using System.Data;
using System.Text.Json;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IMarketingService
{
    Task<object?> AppModeAsync(int userId);
    Task<string> GuardAsync(MarketingCaller c);
    Task<string> RegisterDeviceAsync(MarketingCaller c, PhleboDeviceRequest r);
    Task<object?> SessionAsync(MarketingCaller c);
    Task<object> BranchesAsync(MarketingCaller c);
    Task<object> SpecialitiesAsync(MarketingCaller c);
    Task<object?> SummaryAsync(MarketingCaller c);
    Task<object> LeadsAsync(MarketingCaller c, string? stage, string? search);
    Task<object> LeadAsync(MarketingCaller c, int id);
    Task<int> SaveLeadAsync(MarketingCaller c, int? id, MarketingLeadRequest r);
    Task SetPinAsync(MarketingCaller c, int id, MarketingPinRequest r);
    Task<string> SetStageAsync(MarketingCaller c, int id, MarketingStageRequest r);
    Task<object?> PromoteAsync(MarketingCaller c, int id, MarketingPromoteRequest r);
    Task<object?> CreateVisitAsync(MarketingCaller c, int id, MarketingVisitRequest r);
    Task<object?> FieldDayAsync(MarketingCaller c, MarketingFieldDayRequest r);
    Task<int> SaveLocationAsync(MarketingCaller c, IReadOnlyList<PhleboLocationPoint> points);
}

/// <summary>Marketing executive app (SQLScripts/2446). The rules live in the usp_Mkt_* procedures.</summary>
public sealed class MarketingService(IDbConnectionFactory db) : IMarketingService
{
    private const CommandType Sp = CommandType.StoredProcedure;

    public async Task<object?> AppModeAsync(int userId)
    {
        using var con = db.CreateConnection();
        return Camel(await con.QueryFirstOrDefaultAsync("dbo.usp_Mkt_AppMode", new { UserId = userId }, commandType: Sp));
    }

    public async Task<string> GuardAsync(MarketingCaller c)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleAsync<string>("dbo.usp_Mkt_Guard", new { c.UserId, c.DeviceId }, commandType: Sp);
    }

    // the same phone approval as the phlebotomist app
    public async Task<string> RegisterDeviceAsync(MarketingCaller c, PhleboDeviceRequest r)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleAsync<string>("dbo.usp_Phlebo_Device_Register",
            new { c.UserId, c.CompanyId, c.DeviceId, r.DeviceName, r.Platform, r.AppVersion }, commandType: Sp);
    }

    public async Task<object?> SessionAsync(MarketingCaller c)
    {
        using var con = db.CreateConnection();
        return Camel(await con.QueryFirstOrDefaultAsync("dbo.usp_Mkt_Session_Get", new { c.UserId, c.CompanyId, c.BranchId, c.DeviceId }, commandType: Sp));
    }

    public async Task<object> BranchesAsync(MarketingCaller c)
    {
        using var con = db.CreateConnection();
        return Camel(await con.QueryAsync("dbo.usp_Mkt_Branches", new { c.UserId }, commandType: Sp));
    }

    public async Task<object> SpecialitiesAsync(MarketingCaller c)
    {
        using var con = db.CreateConnection();
        return Camel(await con.QueryAsync("dbo.usp_Mkt_Specialities", new { c.CompanyId }, commandType: Sp));
    }

    public async Task<object?> SummaryAsync(MarketingCaller c)
    {
        using var con = db.CreateConnection();
        return Camel(await con.QueryFirstOrDefaultAsync("dbo.usp_Mkt_Summary", new { c.UserId, c.CompanyId, c.BranchId }, commandType: Sp));
    }

    public async Task<object> LeadsAsync(MarketingCaller c, string? stage, string? search)
    {
        using var con = db.CreateConnection();
        return Camel(await con.QueryAsync("dbo.usp_Mkt_Lead_List", new { c.UserId, c.CompanyId, c.BranchId, Stage = stage, Search = search }, commandType: Sp));
    }

    public async Task<object> LeadAsync(MarketingCaller c, int id)
    {
        using var con = db.CreateConnection();
        using var grid = await con.QueryMultipleAsync("dbo.usp_Mkt_Lead_Get", new { c.UserId, c.CompanyId, ForecastDoctorId = id }, commandType: Sp);
        var lead = Camel(await grid.ReadFirstOrDefaultAsync());
        var visits = Camel(await grid.ReadAsync());
        var stages = Camel(await grid.ReadAsync());
        return new { lead, visits, stages };
    }

    public async Task<int> SaveLeadAsync(MarketingCaller c, int? id, MarketingLeadRequest r)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleAsync<int>("dbo.usp_Mkt_Lead_Save",
            new { c.UserId, c.CompanyId, c.BranchId, ForecastDoctorId = id, r.NamePrefix, r.FullName, r.PhoneNumber, r.PrimarySpecialityId,
                  r.ClinicName, r.Address, r.ExpectedMonthlyReferrals, NextFollowUpDate = r.NextFollowUpDate?.Date, r.Remarks,
                  Latitude = id is null ? r.Latitude : null, Longitude = id is null ? r.Longitude : null },
            commandType: Sp);
    }

    public async Task SetPinAsync(MarketingCaller c, int id, MarketingPinRequest r)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("dbo.usp_Mkt_Lead_SetPin",
            new { c.UserId, c.CompanyId, ForecastDoctorId = id, r.Latitude, r.Longitude, r.AccuracyM, r.IsMock }, commandType: Sp);
    }

    public async Task<string> SetStageAsync(MarketingCaller c, int id, MarketingStageRequest r)
    {
        using var con = db.CreateConnection();
        return await con.QuerySingleAsync<string>("dbo.usp_Mkt_Lead_Stage",
            new { c.UserId, c.CompanyId, ForecastDoctorId = id, r.Stage, r.Reason }, commandType: Sp);
    }

    public async Task<object?> PromoteAsync(MarketingCaller c, int id, MarketingPromoteRequest r)
    {
        using var con = db.CreateConnection();
        return Camel(await con.QueryFirstOrDefaultAsync("dbo.usp_Mkt_Lead_Promote",
            new { c.UserId, c.CompanyId, c.BranchId, ForecastDoctorId = id, r.Gender, r.EmailId, r.PrimarySpecialityId, r.MedicalLicenseNo,
                  DateOfBirth = r.DateOfBirth?.Date },
            commandType: Sp));
    }

    public async Task<object?> CreateVisitAsync(MarketingCaller c, int id, MarketingVisitRequest r)
    {
        using var con = db.CreateConnection();
        return Camel(await con.QueryFirstOrDefaultAsync("dbo.usp_Mkt_Visit_Create",
            new { c.UserId, c.CompanyId, c.BranchId, ForecastDoctorId = id, r.ClientEventId, r.DeviceTime, r.Latitude, r.Longitude, r.AccuracyM,
                  r.IsMock, r.Outcome, r.Notes, NextFollowUpDate = r.NextFollowUpDate?.Date },
            commandType: Sp));
    }

    public async Task<object?> FieldDayAsync(MarketingCaller c, MarketingFieldDayRequest r)
    {
        using var con = db.CreateConnection();
        return Camel(await con.QueryFirstOrDefaultAsync("dbo.usp_Mkt_FieldDay",
            new { c.UserId, c.CompanyId, c.BranchId, Action = r.Action?.ToUpperInvariant(), r.Latitude, r.Longitude }, commandType: Sp));
    }

    public async Task<int> SaveLocationAsync(MarketingCaller c, IReadOnlyList<PhleboLocationPoint> points)
    {
        var json = JsonSerializer.Serialize(points.Select(p => new
        {
            time = p.Time.ToString("yyyy-MM-ddTHH:mm:ss"), lat = p.Lat, lng = p.Lng, accuracy = p.Accuracy, speed = p.Speed, mock = p.Mock
        }));
        using var con = db.CreateConnection();
        return await con.QuerySingleAsync<int>("dbo.usp_Mkt_Location_Batch", new { c.UserId, Json = json }, commandType: Sp);
    }

    private static Dictionary<string, object?>? Camel(dynamic? row)
    {
        if (row is not IDictionary<string, object?> values) return null;
        return values.ToDictionary(k => JsonNamingPolicy.CamelCase.ConvertName(k.Key), k => k.Value);
    }

    private static List<Dictionary<string, object?>?> Camel(IEnumerable<dynamic> rows) => rows.Select(r => (Dictionary<string, object?>?)Camel(r)).ToList();
}
