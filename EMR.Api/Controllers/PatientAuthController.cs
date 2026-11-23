using System.Data;
using System.Security.Claims;
using System.Text.RegularExpressions;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Services;
using EMR.Shared.Security;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.Extensions.Options;

namespace EMR.Api.Controllers;

/// <summary>
/// Sign-in for the patient app, with the same PatientMaster rules as the web portal (EMR.Web PatientPortalController):
/// the e-mail or mobile number of the patient record, not the Patient ID (PatientAccount: a family shares one
/// account, its head of family), an active patient, BCrypt password, 5 wrong
/// passwords lock the portal account for 10 minutes (usp_PatientPortal_LoginFailure / _LoginSuccess, SQLScripts/2326),
/// and the password sent by the hospital must be changed at the first sign-in.
/// A patient new to the app (PatientMaster.Is_App_Verified = 0, SQLScripts/2486) signs in the first time as a marketing
/// executive does (2457): a code on WhatsApp to the mobile number of the patient record (patient-password/forgot),
/// confirmed (forgot/verify), then the password (forgot/reset), which verifies the patient. The same calls reset a
/// forgotten password.
/// Tokens as api/auth gives them: an access token (token_use = patient, AccessTokenMinutes) that opens only the
/// [PatientOwnData] endpoints, and only for this patient, and a refresh token (RefreshTokenDays) rotated by
/// patient-refresh; patient-logout revokes it.
/// </summary>
[ApiController]
[Route("api/auth")]
[Produces("application/json")]
public sealed class PatientAuthController(
    IDbConnectionFactory db,
    IApiTokenService tokens,
    IOptionsMonitor<ApiAuthOptions> options,
    IServiceScopeFactory scopes,
    ILogger<PatientAuthController> logger) : ControllerBase
{
    private const string InvalidCredentials = "E-mail / mobile number or password is not correct.";
    private static readonly TimeSpan ChangeTicketLifetime = TimeSpan.FromMinutes(10);
    private static readonly Regex LetterAndDigit = new(@"^(?=.*[A-Za-z])(?=.*\d).+$", RegexOptions.Compiled);
    private static readonly Lazy<string> DummyHash = new(() => BCrypt.Net.BCrypt.HashPassword(Guid.NewGuid().ToString(), 12));

    /// <summary>Login: the e-mail or the mobile number of the patient record.</summary>
    public sealed record PatientLoginRequest(string Login, string Password);
    public sealed record PatientFirstChangeRequest(string ChangeTicket, string NewPassword, string ConfirmPassword);
    public sealed record PatientForgotRequest(string Login);
    public sealed record PatientForgotVerifyRequest(string Login, string Code);
    public sealed record PatientForgotResetRequest(string ResetToken, string NewPassword, string ConfirmPassword);
    public sealed record PatientRefreshRequest(string RefreshToken);

    private sealed class PatientRow
    {
        public int PatientId { get; set; }
        public string PatientCode { get; set; } = "";
        public string FullName { get; set; } = "";
        public string? PasswordHash { get; set; }
        public bool IsLoginGenerated { get; set; }
        public bool IsPasswordChanged { get; set; }
        /// <summary>False until the first sign-in by WhatsApp code (SQLScripts/2486).</summary>
        public bool IsVerified { get; set; }
        public DateTime? LockedUntil { get; set; }
    }

    private sealed record RotateRow(string Status, int? Patient_ID);

    private sealed record FailureRow(DateTime? LockedUntil, int AttemptsLeft);

    [HttpPost("patient-login")]
    [EnableRateLimiting(AuthController.RateLimitPolicy)]
    [AllowAnonymous]
    public async Task<IActionResult> Login([FromBody] PatientLoginRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Login) || string.IsNullOrEmpty(request.Password))
            return Unauthorized(Fail("INVALID_CREDENTIALS", "Enter your e-mail or mobile number and password."));

        using var con = db.CreateConnection();
        var account = await PatientAccount.FindAsync(con, request.Login);
        var patient = account is null ? null : await FindAsync(con, "PatientId = @id", new { id = account });

        // The same answer and roughly the same work whether or not the account exists.
        if (patient is null)
        {
            BCrypt.Net.BCrypt.Verify(request.Password, DummyHash.Value);
            return Unauthorized(Fail("INVALID_CREDENTIALS", InvalidCredentials));
        }
        if (patient.LockedUntil is { } locked)
            return StatusCode(423, Fail("LOCKED_OUT", LockedMessage(locked)));

        // New to the app (SQLScripts/2486): no password of the patient's own yet. The app asks for a code
        // (patient-password/forgot), confirms it (forgot/verify) and sets the password (forgot/reset).
        if (!patient.IsVerified || !patient.IsLoginGenerated)
            return StatusCode(403, Fail("VERIFICATION_REQUIRED",
                "Verify your mobile number once: we will send a code on WhatsApp to the number registered with the hospital."));

        bool ok;
        try { ok = !string.IsNullOrEmpty(patient.PasswordHash) && BCrypt.Net.BCrypt.Verify(request.Password, patient.PasswordHash); }
        catch { ok = false; }

        if (!ok)
        {
            var failure = await con.QuerySingleAsync<FailureRow>("dbo.usp_PatientPortal_LoginFailure",
                new { patient.PatientId }, commandType: CommandType.StoredProcedure);
            logger.LogWarning("[PATIENT-AUTH] Wrong password for {PatientCode} from {Ip}", patient.PatientCode, ClientIp());
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

        return Ok(await IssueAsync(con, patient, Guid.NewGuid()));
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
        if (PasswordProblem(newPassword) is { } problem) return BadRequest(Fail("WEAK_PASSWORD", problem));
        if (newPassword != request.ConfirmPassword)
            return BadRequest(Fail("PASSWORD_MISMATCH", "The two passwords do not match."));

        using var con = db.CreateConnection();
        var patient = await FindAsync(con, "PatientId = @id", new { id = patientId });
        if (patient is null || !patient.IsLoginGenerated || !patient.IsVerified)
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
        return Ok(await IssueAsync(con, patient, Guid.NewGuid()));
    }

    /// <summary>First sign-in and forgot password: a code on WhatsApp. The answer is the same for every e-mail / mobile, and the send runs behind it, so neither says which patients exist.</summary>
    [HttpPost("patient-password/forgot")]
    [EnableRateLimiting(AuthController.RateLimitPolicy)]
    [AllowAnonymous]
    public IActionResult Forgot([FromBody] PatientForgotRequest request)
    {
        var login = (request.Login ?? "").Trim();
        if (login.Length == 0) return BadRequest(Fail("LOGIN_REQUIRED", "Enter your e-mail or mobile number."));

        var ip = ClientIp();
        _ = Task.Run(async () =>
        {
            try
            {
                using var scope = scopes.CreateScope();
                await scope.ServiceProvider.GetRequiredService<IPatientOtpService>().RequestAsync(login, ip);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "[PATIENT-OTP] Code request failed");
            }
        });
        return Ok(new { success = true, message = "If this e-mail or mobile number is registered with the hospital, a code is on its way on WhatsApp to the registered mobile. If none arrives, please ask the hospital reception." });
    }

    [HttpPost("patient-password/forgot/verify")]
    [EnableRateLimiting(AuthController.RateLimitPolicy)]
    [AllowAnonymous]
    public async Task<IActionResult> ForgotVerify([FromBody] PatientForgotVerifyRequest request, [FromServices] IPatientOtpService otp)
    {
        var token = await otp.VerifyAsync(request.Login ?? "", request.Code ?? "");
        return token is null
            ? BadRequest(Fail("INVALID_CODE", "This code is wrong or has expired."))
            : Ok(new { success = true, resetToken = token });
    }

    [HttpPost("patient-password/forgot/reset")]
    [EnableRateLimiting(AuthController.RateLimitPolicy)]
    [AllowAnonymous]
    public async Task<IActionResult> ForgotReset([FromBody] PatientForgotResetRequest request, [FromServices] IPatientOtpService otp)
    {
        var problem = PasswordProblem(request.NewPassword);
        if (problem is not null) return BadRequest(Fail("WEAK_PASSWORD", problem));
        if (request.NewPassword != request.ConfirmPassword) return BadRequest(Fail("PASSWORD_MISMATCH", "The two passwords do not match."));

        var patientId = await otp.ResetAsync(request.ResetToken ?? "", request.NewPassword);
        if (patientId is null) return BadRequest(Fail("RESET_EXPIRED", "This step has expired. Ask for a new code."));
        return Ok(new { success = true, message = "Password set. Sign in with the new password." });
    }

    /// <summary>A new token pair; the old refresh token is spent, and presenting it again revokes the whole family.</summary>
    [HttpPost("patient-refresh")]
    [EnableRateLimiting(AuthController.RateLimitPolicy)]
    [AllowAnonymous]
    public async Task<IActionResult> Refresh([FromBody] PatientRefreshRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.RefreshToken)) return Unauthorized(Fail("INVALID_REFRESH", "Refresh token required."));
        var (next, nextHash) = tokens.NewRefreshToken();

        using var con = db.CreateConnection();
        var row = await con.QuerySingleAsync<RotateRow>("dbo.usp_PatientApp_RefreshToken_Rotate",
            new { TokenHash = tokens.HashRefreshToken(request.RefreshToken), NewTokenHash = nextHash,
                  NewExpiresOn = DateTime.Now.AddDays(options.CurrentValue.RefreshTokenDays),
                  DeviceId = DeviceId(), CreatedIp = ClientIp(), UserAgent = Request.Headers.UserAgent.ToString() },
            commandType: CommandType.StoredProcedure);

        if (row.Status != "OK")
        {
            if (row.Status == "REUSED")
                logger.LogWarning("[PATIENT-AUTH] Refresh token reused for patient {PatientId} from {Ip}: family revoked", row.Patient_ID, ClientIp());
            return Unauthorized(Fail(row.Status == "REUSED" ? "REFRESH_REUSED" : "INVALID_REFRESH", "Your session has ended. Please sign in again."));
        }

        var patient = await FindAsync(con, "PatientId = @id", new { id = row.Patient_ID });
        if (patient is null) return Unauthorized(Fail("INVALID_REFRESH", "Your session has ended. Please sign in again."));
        return Ok(await ResponseAsync(con, patient, next));
    }

    [HttpPost("patient-logout")]
    [AllowAnonymous]
    public async Task<IActionResult> Logout([FromBody] PatientRefreshRequest request)
    {
        using var con = db.CreateConnection();
        var family = await con.ExecuteScalarAsync<Guid?>("SELECT Family_ID FROM dbo.PatientApiRefreshToken WHERE Token_Hash = @h",
            new { h = tokens.HashRefreshToken(request.RefreshToken ?? "") });
        if (family is not null)
            await con.ExecuteAsync("dbo.usp_PatientApp_RefreshToken_RevokeFamily", new { FamilyId = family, Reason = "Signed out" },
                commandType: CommandType.StoredProcedure);
        return Ok(new { success = true });
    }

    private static Task<PatientRow?> FindAsync(IDbConnection con, string where, object args) =>
        con.QuerySingleOrDefaultAsync<PatientRow>(
            $@"SELECT PatientId, PatientCode,
                      LTRIM(RTRIM(ISNULL(FirstName, '') + ' ' + ISNULL(LastName, ''))) AS FullName,
                      PasswordHash,
                      CAST(ISNULL(IsLoginGenerated, 0) AS BIT) AS IsLoginGenerated,
                      CAST(ISNULL(IsPasswordchanged, 0) AS BIT) AS IsPasswordChanged,
                      Is_App_Verified AS IsVerified,
                      CASE WHEN PortalLockoutUntil > GETDATE() THEN PortalLockoutUntil END AS LockedUntil
                 FROM dbo.PatientMaster
                WHERE {where} AND ISNULL(IsActive, 1) = 1", args);

    private async Task<object> IssueAsync(IDbConnection con, PatientRow p, Guid family)
    {
        var (refresh, hash) = tokens.NewRefreshToken();
        await con.ExecuteAsync("dbo.usp_PatientApp_RefreshToken_Create",
            new { TokenHash = hash, FamilyId = family, p.PatientId, ExpiresOn = DateTime.Now.AddDays(options.CurrentValue.RefreshTokenDays),
                  DeviceId = DeviceId(), CreatedIp = ClientIp(), UserAgent = Request.Headers.UserAgent.ToString() },
            commandType: CommandType.StoredProcedure);
        return await ResponseAsync(con, p, refresh);
    }

    private sealed record FamilyRow(int Id, string Name, string PatientCode, string? Relation);

    // The head of family's token also opens the dependents' records (patient_family); the list is read again on
    // every refresh, so a dependent added or removed at the reception shows within AccessTokenMinutes.
    private async Task<object> ResponseAsync(IDbConnection con, PatientRow p, string refreshToken)
    {
        var familyIds = await PatientAccount.FamilyIdsAsync(con, p.PatientId);
        var family = familyIds.Count == 0 ? new List<FamilyRow>() : (await con.QueryAsync<FamilyRow>(
            @"SELECT f.PatientId AS Id, LTRIM(RTRIM(ISNULL(f.FirstName, '') + ' ' + ISNULL(f.LastName, ''))) AS Name, f.PatientCode,
                     rm.RelationName AS Relation
                FROM dbo.PatientMaster f LEFT JOIN dbo.RelationMaster rm ON rm.RelationId = f.RelationId
               WHERE f.PatientId IN @familyIds
               ORDER BY ISNULL(rm.SortOrder, 99), f.PatientId", new { familyIds })).ToList();

        var claims = new List<Claim>
        {
            new(TokenUse.PatientIdClaim, p.PatientId.ToString()),
            new(ClaimTypes.Name, p.FullName)
        };
        if (familyIds.Count > 0) claims.Add(new Claim(TokenUse.PatientFamilyClaim, string.Join(",", familyIds)));

        var minutes = options.CurrentValue.AccessTokenMinutes;
        return new
        {
            success = true,
            tokenType = "Bearer",
            accessToken = tokens.CreateToken(claims, TokenUse.Patient, TimeSpan.FromMinutes(minutes)),
            expiresIn = minutes * 60,
            refreshToken,
            patient = new { id = p.PatientId, name = p.FullName, patientCode = p.PatientCode },
            family = family.Select(f => new { id = f.Id, name = f.Name, patientCode = f.PatientCode, relation = f.Relation })
        };
    }

    private static string? PasswordProblem(string? password) =>
        (password ?? "").Length is < 8 or > 100 || !LetterAndDigit.IsMatch(password ?? "")
            ? "Use 8 to 100 characters with at least one letter and one digit."
            : null;

    private string? ClientIp() => HttpContext.Connection.RemoteIpAddress?.ToString();
    private string? DeviceId() => Request.Headers["X-Device-Id"].FirstOrDefault();

    private static string LockedMessage(DateTime until) =>
        $"Too many wrong passwords. Try again after {until:hh:mm tt}, or ask the hospital reception to reset your password.";

    private static object Fail(string code, string message) => new { success = false, code, message };
}
