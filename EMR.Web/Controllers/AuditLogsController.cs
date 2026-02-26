using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class AuditLogsController(ApplicationDbContext dbContext) : Controller
{
    public async Task<IActionResult> Index(
        string? search, string? eventType,
        DateTime? dateFrom, DateTime? dateTo,
        int page = 1, int pageSize = 50)
    {
        // Clamp page size to sensible limits
        pageSize = pageSize is 25 or 50 or 100 ? pageSize : 50;
        page = Math.Max(1, page);

        var filter = new AuditLogFilterViewModel
        {
            Search = search?.Trim(),
            EventType = eventType?.Trim(),
            DateFrom = dateFrom,
            DateTo = dateTo,
            Page = page,
            PageSize = pageSize
        };

        // Base query
        var query = from log in dbContext.AuditLogs
                    join user in dbContext.Users on log.UserId equals user.Id into userJoin
                    from user in userJoin.DefaultIfEmpty()
                    join branch in dbContext.BranchMasters on log.BranchId equals branch.BranchId into branchJoin
                    from branch in branchJoin.DefaultIfEmpty()
                    select new { log, username = user != null ? user.Username : "System", branchName = branch != null ? branch.BranchName : "N/A" };

        // Filters
        if (!string.IsNullOrWhiteSpace(filter.EventType))
            query = query.Where(x => x.log.EventType == filter.EventType);

        if (!string.IsNullOrWhiteSpace(filter.Search))
            query = query.Where(x =>
                x.username.Contains(filter.Search) ||
                x.log.ActionName.Contains(filter.Search) ||
                (x.log.Description != null && x.log.Description.Contains(filter.Search)));

        if (filter.DateFrom.HasValue)
            query = query.Where(x => x.log.CreatedDate >= filter.DateFrom.Value);

        if (filter.DateTo.HasValue)
            query = query.Where(x => x.log.CreatedDate < filter.DateTo.Value.AddDays(1));

        // Total count (fast — no projection yet)
        var totalCount = await query.CountAsync();

        // Available event types for filter dropdown (distinct, cheap)
        var eventTypes = await dbContext.AuditLogs
            .Select(x => x.EventType)
            .Where(x => x != null)
            .Distinct()
            .OrderBy(x => x)
            .ToListAsync();

        // Paged results
        var items = await query
            .OrderByDescending(x => x.log.CreatedDate)
            .Skip((page - 1) * pageSize)
            .Take(pageSize)
            .Select(x => new AuditLogListItemViewModel
            {
                Id = x.log.Id,
                CreatedDate = x.log.CreatedDate,
                EventType = x.log.EventType,
                ActionName = x.log.ActionName,
                ControllerName = x.log.ControllerName,
                RoutePath = x.log.RoutePath,
                HttpMethod = x.log.HttpMethod,
                UserAgent = x.log.UserAgent,
                Username = x.username,
                BranchName = x.branchName,
                IpAddress = x.log.IpAddress,
                Description = x.log.Description
            })
            .ToListAsync();

        var result = new AuditLogPagedResult
        {
            Items = items,
            Filter = filter,
            TotalCount = totalCount,
            AvailableEventTypes = eventTypes!
        };

        return View(result);
    }
}
