namespace EMR.Api.Models;

public class LabAntibioticPanelListItem
{
    public int Panel_ID { get; set; }
    public int CompanyId { get; set; }
    public string Panel_Code { get; set; } = string.Empty;
    public string Panel_Name { get; set; } = string.Empty;
    public string Gram_Type { get; set; } = string.Empty;
    public string? Organism_Category { get; set; }
    public int? Sample_Type_ID { get; set; }
    public string? Sample_Type_Name { get; set; }
    public string? Description { get; set; }
    public string? Antibiotic_IDs { get; set; }
    public string? Antibiotic_Names { get; set; }
    public string? Antibiotic_Tiers { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class LabAntibioticPanelCreateRequest
{
    public string Panel_Name { get; set; } = string.Empty;
    public string Gram_Type { get; set; } = string.Empty;
    public string? Organism_Category { get; set; }
    public int? Sample_Type_ID { get; set; }
    public string? Description { get; set; }
    public List<int> Antibiotic_IDs { get; set; } = [];
    public List<int> Antibiotic_Tiers { get; set; } = [];
    public int CompanyId { get; set; } = 1;
    public int? UserId { get; set; }
}

public class LabAntibioticPanelUpdateRequest
{
    public int Panel_ID { get; set; }
    public string Panel_Name { get; set; } = string.Empty;
    public string Gram_Type { get; set; } = string.Empty;
    public string? Organism_Category { get; set; }
    public int? Sample_Type_ID { get; set; }
    public string? Description { get; set; }
    public List<int> Antibiotic_IDs { get; set; } = [];
    public List<int> Antibiotic_Tiers { get; set; } = [];
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
}

public class LabAntibioticPanelToggleStatusRequest
{
    public int Panel_ID { get; set; }
    public bool Status { get; set; }
    public int? UserId { get; set; }
}

public class LabAntibioticPanelLookupItem
{
    public int Id { get; set; }
    public string Text { get; set; } = string.Empty;
}
