using System.Data;
using System.Security.Claims;
using Dapper;
using EMR.Api.Data;
using EMR.Shared.Security;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.Extensions.Options;

namespace EMR.Api.Controllers;

/// <summary>
/// Sign-in for clients other than EMR.Web (EMR.Web signs its own calls). The same rules as the web sign-in:
/// active user, branch mapping, branch-scoped roles, super admin, lockout after repeated wrong passwords.
///   login     -> tokens, or a short ticket plus the branches / roles to choose from
///   context   -> ticket + branch (+ role) -> tokens
///   refresh   -> a new pair; the old refresh token is spent, and presenting it again revokes the whole family
///   switch-branch, logout, me, permissions (ETag), password/change
/// </summary>
[ApiController]
[Route("api/auth")]
[Produces("application/json")]
public sealed class AuthController(
    IDbConnectionFactory db,
    IApiTokenService tokens,
    ILoginSecurity loginSecurity,
    IPermissionService permissions,
    IOptionsMonitor<ApiAuthOptions> options,
    ILogger<AuthController> logger) : ControllerBase
{
    /// <summary>Credential endpoints only (login, context, refresh, password change): 20 a minute per client address.</summary>
    public const string RateLimitPolicy = "auth";
    private const string InvalidCredentials = "Invalid username or password.";
    private static readonly Lazy<string> DummyHash = new(() => BCrypt.Net.BCrypt.HashPassword(Guid.NewGuid().ToString(), 12));

    public sealed record LoginRequest(string Username, string Password, int? BranchId = null, string? Role = null);
    public sealed record ContextRequest(string Ticket, int BranchId, string? Role = null);
    public sealed record RefreshRequest(string RefreshToken);
    public sealed record SwitchBranchRequest(string RefreshToken, int BranchId, string? Role = null);
    public sealed record ChangePasswordRequest(string CurrentPassword, string NewPassword);

    private sealed class UserRow
    {
        public int Id { get; set; }
        public string Username { get; set; } = "";
        public string? FullName { get; set; }
        public string PasswordHash { get; set; } = "";
        public bool IsActive { get; set; }
        public bool IsLockedOut { get; set; }
        public bool IsSuperAdmin { get; set; }
        public int CompanyId { get; set; }
        public bool MustChangePassword { get; set; }
    }
    private sealed record BranchRow(int BranchId, string BranchName, int CompanyId);

    // ── sign-in ──────────────────────────────────────────────────────────
    [HttpPost("login")]
    [EnableRateLimiting(RateLimitPolicy)]
    [AllowAnonymous]
    public async Task<IActionResult> Login([FromBody] LoginRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Username) || string.IsNullOrEmpty(request.Password))
            return Unauthorized(Fail("INVALID_CREDENTIALS", InvalidCredentials));

        using var con = db.CreateConnection();
        var user = await con.QuerySingleOrDefaultAsync<UserRow>(
            @"SELECT Id, Username, FullName, PasswordHash, IsActive, ISNULL(IsLockedOut, 0) AS IsLockedOut,
                     ISNULL(IsSuperAdmin, 0) AS IsSuperAdmin, ISNULL(CompanyId, 1) AS CompanyId, ISNULL(MustChangePassword, 0) AS MustChangePassword
              FROM dbo.Users WHERE Username = @u", new { u = request.Username.Trim() });

        // The same answer and roughly the same work whether or not the user exists.
        if (user is null)
        {
            BCrypt.Net.BCrypt.Verify(request.Password, DummyHash.Value);
            return Unauthorized(Fail("INVALID_CREDENTIALS", InvalidCredentials));
        }
        if (await loginSecurity.LockedUntilAsync(user.Id) is { } until)
            return StatusCode(423, Fail("LOCKED_OUT", $"Too many wrong passwords. Try again after {until:HH:mm}."));

        bool ok;
        try { ok = BCrypt.Net.BCrypt.Verify(request.Password, user.PasswordHash); } catch { ok = false; }
        if (!ok)
        {
            var locked = await loginSecurity.RecordFailureAsync(user.Id);
            logger.LogWarning("[API-AUTH] Wrong password for {User} from {Ip}", user.Username, ClientIp());
            return locked is { } l
                ? StatusCode(423, Fail("LOCKED_OUT", $"Too many wrong passwords. Try again after {l:HH:mm}."))
                : Unauthorized(Fail("INVALID_CREDENTIALS", InvalidCredentials));
        }
        if (!user.IsActive || user.IsLockedOut)
            return StatusCode(403, Fail("ACCOUNT_INACTIVE", "User is inactive or locked out. Contact administrator."));

        await loginSecurity.RecordSuccessAsync(user.Id);
        if (user.MustChangePassword)
            return StatusCode(403, Fail("PASSWORD_CHANGE_REQUIRED", "Change your password in the web application before signing in here."));

        return await IssueForContextAsync(con, user, request.BranchId, request.Role, allowTicket: true);
    }

    [HttpPost("context")]
    [EnableRateLimiting(RateLimitPolicy)]
    [AllowAnonymous]
    public async Task<IActionResult> Context([FromBody] ContextRequest request)
    {
        var ticket = await tokens.ValidateAsync(request.Ticket, TokenUse.Login);
        if (ticket is null || !int.TryParse(ticket.FindFirst("sub")?.Value ?? ticket.FindFirst(ClaimTypes.NameIdentifier)?.Value, out var userId))
            return Unauthorized(Fail("INVALID_TICKET", "The sign-in ticket is invalid or has expired. Sign in again."));

        using var con = db.CreateConnection();
        var user = await LoadUserAsync(con, userId);
        if (user is null || !user.IsActive || user.IsLockedOut)
            return StatusCode(403, Fail("ACCOUNT_INACTIVE", "User is inactive or locked out. Contact administrator."));
        return await IssueForContextAsync(con, user, request.BranchId, request.Role, allowTicket: false);
    }

    [HttpPost("refresh")]
    [EnableRateLimiting(RateLimitPolicy)]
    [AllowAnonymous]
    public async Task<IActionResult> Refresh([FromBody] RefreshRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.RefreshToken)) return Unauthorized(Fail("INVALID_REFRESH", "Refresh token required."));
        var (next, nextHash) = tokens.NewRefreshToken();
        var expires = DateTime.Now.AddDays(options.CurrentValue.RefreshTokenDays);

        using var con = db.CreateConnection();
        var row = await con.QuerySingleAsync<RotateRow>("dbo.usp_Auth_RefreshToken_Rotate",
            new { TokenHash = tokens.HashRefreshToken(request.RefreshToken), NewTokenHash = nextHash, NewExpiresOn = expires,
                  CreatedIp = ClientIp(), UserAgent = Request.Headers.UserAgent.ToString() },
            commandType: CommandType.StoredProcedure);

        if (row.Status != "OK")
        {
            if (row.Status == "REUSED")
            {
                logger.LogWarning("[API-AUTH] Refresh token reused for user {UserId} from {Ip}: family revoked", row.User_ID, ClientIp());
                permissions.InvalidateUser(row.User_ID ?? 0);
            }
            return Unauthorized(Fail(row.Status == "REUSED" ? "REFRESH_REUSED" : "INVALID_REFRESH",
                row.Status == "REUSED" ? "This refresh token was already used; every session from it has been signed out." : "Sign in again."));
        }

        var user = await LoadUserAsync(con, row.User_ID!.Value);
        if (user is null) return Unauthorized(Fail("INVALID_REFRESH", "Sign in again."));
        var branch = await con.QuerySingleOrDefaultAsync<BranchRow>(
            "SELECT BranchID AS BranchId, BranchName, CompanyId FROM dbo.Branchmaster WHERE BranchID = @b", new { b = row.Branch_ID });
        return Ok(TokenResponse(user, branch!, row.Role_Name, next));
    }

    [HttpPost("switch-branch")]
    [Authorize, PublicEndpoint]
    public async Task<IActionResult> SwitchBranch([FromBody] SwitchBranchRequest request)
    {
        if (!IsAccessToken(out var userId)) return Forbid();
        using var con = db.CreateConnection();
        var family = await con.ExecuteScalarAsync<Guid?>(
            "SELECT Family_ID FROM dbo.ApiRefreshToken WHERE Token_Hash = @h AND User_ID = @u AND Revoked_On IS NULL AND Used_On IS NULL",
            new { h = tokens.HashRefreshToken(request.RefreshToken ?? ""), u = userId });
        if (family is null) return Unauthorized(Fail("INVALID_REFRESH", "Sign in again."));

        var user = await LoadUserAsync(con, userId);
        if (user is null || !user.IsActive || user.IsLockedOut)
            return StatusCode(403, Fail("ACCOUNT_INACTIVE", "User is inactive or locked out. Contact administrator."));

        var result = await IssueForContextAsync(con, user, request.BranchId, request.Role, allowTicket: false);
        if (result is OkObjectResult)
            await con.ExecuteAsync("dbo.usp_Auth_RefreshToken_RevokeFamily", new { FamilyId = family, Reason = "Switched branch" },
                commandType: CommandType.StoredProcedure);
        return result;
    }

    [HttpPost("logout")]
    [AllowAnonymous]
    public async Task<IActionResult> Logout([FromBody] RefreshRequest request)
    {
        using var con = db.CreateConnection();
        var family = await con.ExecuteScalarAsync<Guid?>("SELECT Family_ID FROM dbo.ApiRefreshToken WHERE Token_Hash = @h",
            new { h = tokens.HashRefreshToken(request.RefreshToken ?? "") });
        if (family is not null)
            await con.ExecuteAsync("dbo.usp_Auth_RefreshToken_RevokeFamily", new { FamilyId = family, Reason = "Signed out" },
                commandType: CommandType.StoredProcedure);
        return Ok(new { success = true });
    }

    // ── the signed-in user ───────────────────────────────────────────────
    [HttpGet("me")]
    [Authorize, PublicEndpoint]
    public IActionResult Me()
    {
        var subject = PermissionSubjectReader.FromPrincipal(User);
        if (subject is null) return Unauthorized(Fail("UNAUTHENTICATED", "No user in the token."));
        return Ok(new
        {
            success = true,
            user = new
            {
                id = subject.UserId, username = User.FindFirstValue("username"), name = User.FindFirstValue("name"),
                companyId = subject.CompanyId, branchId = subject.BranchId, branchName = User.FindFirstValue("BranchName"),
                activeRole = subject.ActiveRoleName, isSuperAdmin = User.FindFirstValue("IsSuperAdmin") == "true"
            }
        });
    }

    /// <summary>The effective permission set; ETag is the user's permission version, so an unchanged set answers 304.</summary>
    [HttpGet("permissions")]
    [Authorize, PublicEndpoint]
    public async Task<IActionResult> Permissions()
    {
        var subject = PermissionSubjectReader.FromPrincipal(User);
        if (subject is null) return Unauthorized(Fail("UNAUTHENTICATED", "No user in the token."));
        var set = await permissions.GetPermissionSetAsync(subject);
        var etag = $"\"{subject.UserId}-{subject.BranchId}-{subject.ActiveRoleName}-{set.Version}\"";
        if (Request.Headers.IfNoneMatch.ToString() == etag) return StatusCode(StatusCodes.Status304NotModified);

        Response.Headers.ETag = etag;
        return Ok(new
        {
            success = true, version = set.Version, bypass = set.IsBypass,
            allowed = set.Rows.Where(r => set.IsBypass || r.Permission == "A")
                              .Select(r => new { page = r.Page_Code, control = r.Control_Code })
        });
    }

    [HttpPost("password/change")]
    [EnableRateLimiting(RateLimitPolicy)]
    [Authorize, PublicEndpoint]
    public async Task<IActionResult> ChangePassword([FromBody] ChangePasswordRequest request)
    {
        if (!IsAccessToken(out var userId)) return Forbid();
        var problem = PasswordProblem(request.NewPassword);
        if (problem is not null) return BadRequest(Fail("WEAK_PASSWORD", problem));

        using var con = db.CreateConnection();
        var user = await LoadUserAsync(con, userId);
        if (user is null) return Unauthorized(Fail("UNAUTHENTICATED", "Sign in again."));
        bool ok;
        try { ok = BCrypt.Net.BCrypt.Verify(request.CurrentPassword ?? "", user.PasswordHash); } catch { ok = false; }
        if (!ok)
        {
            await loginSecurity.RecordFailureAsync(userId);
            return BadRequest(Fail("INVALID_CREDENTIALS", "The current password is not correct."));
        }

        await con.ExecuteAsync(
            @"UPDATE dbo.Users SET PasswordHash = @h, PasswordLastChanged = SYSDATETIME(), MustChangePassword = 0,
                     Permission_Version = Permission_Version + 1 WHERE Id = @id",
            new { h = BCrypt.Net.BCrypt.HashPassword(request.NewPassword, 12), id = userId });
        await con.ExecuteAsync("dbo.usp_Auth_RefreshToken_RevokeUser", new { UserId = userId, Reason = "Password changed" },
            commandType: CommandType.StoredProcedure);
        permissions.InvalidateUser(userId);
        return Ok(new { success = true, message = "Password changed. Sign in again on every device." });
    }

    // ── helpers ──────────────────────────────────────────────────────────
    private sealed class RotateRow
    {
        public string Status { get; set; } = "";
        public int? User_ID { get; set; }
        public int? Company_ID { get; set; }
        public int? Branch_ID { get; set; }
        public string? Role_Name { get; set; }
        public Guid? Family_ID { get; set; }
    }

    private static Task<UserRow?> LoadUserAsync(IDbConnection con, int userId) => con.QuerySingleOrDefaultAsync<UserRow>(
        @"SELECT Id, Username, FullName, PasswordHash, IsActive, ISNULL(IsLockedOut, 0) AS IsLockedOut,
                 ISNULL(IsSuperAdmin, 0) AS IsSuperAdmin, ISNULL(CompanyId, 1) AS CompanyId, ISNULL(MustChangePassword, 0) AS MustChangePassword
          FROM dbo.Users WHERE Id = @userId", new { userId });

    /// <summary>Resolves branch and role like the web sign-in; answers with tokens, or with the choices and a ticket.</summary>
    private async Task<IActionResult> IssueForContextAsync(IDbConnection con, UserRow user, int? branchId, string? role, bool allowTicket)
    {
        var branches = (await con.QueryAsync<BranchRow>(
            @"SELECT DISTINCT b.BranchID AS BranchId, b.BranchName, b.CompanyId
              FROM dbo.UserBranches ub INNER JOIN dbo.Branchmaster b ON b.BranchID = ub.BranchID
              WHERE ub.UserId = @id AND ub.IsActive = 1 AND b.IsActive = 1", new { id = user.Id })).ToList();
        if (branches.Count == 0) return StatusCode(403, Fail("NO_BRANCH", "No active branch mapping found for this user."));

        var branch = branchId is > 0 ? branches.FirstOrDefault(b => b.BranchId == branchId) : branches.Count == 1 ? branches[0] : null;
        if (branchId is > 0 && branch is null) return StatusCode(403, Fail("BRANCH_NOT_ALLOWED", "This branch is not mapped to the user."));
        if (branch is null)
            return allowTicket ? Ok(Choices(user, branches, null)) : BadRequest(Fail("BRANCH_REQUIRED", "Choose a branch."));

        var roles = user.IsSuperAdmin
            ? new List<string> { "Administrator" }
            : (await con.QueryAsync<string>(
                @"SELECT DISTINCT r.Name FROM dbo.Userroles ur INNER JOIN dbo.roles r ON r.Id = ur.RoleId
                  WHERE ur.UserId = @id AND ur.IsActive = 1 AND (ur.Branch_ID IS NULL OR ur.Branch_ID = @b) AND r.Name <> ''",
                new { id = user.Id, b = branch.BranchId })).ToList();
        if (roles.Count == 0) return StatusCode(403, Fail("NO_ROLE", "No active role for this user in this branch."));

        var active = role is { Length: > 0 } ? roles.FirstOrDefault(r => string.Equals(r, role, StringComparison.OrdinalIgnoreCase))
                   : roles.Count == 1 ? roles[0] : null;
        if (role is { Length: > 0 } && active is null) return StatusCode(403, Fail("ROLE_NOT_ALLOWED", "The user does not hold this role in this branch."));
        if (active is null)
            return allowTicket ? Ok(Choices(user, new List<BranchRow> { branch }, roles)) : BadRequest(Fail("ROLE_REQUIRED", "Choose a role."));

        var (refresh, hash) = tokens.NewRefreshToken();
        await con.ExecuteAsync("dbo.usp_Auth_RefreshToken_Create",
            new { TokenHash = hash, FamilyId = Guid.NewGuid(), UserId = user.Id, CompanyId = branch.CompanyId, BranchId = branch.BranchId,
                  RoleName = active, ExpiresOn = DateTime.Now.AddDays(options.CurrentValue.RefreshTokenDays),
                  CreatedIp = ClientIp(), UserAgent = Request.Headers.UserAgent.ToString() },
            commandType: CommandType.StoredProcedure);
        return Ok(TokenResponse(user, branch, active, refresh));
    }

    private object Choices(UserRow user, List<BranchRow> branches, List<string>? roles)
    {
        var ticket = tokens.CreateToken(new[] { new Claim("sub", user.Id.ToString()) }, TokenUse.Login, TimeSpan.FromMinutes(5));
        return new
        {
            success = true, requiresContext = true, ticket,
            branches = branches.Select(b => new { branchId = b.BranchId, branchName = b.BranchName }),
            roles
        };
    }

    private object TokenResponse(UserRow user, BranchRow branch, string? role, string refreshToken)
    {
        var o = options.CurrentValue;
        var claims = new List<Claim>
        {
            new("sub", user.Id.ToString()),
            new("username", user.Username),
            new("name", string.IsNullOrWhiteSpace(user.FullName) ? user.Username : user.FullName!),
            new("CompanyId", branch.CompanyId.ToString()),
            new("BranchId", branch.BranchId.ToString()),
            new("BranchName", branch.BranchName),
            new("IsSuperAdmin", user.IsSuperAdmin ? "true" : "false")
        };
        if (role is { Length: > 0 }) claims.Add(new Claim("ActiveRole", role));
        return new
        {
            success = true,
            tokenType = "Bearer",
            accessToken = tokens.CreateToken(claims, TokenUse.Access, TimeSpan.FromMinutes(o.AccessTokenMinutes)),
            expiresIn = o.AccessTokenMinutes * 60,
            refreshToken,
            user = new { id = user.Id, name = user.FullName ?? user.Username, branchId = branch.BranchId, branchName = branch.BranchName, activeRole = role }
        };
    }

    private bool IsAccessToken(out int userId)
    {
        userId = 0;
        return User.FindFirstValue(TokenUse.ClaimType) == TokenUse.Access
               && int.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out userId) && userId > 0;
    }

    internal static string? PasswordProblem(string? password)
    {
        if (string.IsNullOrEmpty(password) || password.Length < 8) return "Use at least 8 characters.";
        if (!password.Any(char.IsUpper) || !password.Any(char.IsLower) || !password.Any(char.IsDigit))
            return "Use upper-case and lower-case letters and at least one digit.";
        return null;
    }

    private string? ClientIp() => HttpContext.Connection.RemoteIpAddress?.ToString();

    private static object Fail(string code, string message) => new { success = false, code, message };
}
