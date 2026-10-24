using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>Settings > User Master list, paged on the server (SQLScripts/2314). Mapped to the User Master page.</summary>
[ApiController]
[Route("api/users-list")]
public class UserListController(IUserListService service) : ControllerBase
{
    // GET api/users-list?companyId=1&visibleBranchIds=1,2&currentBranchId=1&search=&userType=&status=&role=&page=1&pageSize=25
    [HttpGet]
    public async Task<IActionResult> GetPaged(
        [FromQuery] int? companyId, [FromQuery] string? visibleBranchIds, [FromQuery] int? currentBranchId,
        [FromQuery] string? search, [FromQuery] string? userType, [FromQuery] string? status, [FromQuery] string? role,
        [FromQuery] int page = 1, [FromQuery] int pageSize = 25)
    {
        List<int>? branches = null;
        if (visibleBranchIds is not null)
            branches = visibleBranchIds.Split(',', StringSplitOptions.RemoveEmptyEntries)
                .Select(s => int.TryParse(s.Trim(), out var b) ? b : 0).Where(b => b > 0).Distinct().ToList();
        return Ok(await service.GetPagedAsync(new UserListQuery
        {
            CompanyId = companyId,
            VisibleBranchIds = branches,
            CurrentBranchId = currentBranchId,
            Search = search?.Trim(),
            UserType = userType?.Trim() is "U" or "D" or "F" or "C" ? userType.Trim() : null,
            Status = status?.Trim().ToLowerInvariant() is "active" or "inactive" or "locked" ? status.Trim().ToLowerInvariant() : null,
            Role = role?.Trim().ToLowerInvariant() is "nurse" or "phlebotomist" or "pathologist" or "labtech" or "logistics" ? role.Trim().ToLowerInvariant() : null,
            Page = page,
            PageSize = pageSize
        }));
    }

    // POST api/users-list/5/unlock - User Master > Unlock (SQLScripts/2320), its own permission control
    [HttpPost("{id:int}/unlock")]
    public async Task<IActionResult> Unlock(int id)
    {
        var r = await service.UnlockAsync(id);
        return r.Found ? Ok(r) : NotFound();
    }
}
