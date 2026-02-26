using System.Security.Claims;

namespace EMR.Web.Extensions;

public static class ClaimsPrincipalExtensions
{
    public static int GetUserId(this ClaimsPrincipal user)
    {
        var claim = user.FindFirstValue(ClaimTypes.NameIdentifier);
        return int.TryParse(claim, out var userId) ? userId : 0;
    }

    public static int? GetCurrentBranchId(this ClaimsPrincipal user)
    {
        var claim = user.FindFirstValue("BranchId");
        return int.TryParse(claim, out var branchId) ? branchId : null;
    }

    public static bool IsSuperAdmin(this ClaimsPrincipal user)
    {
        return user.IsInRole("SuperAdmin") || user.HasClaim("IsSuperAdmin", "true");
    }

    public static bool HasAnyRole(this ClaimsPrincipal user, params string[] roles)
    {
        if (IsSuperAdmin(user))
        {
            return true;
        }

        return roles.Any(user.IsInRole);
    }

    public static string GetActiveRole(this ClaimsPrincipal user)
    {
        return user.FindFirstValue("ActiveRole") ?? string.Empty;
    }
}
