using System.Net.Http.Json;
using System.Web;

namespace EMR.Web.ApiClients;

/// <summary>Settings > User Master list, paged on the server (SQLScripts/2314): EMR.Api api/users-list.</summary>
public interface IUserListApiClient
{
    Task<UserListPageDto> GetPagedAsync(int? companyId, IEnumerable<int>? visibleBranchIds, int? currentBranchId,
        string? search, string? userType, string? status, string? role, int page, int pageSize);
}

public class UserListKpisDto
{
    public int TotalUsers { get; set; }
    public int ActiveUsers { get; set; }
    public int InactiveUsers { get; set; }
    public int Pathologists { get; set; }
    public int PathologistsSigned { get; set; }
    public int LabTechnicians { get; set; }
}

public class UserListRowDto
{
    public int Id { get; set; }
    public string Username { get; set; } = "";
    public string EmployeeCode { get; set; } = "";
    public string FullName { get; set; } = "";
    public string Email { get; set; } = "";
    public bool IsActive { get; set; }
    public bool IsNursingStaff { get; set; }
    public bool IsPhlebotomist { get; set; }
    public bool IsPathologist { get; set; }
    public bool IsLabTechnician { get; set; }
    public bool IsLogisticsBoy { get; set; }
    public string? ProfilePicturePath { get; set; }
    public bool HasSignature { get; set; }
    public string UserType { get; set; } = "U";
    public int? ReferenceUserId { get; set; }
    public string? ReferenceName { get; set; }
    public string Branches { get; set; } = "";
    public string DepartmentNames { get; set; } = "";
}

public class UserListPageDto
{
    public UserListKpisDto Kpis { get; set; } = new();
    public int FilteredCount { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 25;
    public List<UserListRowDto> Items { get; set; } = [];
}

public class UserListApiClient(IHttpClientFactory httpClientFactory) : IUserListApiClient
{
    private HttpClient Client => httpClientFactory.CreateClient("EmrApi");

    public async Task<UserListPageDto> GetPagedAsync(int? companyId, IEnumerable<int>? visibleBranchIds, int? currentBranchId,
        string? search, string? userType, string? status, string? role, int page, int pageSize)
    {
        var qs = HttpUtility.ParseQueryString(string.Empty);
        if (companyId.HasValue) qs["companyId"] = companyId.Value.ToString();
        // an empty list still limits (to nothing); only null means "no branch limit"
        if (visibleBranchIds is not null) qs["visibleBranchIds"] = string.Join(",", visibleBranchIds) is { Length: > 0 } ids ? ids : "0";
        if (currentBranchId.HasValue) qs["currentBranchId"] = currentBranchId.Value.ToString();
        if (!string.IsNullOrWhiteSpace(search)) qs["search"] = search.Trim();
        if (!string.IsNullOrWhiteSpace(userType)) qs["userType"] = userType;
        if (!string.IsNullOrWhiteSpace(status)) qs["status"] = status;
        if (!string.IsNullOrWhiteSpace(role)) qs["role"] = role;
        qs["page"] = page.ToString();
        qs["pageSize"] = pageSize.ToString();
        return await Client.GetFromJsonAsync<UserListPageDto>("api/users-list?" + qs) ?? new UserListPageDto();
    }
}
