using System.Data;
using Dapper;
using EMR.Web.Data;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.SignalR;

namespace EMR.Web.Services.Notifications;

/// <summary>
/// Live channel of the bell (SQLScripts/2263). A signed-in user's open tabs connect here; SignalR addresses them by
/// the login's user id (the NameIdentifier claim), so a notification reaches exactly its recipient. Nothing is sent
/// from the browser to the server through it - reads and changes go through NotificationsController.
/// </summary>
[Authorize]
public sealed class NotificationHub : Hub
{
}

/// <summary>A notification as the bell shows it (also the live push payload).</summary>
public sealed class NotificationItem
{
    public long NotificationId { get; set; }
    public string Category { get; set; } = "";
    public string Severity { get; set; } = "INFO";
    public string Title { get; set; } = "";
    public string Message { get; set; } = "";
    public string? Link { get; set; }
    public string? RefModule { get; set; }
    public long? RefId { get; set; }
    public DateTime CreatedOn { get; set; }
    public bool IsRead { get; set; }
    public DateTime? ReadOn { get; set; }
    public string? CreatedByName { get; set; }
}

public interface INotificationService
{
    /// <summary>A bill saved with a discount: tells the user chosen as "Approved by". Never throws - a notification
    /// must not fail the payment it reports.</summary>
    Task NotifyDiscountApprovalAsync(int paymentHeaderId, int? actorUserId);

    Task<(List<NotificationItem> Items, int UnreadCount)> ListAsync(int userId, int top, long? beforeId, bool unreadOnly);
    Task<int> MarkReadAsync(int userId, long? notificationId);
    Task<int> DismissAsync(int userId, long notificationId);
}

public sealed class NotificationService(
    IDbConnectionFactory db,
    IHubContext<NotificationHub> hub,
    ILogger<NotificationService> logger) : INotificationService
{
    private sealed class CreatedRow
    {
        public long NotificationId { get; set; }
        public int UserId { get; set; }
        public string Category { get; set; } = "";
        public string Severity { get; set; } = "INFO";
        public string Title { get; set; } = "";
        public string Message { get; set; } = "";
        public string? Link { get; set; }
        public string? RefModule { get; set; }
        public long? RefId { get; set; }
        public DateTime CreatedOn { get; set; }
        public int UnreadCount { get; set; }
    }

    public async Task NotifyDiscountApprovalAsync(int paymentHeaderId, int? actorUserId)
    {
        try
        {
            using var con = db.CreateConnection();
            var row = await con.QueryFirstOrDefaultAsync<CreatedRow>("dbo.usp_Notification_DiscountApproval",
                new { PaymentHeaderId = paymentHeaderId, ActorUserId = actorUserId }, commandType: CommandType.StoredProcedure);
            if (row != null) await PushAsync(row);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "[NOTIFY] Discount approval notification for payment {PaymentHeaderId} not created", paymentHeaderId);
        }
    }

    /// <summary>Live push to every open tab of the recipient; when none is open the bell picks it up on next load.</summary>
    private async Task PushAsync(CreatedRow row)
    {
        try
        {
            await hub.Clients.User(row.UserId.ToString()).SendAsync("notification", new
            {
                item = new NotificationItem
                {
                    NotificationId = row.NotificationId, Category = row.Category, Severity = row.Severity, Title = row.Title,
                    Message = row.Message, Link = row.Link, RefModule = row.RefModule, RefId = row.RefId, CreatedOn = row.CreatedOn
                },
                unreadCount = row.UnreadCount
            });
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "[NOTIFY] Live push of notification {NotificationId} failed (kept in the bell)", row.NotificationId);
        }
    }

    public async Task<(List<NotificationItem> Items, int UnreadCount)> ListAsync(int userId, int top, long? beforeId, bool unreadOnly)
    {
        using var con = db.CreateConnection();
        using var m = await con.QueryMultipleAsync("dbo.usp_Notification_List",
            new { UserId = userId, Top = top, BeforeId = beforeId, UnreadOnly = unreadOnly }, commandType: CommandType.StoredProcedure);
        var items = (await m.ReadAsync<NotificationItem>()).ToList();
        var unread = await m.ReadFirstAsync<int>();
        return (items, unread);
    }

    public async Task<int> MarkReadAsync(int userId, long? notificationId)
    {
        using var con = db.CreateConnection();
        var unread = await con.QueryFirstAsync<int>("dbo.usp_Notification_MarkRead",
            new { UserId = userId, NotificationId = notificationId }, commandType: CommandType.StoredProcedure);
        await SyncTabsAsync(userId, unread);
        return unread;
    }

    public async Task<int> DismissAsync(int userId, long notificationId)
    {
        using var con = db.CreateConnection();
        var unread = await con.QueryFirstAsync<int>("dbo.usp_Notification_Dismiss",
            new { UserId = userId, NotificationId = notificationId }, commandType: CommandType.StoredProcedure);
        await SyncTabsAsync(userId, unread);
        return unread;
    }

    /// <summary>Read / dismissed in one tab: the user's other open tabs update their badge too.</summary>
    private async Task SyncTabsAsync(int userId, int unreadCount)
    {
        try { await hub.Clients.User(userId.ToString()).SendAsync("unread", new { unreadCount }); }
        catch (Exception ex) { logger.LogDebug(ex, "[NOTIFY] Tab sync for user {UserId} failed", userId); }
    }
}
