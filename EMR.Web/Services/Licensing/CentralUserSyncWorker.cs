namespace EMR.Web.Services.Licensing;

/// <summary>
/// Central user register (SQLScripts/2470 / 2471): registers, in the background, the users the central server could not take
/// when they were created or changed (it was unreachable) - Users.CentralUserID empty, or Users.CentralSyncPending = 1.
/// Built to cost next to nothing:
///   * nothing pending -> one small query on the application database per run, the central server is not contacted;
///   * at most <see cref="BatchSize"/> users per run; the next run comes sooner only while a backlog remains;
///   * the central server unreachable -> the batch stops at once and the wait doubles (5, 10, 20 up to 30 minutes);
///   * a user that cannot be registered for a lasting reason (a real username clash, no central company) is retried after
///     <see cref="ProblemRetry"/>, or as soon as its username changes - not on every run;
///   * first run a minute after start-up, so start-up is not slowed. Never throws; authentication is not involved.
/// SQLScripts/2487 / 2488: each run first makes the central removals queued by Company > Remove data (a deleted company, the
/// users of a company cleared, any user deleted - trg_Users_CentralRemoval, 2489) that could not be made at the time - one
/// small query when none is queued.
/// SQLScripts/2489 / 2490: a user whose username another installation holds is skipped (marked on the user, not retried
/// until its username changes); every <see cref="SweepInterval"/> the central rows of users no longer in this installation
/// are removed (kept in Central_Delete_Audit) - a mass removal is refused (wrong database?).
/// </summary>
public sealed class CentralUserSyncWorker(ICentralUserRegistry registry, ICentralCompanyRegistry companies, ILogger<CentralUserSyncWorker> logger) : BackgroundService
{
    private const int BatchSize = 50;
    private static readonly TimeSpan FirstRun = TimeSpan.FromMinutes(1);
    private static readonly TimeSpan NormalInterval = TimeSpan.FromMinutes(5);
    private static readonly TimeSpan BacklogInterval = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan MaxBackoff = TimeSpan.FromMinutes(30);
    private static readonly TimeSpan ProblemRetry = TimeSpan.FromHours(6);
    private static readonly TimeSpan SweepInterval = TimeSpan.FromHours(6);
    private DateTime _lastSweep = DateTime.MinValue;

    // users that failed for a lasting reason: when, and under which username (a new username is tried at once)
    private readonly Dictionary<int, (string Username, DateTime At)> _problems = new();
    private TimeSpan _backoff = NormalInterval;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!registry.Configured)
        {
            logger.LogInformation("Central user sync: no central licence login on this server - not started.");
            return;
        }
        try { await Task.Delay(FirstRun, stoppingToken); } catch (OperationCanceledException) { return; }

        while (!stoppingToken.IsCancellationRequested)
        {
            TimeSpan wait;
            try { wait = await RunOnceAsync(stoppingToken); }
            catch (OperationCanceledException) { return; }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "Central user sync: run failed");
                wait = NextBackoff();
            }
            try { await Task.Delay(wait, stoppingToken); } catch (OperationCanceledException) { return; }
        }
    }

    private TimeSpan NextBackoff()
    {
        var wait = _backoff;
        _backoff = TimeSpan.FromTicks(Math.Min(_backoff.Ticks * 2, MaxBackoff.Ticks));
        return wait;
    }

    /// <summary>One pass; returns how long to wait before the next one.</summary>
    private async Task<TimeSpan> RunOnceAsync(CancellationToken ct)
    {
        // removals first: a deleted company's code must not stay held centrally
        var removed = await companies.ProcessRemovalsAsync();
        if (removed.Done > 0)
            logger.LogInformation("Central register: {Done} queued removal(s) made ({Companies} company, {Users} user row(s))", removed.Done, removed.Companies, removed.Users);
        if (removed.Pending > 0 && removed.Error is not null) return NextBackoff();   // the central server is not reachable
        ct.ThrowIfCancellationRequested();

        // users deleted here without the queue (before 2489, or by a restore): their central rows go, a few times a day
        if (DateTime.UtcNow - _lastSweep >= SweepInterval)
        {
            var swept = await registry.RemoveDeletedUsersAsync(null, "Central user sync (background)", guard: true);
            if (swept >= 0) _lastSweep = DateTime.UtcNow;
            ct.ThrowIfCancellationRequested();
        }

        // a few more than one batch, so users parked for a lasting problem do not hide the others
        var pending = await registry.PendingAsync(BatchSize * 4);
        var now = DateTime.UtcNow;
        var due = pending
            .Where(p => !_problems.TryGetValue(p.UserId, out var pr)
                        || !string.Equals(pr.Username, p.Username, StringComparison.OrdinalIgnoreCase)
                        || now - pr.At >= ProblemRetry)
            .Take(BatchSize)
            .ToList();
        if (due.Count == 0)
        {
            _backoff = NormalInterval;
            return NormalInterval;                                  // nothing to do: the central server was not contacted
        }

        int done = 0, parked = 0, skipped = 0;
        foreach (var (userId, username) in due)
        {
            ct.ThrowIfCancellationRequested();
            var r = await registry.SyncUserAsync(userId);
            if (r.Ok)
            {
                done++;
                _problems.Remove(userId);
                continue;
            }
            if (r.Duplicate)
            {
                // another installation holds the username: marked skipped on the user (it leaves the pending list)
                skipped++;
                _problems.Remove(userId);
                continue;
            }
            if (r.Status == "UNAVAILABLE")
            {
                // the central server is still not reachable: stop here, try again later (longer each time)
                if (done > 0) logger.LogInformation("Central user sync: {Done} user(s) registered before the central server became unreachable", done);
                return NextBackoff();
            }
            _problems[userId] = (username, now);                   // lasting problem: not retried on every run
            parked++;
            logger.LogWarning("Central user sync: user {UserId} ({Username}) not registered - {Status}: {Message}", userId, username, r.Status, r.Message);
        }

        _backoff = NormalInterval;
        if (done > 0) logger.LogInformation("Central user sync: {Done} user(s) registered in the central user register", done);
        if (skipped > 0) logger.LogInformation("Central user sync: {Skipped} user(s) skipped - their username is registered by another installation", skipped);
        // forget parked users that are no longer pending (synced from the profile, or fixed)
        var stillPending = pending.Select(p => p.UserId).ToHashSet();
        foreach (var id in _problems.Keys.Where(id => !stillPending.Contains(id)).ToList()) _problems.Remove(id);
        // a full batch went through: more may be waiting
        return done + parked + skipped >= BatchSize ? BacklogInterval : NormalInterval;
    }
}
