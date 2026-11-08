using System.Data;
using System.Security.Claims;
using System.Text.RegularExpressions;
using Dapper;
using EMR.Api.Data;
using EMR.Shared.Security;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.Extensions.Options;

namespace EMR.Api.Controllers;

/// <summary>
/// Sign-in for the patient app, with the same PatientMaster rules as the web portal (EMR.Web PatientPortalController):
/// Patient ID only, an active patient whose portal login was created at the reception, BCrypt password, 5 wrong
/// passwords lock the portal account for 10 minutes (usp_PatientPortal_LoginFailure / _LoginSuccess, SQLScripts/2326),
/// and the password sent by the hospital must be changed at the first sign-in.
/// The token it issues (token_use = patient) opens only the [PatientOwnData] endpoints, and only for this patient.
/// </summary>
[ApiController]
[Route("api/auth")]
[Produces("application/json")]
public sealed class PatientAuthController(
    IDbConnectionFactory db,
    IApiTokenService tokens,
    IOptionsMonitor<ApiAuthOptions> options,
    ILogger<PatientAuthController> logger) : ControllerBase
{
    private const string InvalidCredentials = "Patient ID or password is not correct.";
    private static readonly TimeSpan ChangeTicketLifetime = TimeSpan.FromMinutes(10);
    private static readonly Regex LetterAndDigit = new(@"^(?=.*[A-Za-z])(?=.*\d).+$", RegexOptions.Compiled);
    private static readonly Lazy<string> DummyHash = new(() => BCrypt.Net.BCrypt.HashPassword(Guid.NewGuid().ToString(), 12));

    public sealed record PatientLoginRequest(string PatientCode, string Password);
    public sealed record PatientFirstChangeRequest(string ChangeTicket, string NewPassword, string ConfirmPassword);

    private sealed class PatientRow
    {
        public int PatientId { get; set; }
        public string PatientCode { get; set; } = "";
        public string FullName { get; set; } = "";
        public string? PasswordHash { get; set; }
        public bool IsLoginGenerated { get; set; }
        public bool IsPasswordChanged { get; set; }
        public DateTime? LockedUntil { get; set; }
    }

    private sealed record FailureRow(DateTime? LockedUntil, int AttemptsLeft);

    [HttpPost("patient-login")]
    [EnableRateLimiting(AuthController.RateLimitPolicy)]
    [AllowAnonymous]
    public async Task<IActionResult> Login([FromBody] PatientLoginRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.PatientCode) || string.IsNullOrEmpty(request.Password))
            return Unauthorized(Fail("INVALID_CREDENTIALS", "Enter your Patient ID and password."));

        using var con = db.CreateConnection();
        var patient = await FindAsync(con, "PatientCode = @code", new { code = request.PatientCode.Trim() });

        // The same answer and roughly the same work whether or not the Patient ID exists.
        if (patient is null)
        {
            BCrypt.Net.BCrypt.Verify(request.Password, DummyHash.Value);
            return Unauthorized(Fail("INVALID_CREDENTIALS", InvalidCredentials));
        }
        if (!patient.IsLoginGenerated)
            return StatusCode(403, Fail("NO_PORTAL_LOGIN", "No portal login has been created for this Patient ID yet. Please ask the hospital reception."));
        if (patient.LockedUntil is { } locked)
            return StatusCode(423, Fail("LOCKED_OUT", LockedMessage(locked)));

        bool ok;
        try { ok = !string.IsNullOrEmpty(patient.PasswordHash) && BCrypt.Net.BCrypt.Verify(request.Password, patient.PasswordHash); }
        catch { ok = false; }

        if (!ok)
        {
            var failure = await con.QuerySingleAsync<FailureRow>("dbo.usp_PatientPortal_LoginFailure",
                new { patient.PatientId }, commandType: CommandType.StoredProcedure);
            logger.LogWarning("[PATIENT-AUTH] Wrong password for {PatientCode} from {Ip}", patient.PatientCode, HttpContext.Connection.RemoteIpAddress);
            if (failure.LockedUntil is { } until) return StatusCode(423, Fail("LOCKED_OUT", LockedMessage(until)));
            return Unauthorized(Fail("INVALID_CREDENTIALS", failure.AttemptsLeft <= 2
                ? $"{InvalidCredentials} {failure.AttemptsLeft} attempt(s) left before the account is locked for 10 minutes."
                : InvalidCredentials));
        }

        await con.ExecuteAsync("dbo.usp_PatientPortal_LoginSuccess", new { patient.PatientId }, commandType: CommandType.StoredProcedure);

        if (!patient.IsPasswordChanged)
        {
            var ticket = tokens.CreateToken(new[] { new Claim(TokenUse.PatientIdClaim, patient.PatientId.ToString()) },
                TokenUse.PatientPasswordChange, ChangeTicketLifetime);
            return StatusCode(403, new
            {
                success = false,
                code = "PASSWORD_CHANGE_REQUIRED",
                message = "For your security, please change the password the hospital sent you.",
                changeTicket = ticket
            });
        }

        return Ok(Issue(patient));
    }

    [HttpPost("patient-password/first-change")]
    [EnableRateLimiting(AuthController.RateLimitPolicy)]
    [AllowAnonymous]
    public async Task<IActionResult> FirstChange([FromBody] PatientFirstChangeRequest request)
    {
        var identity = await tokens.ValidateAsync(request.ChangeTicket ?? "", TokenUse.PatientPasswordChange);
        if (identity is null || !int.TryParse(identity.FindFirst(TokenUse.PatientIdClaim)?.Value, out var patientId))
            return BadRequest(Fail("TICKET_EXPIRED", "This step has expired. Please sign in again."));

        var newPassword = request.NewPassword ?? "";
        if (newPassword.Length is < 8 or > 100 || !LetterAndDigit.IsMatch(newPassword))
            return BadRequest(Fail("WEAK_PASSWORD", "Use 8 to 100 characters with at least one letter and one digit."));
        if (newPassword != request.ConfirmPassword)
            return BadRequest(Fail("PASSWORD_MISMATCH", "The two passwords do not match."));

        using var con = db.CreateConnection();
        var patient = await FindAsync(con, "PatientId = @id", new { id = patientId });
        if (patient is null || !patient.IsLoginGenerated)
            return BadRequest(Fail("TICKET_EXPIRED", "This step has expired. Please sign in again."));
        if (!string.IsNullOrEmpty(patient.PasswordHash) && BCrypt.Net.BCrypt.Verify(newPassword, patient.PasswordHash))
            return BadRequest(Fail("SAME_PASSWORD", "Choose a password different from the one you were sent."));

        var salt = BCrypt.Net.BCrypt.GenerateSalt(12);
        await con.ExecuteAsync(
            @"UPDATE dbo.PatientMaster
                 SET PasswordHash = @Hash, Salt = @Salt, IsPasswordchanged = 1, Lastlogin = GETDATE()
               WHERE PatientId = @Id",
            new { Hash = BCrypt.Net.BCrypt.HashPassword(newPassword, salt), Salt = salt, Id = patientId });

        patient.IsPasswordChanged = true;
        return Ok(Issue(patient));
    }

    private static Task<PatientRow?> FindAsync(IDbConnection con, string where, object args) =>
        con.QuerySingleOrDefaultAsync<PatientRow>(
            $@"SELECT PatientId, PatientCode,
                      LTRIM(RTRIM(ISNULL(FirstName, '') + ' ' + ISNULL(LastName, ''))) AS FullName,
                      PasswordHash,
                      CAST(ISNULL(IsLoginGenerated, 0) AS BIT) AS IsLoginGenerated,
                      CAST(ISNULL(IsPasswordchanged, 0) AS BIT) AS IsPasswordChanged,
                      CASE WHEN PortalLockoutUntil > GETDATE() THEN PortalLockoutUntil END AS LockedUntil
                 FROM dbo.PatientMaster
                WHERE {where} AND ISNULL(IsActive, 1) = 1", args);

    private object Issue(PatientRow p)
    {
        var lifetime = TimeSpan.FromHours(Math.Max(1, options.CurrentValue.PatientTokenHours));
        var token = tokens.CreateToken(new[]
        {
            new Claim(TokenUse.PatientIdClaim, p.PatientId.ToString()),
            new Claim(ClaimTypes.Name, p.FullName)
        }, TokenUse.Patient, lifetime);
        return new
        {
            success = true,
            tokenType = "Bearer",
            accessToken = token,
            expiresIn = (int)lifetime.TotalSeconds,
            patient = new { id = p.PatientId, name = p.FullName, patientCode = p.PatientCode }
        };
    }

    private static string LockedMessage(DateTime until) =>
        $"Too many wrong passwords. Try again after {until:hh:mm tt}, or ask the hospital reception to reset your password.";

    private static object Fail(string code, string message) => new { success = false, code, message };
}
