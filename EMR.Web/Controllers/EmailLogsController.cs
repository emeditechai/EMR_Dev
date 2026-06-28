using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class EmailLogsController(ApplicationDbContext dbContext) : Controller
{
    public async Task<IActionResult> Index(
        string? search, string? status,
        DateTime? dateFrom, DateTime? dateTo,
        int page = 1, int pageSize = 50)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null)
        {
            TempData["Error"] = "No active branch found. Please select a branch first.";
            return RedirectToAction("Index", "Dashboard");
        }

        pageSize = pageSize is 25 or 50 or 100 ? pageSize : 50;
        page = Math.Max(1, page);

        var filter = new EmailLogFilterViewModel
        {
            Search = search?.Trim(),
            Status = status?.Trim(),
            DateFrom = dateFrom,
            DateTo = dateTo,
            Page = page,
            PageSize = pageSize
        };

        var query = dbContext.EmailLogs
            .Include(x => x.Config)
            .Include(x => x.Branch)
            .Where(x => x.BranchId == branchId.Value)
            .AsQueryable();

        // Filters
        if (!string.IsNullOrWhiteSpace(filter.Status))
            query = query.Where(x => x.Status == filter.Status);

        if (!string.IsNullOrWhiteSpace(filter.Search))
            query = query.Where(x =>
                x.RecipientEmail.Contains(filter.Search) ||
                (x.Subject != null && x.Subject.Contains(filter.Search)));

        if (filter.DateFrom.HasValue)
            query = query.Where(x => x.SentDate >= filter.DateFrom.Value);

        if (filter.DateTo.HasValue)
            query = query.Where(x => x.SentDate < filter.DateTo.Value.AddDays(1));

        // Stats
        var totalCount = await query.CountAsync();
        var totalSuccess = await query.CountAsync(x => x.Status == "Success");
        var totalFailed = totalCount - totalSuccess;

        // Paged results
        var items = await query
            .OrderByDescending(x => x.SentDate)
            .Skip((page - 1) * pageSize)
            .Take(pageSize)
            .Select(x => new EmailLogListItemViewModel
            {
                Id = x.Id,
                RecipientEmail = x.RecipientEmail,
                Subject = x.Subject,
                SentDate = x.SentDate,
                Status = x.Status,
                ErrorMessage = x.ErrorMessage,
                ConfigName = x.Config.ConfigName,
                ProviderType = x.Config.ProviderType,
                BranchName = x.Branch.BranchName
            })
            .ToListAsync();

        var result = new EmailLogPagedResult
        {
            Items = items,
            Filter = filter,
            TotalCount = totalCount,
            TotalSuccess = totalSuccess,
            TotalFailed = totalFailed
        };

        return View(result);
    }
}
