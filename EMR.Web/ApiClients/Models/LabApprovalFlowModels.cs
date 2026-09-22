namespace EMR.Web.ApiClients.Models;

/// <summary>A configured Pathologist Approval Flow - list row and detail header.</summary>
public class LabApprovalFlowModel
{
    public int Flow_ID { get; set; }
    public string Flow_Code { get; set; } = string.Empty;
    public int CompanyId { get; set; }
    public int? Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public int? Department_ID { get; set; }
    public string? DepartmentName { get; set; }
    /// <summary>Null = every test category; otherwise "3,7,11".</summary>
    public string? Category_IDs { get; set; }
    /// <summary>Names of the chosen categories, comma-separated.</summary>
    public string? CategoryNames { get; set; }

    /// <summary>The chosen category ids as a list (empty = every category).</summary>
    public IEnumerable<int> CategoryIdList => string.IsNullOrWhiteSpace(Category_IDs)
        ? Enumerable.Empty<int>()
        : Category_IDs.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                      .Select(x => int.TryParse(x, out var id) ? id : 0).Where(id => id > 0);

    /// <summary>The chosen category names as a list.</summary>
    public IEnumerable<string> CategoryNameList => string.IsNullOrWhiteSpace(CategoryNames)
        ? Enumerable.Empty<string>()
        : CategoryNames.Split(", ", StringSplitOptions.RemoveEmptyEntries);

    public string Flow_Name { get; set; } = string.Empty;
    public int Required_Levels { get; set; }
    public bool Allow_Same_Approver { get; set; }
    public bool Status { get; set; }
    public DateTime CreatedDate { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public string? LevelsSummary { get; set; }
}

public class LabApprovalFlowLevelModel
{
    public int Level_ID { get; set; }
    public int Level_No { get; set; }
    public string Level_Title { get; set; } = string.Empty;
}

public class LabApprovalFlowApproverModel
{
    public int Level_No { get; set; }
    public int UserId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string? RegistrationNo { get; set; }
    public bool UserIsActive { get; set; } = true;
    public bool UserIsPathologist { get; set; } = true;
}

public class LabApprovalFlowDetailModel
{
    public LabApprovalFlowModel Flow { get; set; } = new();
    public List<LabApprovalFlowLevelModel> Levels { get; set; } = new();
    public List<LabApprovalFlowApproverModel> Approvers { get; set; } = new();
}

public class LabApprovalEligibleApproverModel
{
    public int UserId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string? Username { get; set; }
    public string? RegistrationNo { get; set; }
    public string? DepartmentIds { get; set; }
    public string? PathologistCategoryIds { get; set; }
    /// <summary>The user's Assigned Department(s) from User Master, by name.</summary>
    public string? DepartmentNames { get; set; }
    /// <summary>The user's Test Categories (sign-off scope) by name; "All categories" when none are assigned.</summary>
    public string? CategoryNames { get; set; }
    /// <summary>False when the pathologist does not match the chosen branch / department / categories.</summary>
    public bool IsEligible { get; set; } = true;
    public string? IneligibleReason { get; set; }
}

public class LabApprovalFlowLevelInput
{
    public int LevelNo { get; set; }
    public string? Title { get; set; }
    public List<int> ApproverIds { get; set; } = new();
}

public class LabApprovalFlowCreateRequestModel
{
    public string Flow_Name { get; set; } = string.Empty;
    public int Required_Levels { get; set; }
    public int? Branch_ID { get; set; }
    public int? Department_ID { get; set; }
    public List<int> Category_IDs { get; set; } = new();
    public bool Allow_Same_Approver { get; set; }
    public List<LabApprovalFlowLevelInput> Levels { get; set; } = new();
    public int CompanyId { get; set; } = 1;
    public int? UserId { get; set; }
}

public class LabApprovalFlowUpdateRequestModel
{
    public int Flow_ID { get; set; }
    public string Flow_Name { get; set; } = string.Empty;
    public int Required_Levels { get; set; }
    public int? Branch_ID { get; set; }
    public int? Department_ID { get; set; }
    public List<int> Category_IDs { get; set; } = new();
    public bool Allow_Same_Approver { get; set; }
    public bool Status { get; set; } = true;
    public List<LabApprovalFlowLevelInput> Levels { get; set; } = new();
    public int? UserId { get; set; }
}

public class LabApprovalFlowToggleStatusRequestModel
{
    public int Flow_ID { get; set; }
    public bool Status { get; set; }
    public int? UserId { get; set; }
}
