using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;

namespace EMR.Shared.Security;

/// <summary>"ApiAuth" section, identical in EMR.Web and EMR.Api (the signing key is the shared secret).</summary>
public sealed class ApiAuthOptions
{
    public const string SectionName = "ApiAuth";

    /// <summary>At least 32 bytes. Keep it out of source control in production (environment variable ApiAuth__SigningKey).</summary>
    public string SigningKey { get; set; } = string.Empty;
    public string Issuer { get; set; } = "EMR";
    public string Audience { get; set; } = "EMR.Api";

    /// <summary>EMR.Api: Enforce (a token is required on every call) or Audit (calls without one are logged, not refused).</summary>
    public string Mode { get; set; } = "Enforce";

    /// <summary>Lifetime of the token EMR.Web attaches to each call it makes for a signed-in user.</summary>
    public int OnBehalfTokenSeconds { get; set; } = 120;

    /// <summary>api/auth: access token and refresh token lifetimes.</summary>
    public int AccessTokenMinutes { get; set; } = 15;
    public int RefreshTokenDays { get; set; } = 7;

    /// <summary>Wrong passwords before a temporary lockout, and its length (web and API sign-in alike).</summary>
    public int MaxFailedAttempts { get; set; } = 5;
    public int LockoutMinutes { get; set; } = 15;

    public bool IsEnforced => !string.Equals(Mode, "Audit", StringComparison.OrdinalIgnoreCase);
}

/// <summary>What a token is for; EMR.Api treats them differently.</summary>
public static class TokenUse
{
    public const string ClaimType = "token_use";
    /// <summary>Minted by EMR.Web for one signed-in user's calls. The Web has already authorized the action.</summary>
    public const string OnBehalf = "obo";
    /// <summary>Minted by EMR.Web when no staff user is signed in (start-up, jobs, the patient portal).</summary>
    public const string Service = "service";
    /// <summary>Issued by api/auth to an outside client; each call must pass the endpoint permission map.</summary>
    public const string Access = "access";
    /// <summary>Short ticket between api/auth/login and api/auth/context when the user must pick a branch / role.</summary>
    public const string Login = "login";

    public const string PatientIdClaim = "patient_id";
}

public interface IApiTokenService
{
    string CreateToken(IEnumerable<Claim> claims, string tokenUse, TimeSpan lifetime);
    TokenValidationParameters ValidationParameters();

    /// <summary>Validates a token of one use (e.g. the login ticket); null when invalid.</summary>
    Task<ClaimsIdentity?> ValidateAsync(string token, string expectedUse);

    /// <summary>A new random refresh token and the SHA-256 hash that is stored instead of it.</summary>
    (string Token, string Hash) NewRefreshToken();
    string HashRefreshToken(string token);
}

public sealed class ApiTokenService(IOptionsMonitor<ApiAuthOptions> options) : IApiTokenService
{
    private readonly JsonWebTokenHandler _handler = new() { SetDefaultTimesOnTokenCreation = true };

    private SymmetricSecurityKey Key()
    {
        var key = options.CurrentValue.SigningKey;
        if (string.IsNullOrWhiteSpace(key) || Encoding.UTF8.GetByteCount(key) < 32)
            throw new InvalidOperationException("ApiAuth:SigningKey must be set to at least 32 characters in EMR.Web and EMR.Api.");
        return new SymmetricSecurityKey(Encoding.UTF8.GetBytes(key));
    }

    public string CreateToken(IEnumerable<Claim> claims, string tokenUse, TimeSpan lifetime)
    {
        var o = options.CurrentValue;
        var identity = new ClaimsIdentity(claims);
        identity.AddClaim(new Claim(TokenUse.ClaimType, tokenUse));
        return _handler.CreateToken(new SecurityTokenDescriptor
        {
            Issuer = o.Issuer,
            Audience = o.Audience,
            Subject = identity,
            Expires = DateTime.UtcNow.Add(lifetime),
            SigningCredentials = new SigningCredentials(Key(), SecurityAlgorithms.HmacSha256)
        });
    }

    public TokenValidationParameters ValidationParameters()
    {
        var o = options.CurrentValue;
        return new TokenValidationParameters
        {
            ValidateIssuer = true, ValidIssuer = o.Issuer,
            ValidateAudience = true, ValidAudience = o.Audience,
            ValidateIssuerSigningKey = true, IssuerSigningKey = Key(),
            ValidateLifetime = true, ClockSkew = TimeSpan.FromSeconds(30),
            ValidAlgorithms = new[] { SecurityAlgorithms.HmacSha256 }
        };
    }

    public async Task<ClaimsIdentity?> ValidateAsync(string token, string expectedUse)
    {
        if (string.IsNullOrWhiteSpace(token)) return null;
        var result = await _handler.ValidateTokenAsync(token, ValidationParameters());
        if (!result.IsValid) return null;
        return result.ClaimsIdentity.FindFirst(TokenUse.ClaimType)?.Value == expectedUse ? result.ClaimsIdentity : null;
    }

    public (string Token, string Hash) NewRefreshToken()
    {
        var token = Base64UrlEncoder.Encode(RandomNumberGenerator.GetBytes(48));
        return (token, HashRefreshToken(token));
    }

    public string HashRefreshToken(string token)
        => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token)));
}
