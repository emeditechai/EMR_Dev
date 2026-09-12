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
        string? search, string? eventType, string? moduleCode, string? referenceNo,
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
            ModuleCode = string.IsNullOrWhiteSpace(moduleCode) ? "ALL" : moduleCode.Trim().ToUpperInvariant(),
            ReferenceNo = referenceNo?.Trim(),
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
                    select new 
                    { 
                        log, 
                        username = user != null ? user.Username : "System", 
                        branchName = branch != null ? branch.BranchName : "N/A" 
                    };

        // Filters
        if (!string.IsNullOrWhiteSpace(filter.ModuleCode) && filter.ModuleCode != "ALL")
        {
            if (filter.ModuleCode == "OPD")
            {
                query = query.Where(x => x.log.ModuleCode == "OPD" || x.log.EventType.Contains("OPD"));
            }
            else if (filter.ModuleCode == "LAB")
            {
                query = query.Where(x => x.log.ModuleCode == "LAB" || x.log.EventType.Contains("LAB") || x.log.EventType.Contains("Sample") || x.log.EventType.Contains("Reporting"));
            }
            else if (filter.ModuleCode == "SECURITY" || filter.ModuleCode == "AUTH")
            {
                query = query.Where(x => x.log.EventType.StartsWith("Auth") || x.log.ActionName.StartsWith("Account"));
            }
            else
            {
                query = query.Where(x => x.log.ModuleCode == filter.ModuleCode);
            }
        }

        if (!string.IsNullOrWhiteSpace(filter.EventType))
            query = query.Where(x => x.log.EventType == filter.EventType);

        if (!string.IsNullOrWhiteSpace(filter.ReferenceNo))
            query = query.Where(x => x.log.ReferenceNo != null && x.log.ReferenceNo.Contains(filter.ReferenceNo));

        if (!string.IsNullOrWhiteSpace(filter.Search))
            query = query.Where(x =>
                x.username.Contains(filter.Search) ||
                x.log.ActionName.Contains(filter.Search) ||
                (x.log.Description != null && x.log.Description.Contains(filter.Search)) ||
                (x.log.ReferenceNo != null && x.log.ReferenceNo.Contains(filter.Search)) ||
                (x.log.PatientCode != null && x.log.PatientCode.Contains(filter.Search)));

        if (filter.DateFrom.HasValue)
            query = query.Where(x => x.log.CreatedDate >= filter.DateFrom.Value);

        if (filter.DateTo.HasValue)
            query = query.Where(x => x.log.CreatedDate < filter.DateTo.Value.AddDays(1));

        // Total count (fast — no projection yet)
        var totalCount = await query.CountAsync();

        // Lifecycle module counts
        var totalOpdLogs = await dbContext.AuditLogs.CountAsync(x => x.ModuleCode == "OPD" || x.EventType.Contains("OPD"));
        var totalLabLogs = await dbContext.AuditLogs.CountAsync(x => x.ModuleCode == "LAB" || x.EventType.Contains("LAB") || x.EventType.Contains("Sample") || x.EventType.Contains("Reporting"));
        var totalSecurityLogs = await dbContext.AuditLogs.CountAsync(x => x.EventType.StartsWith("Auth") || x.ActionName.StartsWith("Account"));

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
                Description = x.log.Description,
                ModuleCode = x.log.ModuleCode,
                ReferenceNo = x.log.ReferenceNo,
                ReferenceId = x.log.ReferenceId,
                PatientCode = x.log.PatientCode,
                MetadataJson = x.log.MetadataJson
            })
            .ToListAsync();

        var result = new AuditLogPagedResult
        {
            Items = items,
            Filter = filter,
            TotalCount = totalCount,
            TotalOpdLogs = totalOpdLogs,
            TotalLabLogs = totalLabLogs,
            TotalSecurityLogs = totalSecurityLogs,
            AvailableEventTypes = eventTypes!
        };

        return View(result);
    }
}
