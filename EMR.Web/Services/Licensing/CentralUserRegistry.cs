using System.Collections.Concurrent;
using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace EMR.Web.Services.Licensing;

/// <summary>Result of a central user check / save: Status FREE / TAKEN (check), CREATED / UPDATED / UNCHANGED / CONFLICT
/// (save), DUPLICATE (SQLScripts/2490: the username is held by ANOTHER installation - usernames are unique across all of
/// them, the platform super admin excepted; the sync skips such a user), NO_COMPANY (the user has no company, or its company is not / cannot be in Central_Company - no central user is
/// created without its company: FK), UNAVAILABLE (central database not reachable).</summary>
public sealed record CentralUserResult(string Status, string Message, long? CentralUserId = null)
{
    public bool Ok => Status is "CREATED" or "UPDATED" or "UNCHANGED";
    public bool Taken => Status is "TAKEN" or "CONFLICT" or "DUPLICATE";
    /// <summary>SQLScripts/2490: held by another installation (the user is skipped by the sync, not retried).</summary>
    public bool Duplicate => Status == "DUPLICATE";
    /// <summary>The user cannot be created: its company has no central company.</summary>
    public bool NoCompany => Status == "NO_COMPANY";
}

/// <summary>Result of "Sync Users" for a company.</summary>
public sealed record CentralUserSyncSummary(int Total, int Created, int Updated, int Unchanged, int Failed, List<string> Problems, string? Error)
{
    /// <summary>SQLScripts/2490: users not synced because another installation holds their username (not counted in Failed).</summary>
    public int Skipped { get; init; }
    /// <summary>SQLScripts/2489 / 2490: central rows removed because their user no longer exists in this installation.</summary>
    public int Removed { get; init; }
    /// <summary>The users not synced (id, username, reason) - the profile links each to its Edit page.</summary>
    public List<CentralUserProblem> Users { get; init; } = [];
}

public sealed record CentralUserProblem(int UserId, string Username, string Status, string Message);

/// <summary>
/// The central user register (Central_Lic_DB.dbo.Central_Users, SQLScripts/2470): every sign-in, Username unique across
/// ALL installations since SQLScripts/2490 (the platform super admin ecare360plusadmin@emeditechplus.com excepted: unique per
/// installation, each registers it); before that unique per INSTALLATION (Central_Company.InstanceKey - <see cref="ICentralCompanyRegistry.InstanceKey"/>); each row also carries the
/// user's central company (Central_Company.ID - <see cref="ICentralCompanyRegistry.ResolveAsync"/>). The
/// application database keeps the central ID in Users.CentralUserID (2471). Authentication is unchanged; this only records.
/// Uses the licensing connection; never throws.
/// </summary>
public interface ICentralUserRegistry
{
    /// <summary>Is the username free in this installation (every company of it)?</summary>
    Task<CentralUserResult> CheckAsync(int companyId, string username, int? appUserId = null, long? centralUserId = null);

    /// <summary>Create / update the user's central row (appUserId null = reserve the username first, User Master).</summary>
    Task<CentralUserResult> SaveAsync(int companyId, string username, int? appUserId, long? centralUserId);

    /// <summary>Before creating a user / changing a username: the company must be (or become) a central company. NO_COMPANY
    /// blocks the save; UNAVAILABLE (central database not reachable) does not.</summary>
    Task<CentralUserResult> EnsureCompanyAsync(int companyId);

    /// <summary>Drops a reservation whose application user was never saved.</summary>
    Task ReleaseAsync(long centralUserId);

    /// <summary>Registers one application user (by its Users.Id) and stores the central ID on it.</summary>
    Task<CentralUserResult> SyncUserAsync(int appUserId);

    /// <summary>Registers every user of a company (or only those without a central ID yet).</summary>
    Task<CentralUserSyncSummary> SyncCompanyAsync(int companyId, bool onlyPending);

    /// <summary>False when this server has no login for the central licence database (nothing to sync).</summary>
    bool Configured { get; }

    /// <summary>Background sync's work list: users not registered centrally, or changed while it was unreachable.</summary>
    Task<List<(int UserId, string Username)>> PendingAsync(int top);

