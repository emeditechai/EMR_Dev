using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Claims;
using EMR.Shared.Security;
using Microsoft.Extensions.Options;

namespace EMR.Web.ApiClients;

/// <summary>
/// Signs every call to EMR.Api (the "EmrApi" client only - never a third-party one) with a Bearer token:
///   - a signed-in staff user        -> an access token from api/auth/web-token (ApiAuth:AccessTokenMinutes on EMR.Api),
///                                      kept in the user's session and renewed shortly before it expires or when the
///                                      branch / role changes; a 401 drops it and the call is retried once with a new one;
///   - the patient portal            -> a service token naming the portal patient (HttpContext.Items[PatientIdItem]);
///   - no user (start-up, jobs)      -> a service token.
/// </summary>
public sealed class EmrApiTokenHandler(
    IHttpContextAccessor httpContextAccessor,
    IApiTokenService tokens,
    IOptionsMonitor<ApiAuthOptions> options,
    IConfiguration configuration,
    ILogger<EmrApiTokenHandler> logger) : DelegatingHandler
{
    /// <summary>Set by the patient portal to the signed-in patient's id before it calls the API.</summary>
    public const string PatientIdItem = "EmrApi.PatientId";
    public const string SessionTokenKey = "EmrApi.AccessToken";
    private const string SessionExpiresKey = "EmrApi.AccessTokenExpires";
    private const string SessionSubjectKey = "EmrApi.AccessTokenSubject";
    private static readonly TimeSpan RenewBefore = TimeSpan.FromSeconds(60);

    private static readonly object ServiceGate = new();
    private static (string Token, DateTime Expires) _serviceToken;

    private sealed record WebTokenResponse(string AccessToken, int ExpiresIn);

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        if (request.Headers.Authorization is not null) return await base.SendAsync(request, cancellationToken);

        var http = httpContextAccessor.HttpContext;
        var staff = StaffSubject(http?.User);
        if (staff is null)
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", ServiceToken(http));
            return await base.SendAsync(request, cancellationToken);
        }

        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await UserTokenAsync(http!, staff, false, cancellationToken));
        var response = await base.SendAsync(request, cancellationToken);
        if (response.StatusCode != HttpStatusCode.Unauthorized || request.Content is not null) return response;

        // The token was refused (signing key changed, API restarted with new settings): get a new one and try once more.
        response.Dispose();
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await UserTokenAsync(http!, staff, true, cancellationToken));
        return await base.SendAsync(request, cancellationToken);
    }

    private sealed record Staff(string UserId, string Fingerprint, List<Claim> Claims);

    private static Staff? StaffSubject(ClaimsPrincipal? user)
    {
        if (user?.Identity?.IsAuthenticated != true || user.FindFirstValue(ClaimTypes.NameIdentifier) is not { Length: > 0 } userId) return null;
        var claims = new List<Claim> { new("sub", userId) };
        foreach (var type in new[] { "BranchId", "CompanyId", "ActiveRole", "IsSuperAdmin" })
            if (user.FindFirstValue(type) is { Length: > 0 } v) claims.Add(new Claim(type, v));
        return new Staff(userId, string.Join("|", claims.Select(c => c.Value)), claims);
    }

    private async Task<string> UserTokenAsync(HttpContext http, Staff staff, bool renew, CancellationToken ct)
    {
        ISession? session = null;
        try
        {
            session = http.Session;
            await session.LoadAsync(ct);
            if (!renew
                && session.GetString(SessionSubjectKey) == staff.Fingerprint
                && session.GetString(SessionTokenKey) is { Length: > 0 } cached
                && long.TryParse(session.GetString(SessionExpiresKey), out var ticks)
                && new DateTime(ticks, DateTimeKind.Utc) - RenewBefore > DateTime.UtcNow)
                return cached;
        }
        catch (Exception ex) when (ex is InvalidOperationException or ObjectDisposedException)
        {
            session = null;   // no session on this request (e.g. work continuing after the response): no caching
        }

        var (token, expires) = await ExchangeAsync(staff, ct);
        try
        {
            session?.SetString(SessionTokenKey, token);
            session?.SetString(SessionExpiresKey, expires.Ticks.ToString());
            session?.SetString(SessionSubjectKey, staff.Fingerprint);
        }
        catch (Exception ex) when (ex is InvalidOperationException or ObjectDisposedException)
        {
            // the response has already started; the next request gets its own token
        }
        return token;
    }

    /// <summary>Forgets the user's API access token (sign-out).</summary>
    public static void Forget(ISession session)
    {
        session.Remove(SessionTokenKey);
        session.Remove(SessionExpiresKey);
        session.Remove(SessionSubjectKey);
    }

    /// <summary>api/auth/web-token, authorized by a short on-behalf token; sent past this handler so it is not signed twice.</summary>
    private async Task<(string Token, DateTime Expires)> ExchangeAsync(Staff staff, CancellationToken ct)
    {
        var baseUrl = (configuration["ApiSettings:BaseUrl"] ?? "https://localhost:5125").TrimEnd('/') + "/";
        using var exchange = new HttpRequestMessage(HttpMethod.Post, new Uri(new Uri(baseUrl), "api/auth/web-token"));
        exchange.Headers.Authorization = new AuthenticationHeaderValue("Bearer",
            tokens.CreateToken(staff.Claims, TokenUse.OnBehalf, TimeSpan.FromSeconds(Math.Clamp(options.CurrentValue.OnBehalfTokenSeconds, 30, 900))));
        exchange.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

        using var response = await base.SendAsync(exchange, ct);
        if (!response.IsSuccessStatusCode)
        {
            logger.LogWarning("[API-AUTH] web-token refused for user {UserId}: {Status}", staff.UserId, (int)response.StatusCode);
            throw new HttpRequestException($"EMR.Api refused an access token for this user ({(int)response.StatusCode}).", null, response.StatusCode);
        }
        var body = await response.Content.ReadFromJsonAsync<WebTokenResponse>(ct)
                   ?? throw new HttpRequestException("EMR.Api returned no access token.");
        return (body.AccessToken, DateTime.UtcNow.AddSeconds(body.ExpiresIn));
    }

    private string ServiceToken(HttpContext? http)
    {
        var lifetime = TimeSpan.FromSeconds(Math.Clamp(options.CurrentValue.OnBehalfTokenSeconds, 30, 900));
        if (http?.Items[PatientIdItem] is int patientId && patientId > 0)
            return tokens.CreateToken(new[] { new Claim("svc", "EMR.Web"), new Claim(TokenUse.PatientIdClaim, patientId.ToString()) },
                TokenUse.Service, lifetime);

        lock (ServiceGate)
        {
            if (_serviceToken.Expires <= DateTime.UtcNow.AddSeconds(30))
                _serviceToken = (tokens.CreateToken(new[] { new Claim("svc", "EMR.Web") }, TokenUse.Service, lifetime),
                                 DateTime.UtcNow.Add(lifetime));
            return _serviceToken.Token;
        }
    }
}
