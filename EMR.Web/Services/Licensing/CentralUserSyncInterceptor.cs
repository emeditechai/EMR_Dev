using EMR.Web.Models.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;

namespace EMR.Web.Services.Licensing;

/// <summary>
/// Central user register (SQLScripts/2470): after the application saves a new user, or changes a user's username or company,
/// the user is registered / updated in Central_Users and its Users.CentralUserID is stored. Covers every screen that
/// creates or edits a login through the application's data layer (User Master, doctor, corporate and franchise logins).
/// Runs after the save has committed and never fails it: a central problem is only logged (Companies > Sync Users catches up).
/// </summary>
public sealed class CentralUserSyncInterceptor(ICentralUserRegistry registry, ILogger<CentralUserSyncInterceptor> logger) : SaveChangesInterceptor
{
    // the users touched by the save in progress, per context (one context = one request)
    private readonly System.Runtime.CompilerServices.ConditionalWeakTable<DbContext, List<User>> _pending = new();

    private void Collect(DbContext? context)
    {
        if (context is null) return;
        var users = context.ChangeTracker.Entries<User>()
            .Where(e => e.State == EntityState.Added
                        || (e.State == EntityState.Modified
                            && (e.Property(u => u.Username).IsModified || e.Property(u => u.CompanyId).IsModified)))
            .Select(e => e.Entity)
            .ToList();
        _pending.AddOrUpdate(context, users);
    }

    private List<User> Take(DbContext? context)
    {
        if (context is null || !_pending.TryGetValue(context, out var users)) return [];
        _pending.Remove(context);
        return users;
    }

    public override InterceptionResult<int> SavingChanges(DbContextEventData eventData, InterceptionResult<int> result)
    {
        Collect(eventData.Context);
        return result;
    }

    public override ValueTask<InterceptionResult<int>> SavingChangesAsync(DbContextEventData eventData, InterceptionResult<int> result,
        CancellationToken cancellationToken = default)
    {
        Collect(eventData.Context);
        return ValueTask.FromResult(result);
    }

    public override int SavedChanges(SaveChangesCompletedEventData eventData, int result)
    {
        var users = Take(eventData.Context);
        if (users.Count > 0)
        {
            var ids = users.Where(u => u.Id > 0).Select(u => u.Id).ToList();
            _ = Task.Run(async () => { foreach (var id in ids) await SyncAsync(id); });   // synchronous save: in the background
        }
        return result;
    }

    public override async ValueTask<int> SavedChangesAsync(SaveChangesCompletedEventData eventData, int result,
        CancellationToken cancellationToken = default)
    {
        foreach (var u in Take(eventData.Context))
        {
            if (u.Id <= 0) continue;
            var r = await SyncAsync(u.Id);
            if (r?.Ok == true && r.CentralUserId is > 0) u.CentralUserID = r.CentralUserId;   // the tracked entity shows it too
        }
        return result;
    }

    public override void SaveChangesFailed(DbContextErrorEventData eventData) => Take(eventData.Context);

    public override Task SaveChangesFailedAsync(DbContextErrorEventData eventData, CancellationToken cancellationToken = default)
    {
        Take(eventData.Context);
        return Task.CompletedTask;
    }

    private async Task<CentralUserResult?> SyncAsync(int userId)
    {
        try
        {
            var r = await registry.SyncUserAsync(userId);
            if (!r.Ok && r.Status != "SKIPPED")
                logger.LogWarning("Central user register: user {UserId} - {Status}: {Message}", userId, r.Status, r.Message);
            return r;
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Central user register: user {UserId} not synced", userId);
            return null;
        }
    }
}