    /// <summary>SQLScripts/2489 / 2490: removes the central rows of this installation (optionally of one application company)
    /// whose user no longer exists here, and abandoned reservations - each kept in Central_Delete_Audit. <paramref name="guard"/>
    /// (the background run) refuses a mass removal (over half of 10+ rows), which points at a wrong database rather than
    /// deleted users. Returns the rows removed, or -1 when it could not run. Never throws.</summary>
    Task<int> RemoveDeletedUsersAsync(int? companyId, string deletedBy, bool guard);
}

public sealed class CentralUserRegistry(
    IOptions<LicensingOptions> options,
    ICentralCompanyRegistry companies,
    IConfiguration configuration,
    ILogger<CentralUserRegistry> logger) : ICentralUserRegistry
{
    private readonly LicensingOptions _o = options.Value;
    private int Timeout => Math.Max(5, _o.RemoteConnectionTimeoutSeconds * 2);
    private SqlConnection Central() => new(_o.CentralConnectionString);
    private SqlConnection App() => new(configuration.GetConnectionString("DefaultConnection"));

    public bool Configured => !string.IsNullOrWhiteSpace(_o.CentralUsername) && !string.IsNullOrEmpty(_o.CentralPassword);

    public async Task<List<(int UserId, string Username)>> PendingAsync(int top)
    {
        await using var app = App();
        return (await app.QueryAsync<UserRow>("dbo.usp_User_CentralPending", new { Top = top }, commandType: CommandType.StoredProcedure))
            .Select(u => (u.Id, u.Username)).ToList();
    }

    // central company of an application company, kept 5 minutes (a "Sync Users" of many users asks once)
    private static readonly ConcurrentDictionary<int, (int Id, DateTime At)> CompanyCache = new();

    private sealed class CompanyRow { public int CompanyId { get; set; } public string CompanyCode { get; set; } = ""; public string CompanyName { get; set; } = ""; }
    private sealed class CheckRow
    {
        public bool Taken { get; set; }
        public long ID { get; set; }
        public int? ApplicationUserID { get; set; }
        public string? Scope { get; set; }            // INSTALLATION | GLOBAL (SQLScripts/2490)
    }
    private sealed class UserRow
    {
        public int Id { get; set; }
        public string Username { get; set; } = "";
        public int? CompanyId { get; set; }
        public long? CentralUserID { get; set; }
        public string? CentralSyncSkipReason { get; set; }
    }
    private sealed class SaveRow
    {
        public string Status { get; set; } = "";
        public string Message { get; set; } = "";
        public long? ID { get; set; }
        public string? Scope { get; set; }            // INSTALLATION | GLOBAL (SQLScripts/2490)
    }
    private sealed class InstanceRow { public long ID { get; set; } public string Username { get; set; } = ""; public int? ApplicationUserID { get; set; } public int AgeMinutes { get; set; } }

    private sealed class RemovedRow { public string Status { get; set; } = ""; public int Users { get; set; } }

    /// <summary>SQLScripts/2491: held by another installation - a standard message; nothing about the other client is told.</summary>
    private const string GlobalMessage = "This e-mail is already in use as a sign-in and cannot be used. Please use a different e-mail address.";
    private sealed class HolderRow
    {
        public long ID { get; set; }
        public string Username { get; set; } = "";
        public string InstanceKey { get; set; } = "";
        public int? ApplicationUserID { get; set; }
        public int AgeMinutes { get; set; }
    }

    /// <summary>A reservation (central row without its application user) older than this was abandoned (a create that never finished).</summary>
    private const int AbandonedReservationMinutes = 10;

    /// <summary>
    /// A username of this installation is held centrally by another row. The application database is the source of truth
    /// (its usernames are unique in the whole installation), so the holder is checked against it: its user was removed ->
    /// the row is removed; renamed (while the central server was unreachable) -> the row is updated to the current name;
    /// a reservation that some user carries -> linked to that user; an abandoned reservation -> released. True when the
    /// holder no longer holds <paramref name="username"/> (the caller retries once); false for a real clash, or a
    /// reservation of a create still in progress.
    /// </summary>
    private async Task<bool> ReconcileHolderAsync(long holderId, string username)
    {
        try
        {
            HolderRow? h;
            await using (var cn = Central())
                h = await cn.QueryFirstOrDefaultAsync<HolderRow>("dbo.usp_CentralUser_Get", new { CentralUserID = holderId },
                    commandType: CommandType.StoredProcedure, commandTimeout: Timeout);
            if (h is null) return true;                                            // gone meanwhile
            if (!string.Equals(h.InstanceKey, companies.InstanceKey, StringComparison.OrdinalIgnoreCase)) return false;

            UserRow? owner;
            await using (var app = App())
                owner = h.ApplicationUserID is > 0
                    ? await app.QueryFirstOrDefaultAsync<UserRow>("dbo.usp_User_CentralGet", new { UserId = h.ApplicationUserID }, commandType: CommandType.StoredProcedure)
                    : await app.QueryFirstOrDefaultAsync<UserRow>("dbo.usp_User_CentralFindByCentralId", new { CentralUserID = h.ID }, commandType: CommandType.StoredProcedure);

            // a reservation belongs to the user that carries its ID AND the reserved username (anything else is unrelated)
            if (h.ApplicationUserID is null && owner is not null
                && !string.Equals(owner.Username?.Trim(), h.Username, StringComparison.OrdinalIgnoreCase))
                owner = null;

            if (owner is null)
            {
                if (h.ApplicationUserID is > 0)
                {
                    // its application user does not exist any more in this installation: the central row is stale
                    await using var cn = Central();
                    await cn.ExecuteAsync("dbo.usp_CentralUser_Remove", new { CentralUserID = h.ID, companies.InstanceKey },
                        commandType: CommandType.StoredProcedure, commandTimeout: Timeout);
                    logger.LogInformation("Central user register: stale row {Id} ({Username}) removed - its user no longer exists", h.ID, h.Username);
                    return true;
                }
                if (h.AgeMinutes < AbandonedReservationMinutes) return false;        // a create in progress right now
                await ReleaseAsync(h.ID);                                            // abandoned reservation
                logger.LogInformation("Central user register: abandoned reservation {Id} ({Username}) released", h.ID, h.Username);
                return true;
            }

            // the holder's user exists: does it still have this username?
            if (string.Equals(owner.Username?.Trim(), username, StringComparison.OrdinalIgnoreCase))
            {
                // a reservation carried by the user that really has the name: link it, the clash is real
                if (h.ApplicationUserID is null) await SyncRowAsync(owner, reconcile: false);
                return false;
            }
            // renamed while the central register was not reachable: bring its row up to date (frees the name)
            var fixedRow = await SyncRowAsync(owner, reconcile: false);
            logger.LogInformation("Central user register: row {Id} moved from {Old} to {New} ({Status})", h.ID, h.Username, owner.Username, fixedRow.Status);
            return fixedRow.Ok;
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Central user register: holder {Id} of {Username} not reconciled", holderId, username);
            return false;
        }
    }

    private async Task<(int? Id, string? Error, bool Unreachable)> CentralCompanyAsync(int companyId, bool pushIfNeeded)
    {
        if (companyId <= 0) return (null, "The user has no company.", false);
        if (CompanyCache.TryGetValue(companyId, out var hit) && hit.At > DateTime.UtcNow.AddMinutes(-5)) return (hit.Id, null, false);
        CompanyRow? c;
        await using (var app = App())
            c = await app.QueryFirstOrDefaultAsync<CompanyRow>("dbo.usp_Company_CentralGet", new { CompanyId = companyId }, commandType: CommandType.StoredProcedure);
        if (c is null) return (null, "The user's company was not found.", false);
        var (id, error, unreachable) = await companies.ResolveAsync(companyId, c.CompanyCode, c.CompanyName, pushIfNeeded);
        if (id is > 0) CompanyCache[companyId] = (id.Value, DateTime.UtcNow);
        return (id, error, unreachable);
    }

    private static CentralUserResult CompanyProblem(string? error, bool unreachable) => unreachable
        ? new("UNAVAILABLE", error ?? "The central register could not be reached.")
        : new("NO_COMPANY", "No user is created without its company in the central company register: "
                            + (error ?? "the company is not registered centrally.") + " Push the company to Central from its profile first.");

    public async Task<CentralUserResult> EnsureCompanyAsync(int companyId)
    {
        try
        {
            var (cid, error, unreachable) = await CentralCompanyAsync(companyId, pushIfNeeded: true);
            return cid is > 0 ? new("UNCHANGED", "") : CompanyProblem(error, unreachable);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Central user register: company {CompanyId} not checked", companyId);
            return new("UNAVAILABLE", "The central register could not be reached.");
        }
    }

    public async Task<CentralUserResult> CheckAsync(int companyId, string username, int? appUserId = null, long? centralUserId = null)
    {
        var name = (username ?? "").Trim().ToLowerInvariant();
        if (name.Length == 0) return new("FREE", "");   // the company is not needed: the name is unique per installation
        try
        {
            // uniqueness is per installation: no need for the company to be registered centrally to check
            async Task<CheckRow?> HolderAsync()
            {
                await using var cn = Central();
                // a row only when another user holds the name: of this installation (INSTALLATION) or another one (GLOBAL, 2490)
                return await cn.QueryFirstOrDefaultAsync<CheckRow>("dbo.usp_CentralUser_Check",
                    new { companies.InstanceKey, Username = name, CentralUserID = centralUserId, ApplicationUserID = appUserId },
                    commandType: CommandType.StoredProcedure, commandTimeout: Timeout);
            }
            var holder = await HolderAsync();
            // held here by a stale row (user renamed / removed while the central server was down) or an abandoned reservation:
            // corrected from the application database, then checked again (another installation's row is never touched)
            if (holder is { Scope: not "GLOBAL" } && await ReconcileHolderAsync(holder.ID, name)) holder = await HolderAsync();
            if (holder is null) return new("FREE", "");
            return holder.Scope == "GLOBAL"
                ? new("DUPLICATE", GlobalMessage)
                : new("TAKEN", GlobalMessage);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Central user register: {Username} not checked", name);
            return new("UNAVAILABLE", "The central user register could not be reached.");
        }
    }

    public Task<CentralUserResult> SaveAsync(int companyId, string username, int? appUserId, long? centralUserId) =>
        SaveCoreAsync(companyId, username, appUserId, centralUserId, reconcile: true);

    private async Task<CentralUserResult> SaveCoreAsync(int companyId, string username, int? appUserId, long? centralUserId, bool reconcile)
    {
        var name = (username ?? "").Trim().ToLowerInvariant();
        if (name.Length == 0) return new("NO_COMPANY", "The user has no username.");
        if (companyId <= 0) return CompanyProblem("the user has no company.", false);
        try
        {
            var (cid, error, unreachable) = await CentralCompanyAsync(companyId, pushIfNeeded: true);
            if (cid is not > 0) return CompanyProblem(error, unreachable);
            await using var cn = Central();
            var r = await cn.QueryFirstAsync<SaveRow>("dbo.usp_CentralUser_Save",
                new { CompanyID = cid, Username = name, ApplicationUserID = appUserId, CentralUserID = centralUserId },
                commandType: CommandType.StoredProcedure, commandTimeout: Timeout);
            if (r.Status == "CONFLICT" && r.Scope == "GLOBAL")
                // SQLScripts/2490: another installation holds the name - usernames are unique across all installations
                return new("DUPLICATE", GlobalMessage + " (Not registered centrally until its e-mail is changed.)", r.ID);
            if (r.Status == "CONFLICT")
            {
                // the name is held by another row of this installation: reconcile it with the application database, retry once
                if (reconcile && r.ID is > 0 && await ReconcileHolderAsync(r.ID.Value, name))
                    return await SaveCoreAsync(companyId, name, appUserId, centralUserId, reconcile: false);
                return new("CONFLICT", r.Message + " Another user of this installation already has it - change this user's username (Settings > Users > Edit) and save: it is then registered centrally.");
            }
            return new(r.Status, r.Message, r.ID);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Central user register: {Username} (user {UserId}) not saved", name, appUserId);
            return new("UNAVAILABLE", "The central user register could not be reached.");
        }
    }

    public async Task ReleaseAsync(long centralUserId)
    {
        try
        {
            await using var cn = Central();
            await cn.ExecuteAsync("dbo.usp_CentralUser_Release", new { CentralUserID = centralUserId },
                commandType: CommandType.StoredProcedure, commandTimeout: Timeout);
        }
        catch (Exception ex) { logger.LogWarning(ex, "Central user register: reservation {Id} not released", centralUserId); }
    }

    public async Task<CentralUserResult> SyncUserAsync(int appUserId)
    {
        try
        {
            UserRow? u;
            await using (var app = App())
                u = await app.QueryFirstOrDefaultAsync<UserRow>("dbo.usp_User_CentralGet", new { UserId = appUserId }, commandType: CommandType.StoredProcedure);
            if (u is null) return new("SKIPPED", "The user was not found.");
            return await SyncRowAsync(u);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Central user register: user {UserId} not synced", appUserId);
            return new("UNAVAILABLE", "The central user register could not be reached.");
        }
    }

    private async Task<CentralUserResult> SyncRowAsync(UserRow u, bool reconcile = true)
    {
        if (u.CompanyId is not > 0) return CompanyProblem("the user has no company.", false);
        var r = await SaveCoreAsync(u.CompanyId.Value, u.Username, u.Id, u.CentralUserID, reconcile);
        await using var app = App();
        if (r.Duplicate)
        {
            // SQLScripts/2489 / 2490: the name belongs to another installation - skipped, not retried until the username changes
            await app.ExecuteAsync("dbo.usp_User_CentralSkip", new { UserId = u.Id, Reason = r.Message }, commandType: CommandType.StoredProcedure);
            if (u.CentralSyncSkipReason is null)
                logger.LogInformation("Central user register: user {UserId} ({Username}) skipped - held by another installation", u.Id, u.Username);
            return r;
        }
        if (r.Ok && r.CentralUserId is > 0)
            // stores the central ID and clears the pending flag (the procedure writes only when something changes)
            await app.ExecuteAsync("dbo.usp_User_CentralSet", new { UserId = u.Id, CentralUserID = r.CentralUserId }, commandType: CommandType.StoredProcedure);
        else if (u.CentralUserID is > 0)
            // a registered user whose change did not reach the central register: the background sync retries it
            await app.ExecuteAsync("dbo.usp_User_CentralMarkPending", new { UserId = u.Id }, commandType: CommandType.StoredProcedure);
        return r;
    }

    public async Task<CentralUserSyncSummary> SyncCompanyAsync(int companyId, bool onlyPending)
    {
        List<UserRow> users;
        try
        {
            await using var app = App();
            users = (await app.QueryAsync<UserRow>("dbo.usp_User_CentralList", new { CompanyId = companyId, OnlyPending = onlyPending },
                commandType: CommandType.StoredProcedure)).ToList();
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Central user register: users of company {CompanyId} not listed", companyId);
            return new(0, 0, 0, 0, 0, [], "The users could not be read.");
        }
        if (users.Count == 0) return new(0, 0, 0, 0, 0, [], null);

        // the company first: a company that cannot be mapped stops the whole sync with one clear reason
        var (cid, error, unreachable) = await CentralCompanyAsync(companyId, pushIfNeeded: true);
        if (cid is not > 0) return new(users.Count, 0, 0, 0, users.Count, [], CompanyProblem(error, unreachable).Message);

        int created = 0, updated = 0, unchanged = 0, failed = 0, skipped = 0;
        var problems = new List<string>();
        var problemUsers = new List<CentralUserProblem>();
        foreach (var u in users)
        {
            var r = await SyncRowAsync(u);
            switch (r.Status)
            {
                case "CREATED": created++; break;
                case "UPDATED": updated++; break;
                case "UNCHANGED": unchanged++; break;
                case "DUPLICATE":
                    // SQLScripts/2490: another installation holds the username - skipped, listed (not a failure)
                    skipped++;
                    if (problemUsers.Count < 50) problemUsers.Add(new(u.Id, u.Username, r.Status, r.Message));
                    break;
                default:
                    failed++;
                    if (problems.Count < 50)
                    {
                        problems.Add($"{u.Username}: {r.Message}");
                        problemUsers.Add(new(u.Id, u.Username, r.Status, r.Message));
                    }
                    break;
            }
        }
        // SQLScripts/2489 / 2490: central rows of this company whose user was deleted here (or abandoned reservations) go
        var removed = await RemoveDeletedUsersAsync(companyId, "Sync Users", guard: false);
        return new(users.Count, created, updated, unchanged, failed, problems, null)
        {
            Users = problemUsers, Skipped = skipped, Removed = Math.Max(0, removed)
        };
    }

    public async Task<int> RemoveDeletedUsersAsync(int? companyId, string deletedBy, bool guard)
    {
        if (!Configured) return -1;
        try
        {
            int? centralCompanyId = null;
            if (companyId is > 0)
            {
                var (cid, _, _) = await CentralCompanyAsync(companyId.Value, pushIfNeeded: false);
                if (cid is not > 0) return 0;                                   // the company is not registered: nothing of it centrally
                centralCompanyId = cid;
            }
            List<InstanceRow> rows;
            await using (var cn = Central())
                rows = (await cn.QueryAsync<InstanceRow>("dbo.usp_CentralUser_ListInstance",
                    new { companies.InstanceKey, CompanyID = centralCompanyId },
                    commandType: CommandType.StoredProcedure, commandTimeout: Timeout)).ToList();
            if (rows.Count == 0) return 0;

            var linked = rows.Where(r => r.ApplicationUserID is > 0).Select(r => r.ApplicationUserID!.Value).Distinct().ToList();
            HashSet<int> existing;
            await using (var app = App())
                existing = (await app.QueryAsync<int>("dbo.usp_User_CentralExisting",
                    new { UserIds = "[" + string.Join(",", linked) + "]" }, commandType: CommandType.StoredProcedure)).ToHashSet();
            var gone = linked.Where(id => !existing.Contains(id)).ToList();

            if (guard && rows.Count >= 10 && gone.Count * 2 > rows.Count)
            {
                logger.LogWarning("Central user register: {Gone} of {Total} central users of this installation have no user here - not removed automatically (wrong database?). Use Sync Users on the company profile.",
                    gone.Count, rows.Count);
                return 0;
            }

            var removed = 0;
            if (gone.Count > 0)
            {
                await using var cn = Central();
                var r = await cn.QueryFirstAsync<RemovedRow>("dbo.usp_CentralUser_RemoveByApp",
                    new { companies.InstanceKey, ApplicationUserIDs = "[" + string.Join(",", gone) + "]", Preview = false,
                          DeletedBy = deletedBy, DeletedFrom = (string?)null, Reference = $"{companies.InstanceKey}: user no longer in the installation",
                          Reason = "USER_DELETED" },
                    commandType: CommandType.StoredProcedure, commandTimeout: Timeout);
                removed += r.Users;
            }
            // reservations never linked to a user (a create that did not finish)
            foreach (var res in rows.Where(r => r.ApplicationUserID is null && r.AgeMinutes >= AbandonedReservationMinutes))
            {
                UserRow? carrier;
                await using (var app = App())
                    carrier = await app.QueryFirstOrDefaultAsync<UserRow>("dbo.usp_User_CentralFindByCentralId", new { CentralUserID = res.ID }, commandType: CommandType.StoredProcedure);
                if (carrier is not null) { await SyncRowAsync(carrier, reconcile: false); continue; }   // its user exists: link it
                await ReleaseAsync(res.ID);
                removed++;
            }
            if (removed > 0)
                logger.LogInformation("Central user register: {Removed} central row(s) of deleted users / abandoned reservations removed ({By})", removed, deletedBy);
            return removed;
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Central user register: deleted users not removed centrally (company {CompanyId})", companyId);
            return -1;
        }
    }
}
