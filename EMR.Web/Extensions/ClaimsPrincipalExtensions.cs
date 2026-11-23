using System.Security.Claims;

namespace EMR.Web.Extensions;

public static class ClaimsPrincipalExtensions
{
    public static int GetUserId(this ClaimsPrincipal user)
    {
        var claim = user.FindFirstValue(ClaimTypes.NameIdentifier);
        return int.TryParse(claim, out var userId) ? userId : 0;
    }

    /// <summary>The franchise a franchise login belongs to (Users.User_Type 'F', ReferenceUserID); null for every other user.</summary>
    public static int? GetFranchiseId(this ClaimsPrincipal user)
    {
        if (!string.Equals(user.FindFirstValue("UserType"), "F", StringComparison.OrdinalIgnoreCase)) return null;
        return int.TryParse(user.FindFirstValue("ReferenceUserId"), out var id) && id > 0 ? id : null;
    }

    /// <summary>A login created from the Franchise master: it only ever sees and bills for its own franchise.</summary>
    public static bool IsFranchiseUser(this ClaimsPrincipal user) => user.GetFranchiseId().HasValue;

    public static int? GetCurrentBranchId(this ClaimsPrincipal user)
    {
        var claim = user.FindFirstValue("BranchId");
        return int.TryParse(claim, out var branchId) ? branchId : null;
    }

    public static bool IsHOBranch(this ClaimsPrincipal user)
    {
        var claim = user.FindFirstValue("IsHOBranch");
        return bool.TryParse(claim, out var isHO) && isHO;
    }

    public static int GetCompanyId(this ClaimsPrincipal user)
    {
        var claim = user.FindFirstValue("CompanyId");
        return int.TryParse(claim, out var companyId) && companyId > 0 ? companyId : 1;
    }

    public static string GetCompanyName(this ClaimsPrincipal user)
    {
        return user.FindFirstValue("CompanyName") ?? "Primary Healthcare Network";
    }

    public static string GetCompanyCode(this ClaimsPrincipal user)
    {
        return user.FindFirstValue("CompanyCode") ?? "CMP-001";
    }

    public static bool IsSuperAdmin(this ClaimsPrincipal user)
    {
        return user.IsInRole("SuperAdmin") || user.HasClaim("IsSuperAdmin", "true");
    }

    public static bool IsCompanyAdmin(this ClaimsPrincipal user)
    {
        return IsSuperAdmin(user) || user.IsInRole("CompanyAdmin") || user.IsInRole("Administrator");
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

    public static string GetDisplayName(this ClaimsPrincipal user)
    {
        return user.FindFirstValue("DisplayName") 
            ?? user.FindFirstValue(ClaimTypes.Name) 
            ?? user.Identity?.Name 
            ?? "Unknown User";
    }
}

