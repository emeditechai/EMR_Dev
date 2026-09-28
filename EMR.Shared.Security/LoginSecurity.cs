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

    Task RecordSuccessAsync(int userId);
}

public sealed class SqlLoginSecurity(string connectionString, IOptionsMonitor<ApiAuthOptions> options) : ILoginSecurity
{
    public async Task<DateTime?> LockedUntilAsync(int userId)
    {
        await using var con = new SqlConnection(connectionString);
        var until = await con.ExecuteScalarAsync<DateTime?>("SELECT Lockout_Until FROM dbo.Users WHERE Id = @userId", new { userId });
        return until > DateTime.Now ? until : null;
    }

    public async Task<DateTime?> RecordFailureAsync(int userId)
    {
        var o = options.CurrentValue;
        await using var con = new SqlConnection(connectionString);
        var row = await con.QuerySingleOrDefaultAsync<(int FailedLoginAttempts, DateTime? Lockout_Until)>(
            "dbo.usp_Auth_Login_RecordFailure",
            new { UserId = userId, MaxAttempts = Math.Max(1, o.MaxFailedAttempts), LockMinutes = Math.Max(1, o.LockoutMinutes) },
            commandType: CommandType.StoredProcedure);
        return row.Lockout_Until > DateTime.Now ? row.Lockout_Until : null;
    }

    public async Task RecordSuccessAsync(int userId)
    {
        await using var con = new SqlConnection(connectionString);
        await con.ExecuteAsync("dbo.usp_Auth_Login_RecordSuccess", new { UserId = userId }, commandType: CommandType.StoredProcedure);
    }
}
