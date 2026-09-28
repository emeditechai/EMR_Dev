using System.Net.Http.Headers;
using System.Security.Claims;
using EMR.Shared.Security;
using Microsoft.Extensions.Options;

namespace EMR.Web.ApiClients;

/// <summary>
/// Signs every call to EMR.Api (the "EmrApi" client only - never a third-party one):
///   - a signed-in staff user        -> an on-behalf token with the user's id, branch, company and active role;
///   - the patient portal            -> a service token naming the portal patient (HttpContext.Items[PatientIdItem]);
///   - no user (start-up, jobs)      -> a service token.
/// Tokens are short-lived and made once per request (or once a minute for the service token).
/// </summary>
public sealed class EmrApiTokenHandler(
    IHttpContextAccessor httpContextAccessor,
    IApiTokenService tokens,
    IOptionsMonitor<ApiAuthOptions> options) : DelegatingHandler
{
    /// <summary>Set by the patient portal to the signed-in patient's id before it calls the API.</summary>
    public const string PatientIdItem = "EmrApi.PatientId";
    private const string TokenItem = "EmrApi.Token";

    private static readonly object ServiceGate = new();
    private static (string Token, DateTime Expires) _serviceToken;

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        if (request.Headers.Authorization is null)
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", TokenFor(httpContextAccessor.HttpContext));
        return base.SendAsync(request, cancellationToken);
    }

    private string TokenFor(HttpContext? http)
    {
        if (http?.Items[TokenItem] is string cached) return cached;
        var lifetime = TimeSpan.FromSeconds(Math.Clamp(options.CurrentValue.OnBehalfTokenSeconds, 30, 900));

        string token;
        var user = http?.User;
        if (user?.Identity?.IsAuthenticated == true && user.FindFirstValue(ClaimTypes.NameIdentifier) is { Length: > 0 } userId)
        {
            var claims = new List<Claim> { new("sub", userId) };
            foreach (var type in new[] { "BranchId", "CompanyId", "ActiveRole", "IsSuperAdmin" })
                if (user.FindFirstValue(type) is { Length: > 0 } v) claims.Add(new Claim(type, v));
            token = tokens.CreateToken(claims, TokenUse.OnBehalf, lifetime);
        }
        else if (http?.Items[PatientIdItem] is int patientId && patientId > 0)
        {
            token = tokens.CreateToken(new[] { new Claim("svc", "EMR.Web"), new Claim(TokenUse.PatientIdClaim, patientId.ToString()) },
                TokenUse.Service, lifetime);
        }
        else
        {
            lock (ServiceGate)
            {
                if (_serviceToken.Expires <= DateTime.UtcNow.AddSeconds(30))
                    _serviceToken = (tokens.CreateToken(new[] { new Claim("svc", "EMR.Web") }, TokenUse.Service, lifetime),
                                     DateTime.UtcNow.Add(lifetime));
                token = _serviceToken.Token;
            }
        }

        if (http is not null) http.Items[TokenItem] = token;
        return token;
    }
}
