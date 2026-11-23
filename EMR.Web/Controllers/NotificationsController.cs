using EMR.Shared.Security;
using EMR.Web.Extensions;
using EMR.Web.Services.Notifications;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// The bell (SQLScripts/2263): every signed-in user reads and clears their own notifications. Not a page that is
/// granted - each call works only on the rows of the login making it (the user id comes from the login).
/// </summary>
[Authorize]
[PublicEndpoint]
public class NotificationsController(INotificationService notifications) : Controller
{
    /// <summary>"View all": the full list with All / Unread and paging.</summary>
    [HttpGet]
    public IActionResult Index() => View();

    [HttpGet]
    public async Task<IActionResult> Feed(int top = 15, long? beforeId = null, bool unreadOnly = false)
    {
        var (items, unread) = await notifications.ListAsync(User.GetUserId(), Math.Clamp(top, 1, 50), beforeId, unreadOnly);
        return Json(new { success = true, items, unreadCount = unread });
    }

    [HttpPost]
    public async Task<IActionResult> MarkRead(long id)
        => Json(new { success = true, unreadCount = await notifications.MarkReadAsync(User.GetUserId(), id) });

    [HttpPost]
    public async Task<IActionResult> MarkAllRead()
        => Json(new { success = true, unreadCount = await notifications.MarkReadAsync(User.GetUserId(), null) });

    [HttpPost]
    public async Task<IActionResult> Dismiss(long id)
        => Json(new { success = true, unreadCount = await notifications.DismissAsync(User.GetUserId(), id) });
}
