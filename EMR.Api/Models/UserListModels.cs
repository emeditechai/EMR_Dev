namespace EMR.Api.Models;

/// <summary>Settings > User Master list, paged on the server (SQLScripts/2314).</summary>
public class UserListQuery
{
    /// <summary>Null = Super Admin: every company.</summary>
    public int? CompanyId { get; set; }
    /// <summary>Null = no branch limit (signed in to the head office).</summary>
    public List<int>? VisibleBranchIds { get; set; }
    public int? CurrentBranchId { get; set; }
    public string? Search { get; set; }
    public string? UserType { get; set; }
    public string? Status { get; set; }
    public string? Role { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 25;
}

public class UserListKpis
{
    public int TotalUsers { get; set; }
    public int ActiveUsers { get; set; }
    public int InactiveUsers { get; set; }
    public int Pathologists { get; set; }
    public int PathologistsSigned { get; set; }
    public int LabTechnicians { get; set; }
}

public class UserListRow
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

public class UserListPage
{
    public UserListKpis Kpis { get; set; } = new();
    public int FilteredCount { get; set; }
    public int Page { get; set; }
    public int PageSize { get; set; }
    public List<UserListRow> Items { get; set; } = [];
}
