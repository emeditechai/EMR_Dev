using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace EMR.Shared.Security;

/// <summary>
/// Wrong-password counting and the temporary lockout, shared by the web sign-in and api/auth/login.
/// Users.IsLockedOut remains the administrator's permanent lock; Lockout_Until is the automatic one.
/// </summary>
public interface ILoginSecurity
{
    /// <summary>The time the account unlocks, when it is locked right now.</summary>
    Task<DateTime?> LockedUntilAsync(int userId);

    /// <summary>Counts a wrong password; returns the unlock time when this attempt locked the account.</summary>
    Task<DateTime?> RecordFailureAsync(int userId);

    /// <summary>Counts a wrong password (Hospital Settings > Login Retry Count, SQLScripts/2320): the unlock time when this
    /// attempt locked the account, and the attempts left before the lock (null when wrong passwords are not counted).</summary>
    Task<(DateTime? LockedUntil, int? AttemptsLeft)> RecordFailureDetailAsync(int userId);

    Task RecordSuccessAsync(int userId);

    /// <summary>After a counted wrong password: whether to send the user a security alert now (Hospital Settings >
    /// Login Alert After Wrong Attempts, SQLScripts/2383), with whom to send it to.</summary>
    Task<LoginFailureAlert?> FailureAlertAsync(int userId, bool justLocked);
}

/// <summary>A row of dbo.usp_Auth_Login_FailureAlert (SQLScripts/2383).</summary>
public sealed class LoginFailureAlert
{
    public bool ShouldAlert { get; set; }
    public int FailedAttempts { get; set; }
    public DateTime? LockedUntil { get; set; }
    public string? UserName { get; set; }
    public string? Email { get; set; }
    public string? Mobile { get; set; }
    public int? BranchId { get; set; }
}

public sealed class SqlLoginSecurity(string connectionString, IOptionsMonitor<ApiAuthOptions> options) : ILoginSecurity
{
    public async Task<DateTime?> LockedUntilAsync(int userId)
    {
        await using var con = new SqlConnection(connectionString);
        var until = await con.ExecuteScalarAsync<DateTime?>("SELECT Lockout_Until FROM dbo.Users WHERE Id = @userId", new { userId });
        return until > DateTime.Now ? until : null;
    }

    public async Task<DateTime?> RecordFailureAsync(int userId) => (await RecordFailureDetailAsync(userId)).LockedUntil;

    public async Task<(DateTime? LockedUntil, int? AttemptsLeft)> RecordFailureDetailAsync(int userId)
    {
        var o = options.CurrentValue;
        await using var con = new SqlConnection(connectionString);
        // the limit and the 10-minute lock come from Hospital Settings; the configured values are passed for older databases
        var row = await con.QuerySingleOrDefaultAsync<(int? FailedLoginAttempts, DateTime? Lockout_Until, int? RetryCount)>(
            "dbo.usp_Auth_Login_RecordFailure",
            new { UserId = userId, MaxAttempts = Math.Max(1, o.MaxFailedAttempts), LockMinutes = Math.Max(1, o.LockoutMinutes) },
            commandType: CommandType.StoredProcedure);
        var locked = row.Lockout_Until > DateTime.Now ? row.Lockout_Until : null;
        int? left = row.RetryCount is > 0 ? Math.Max(0, row.RetryCount.Value - (row.FailedLoginAttempts ?? 0)) : null;
        return (locked, left);
    }

    public async Task<LoginFailureAlert?> FailureAlertAsync(int userId, bool justLocked)
    {
        await using var con = new SqlConnection(connectionString);
        return await con.QuerySingleOrDefaultAsync<LoginFailureAlert>("dbo.usp_Auth_Login_FailureAlert",
            new { UserId = userId, JustLocked = justLocked }, commandType: CommandType.StoredProcedure);
    }

    public async Task RecordSuccessAsync(int userId)
    {
        await using var con = new SqlConnection(connectionString);
        await con.ExecuteAsync("dbo.usp_Auth_Login_RecordSuccess", new { UserId = userId }, commandType: CommandType.StoredProcedure);
    }
}
