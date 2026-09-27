namespace EMR.Api.Models;

public class LabExpertRuleListItem
{
    public int Rule_ID { get; set; }
    public int CompanyId { get; set; }
    public string Rule_Code { get; set; } = string.Empty;
    public string Rule_Type { get; set; } = string.Empty;
    public string? Organism_Category { get; set; }
    public int? Organism_ID { get; set; }
    public string? Organism_Name { get; set; }
    public int Antibiotic_ID { get; set; }
    public string? Antibiotic_Name { get; set; }
    public string Trigger_Result { get; set; } = string.Empty;
    public string Rule_Action { get; set; } = string.Empty;
    public string Alert_Message { get; set; } = string.Empty;
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class LabExpertRuleCreateRequest
{
    public string Rule_Type { get; set; } = string.Empty;
    public string? Organism_Category { get; set; }
    public int? Organism_ID { get; set; }
    public int Antibiotic_ID { get; set; }
    public string Trigger_Result { get; set; } = string.Empty;
    public string Rule_Action { get; set; } = string.Empty;
    public string Alert_Message { get; set; } = string.Empty;
    public int CompanyId { get; set; } = 1;
    public int? UserId { get; set; }
}

public class LabExpertRuleUpdateRequest
{
    public int Rule_ID { get; set; }
    public string Rule_Type { get; set; } = string.Empty;
    public string? Organism_Category { get; set; }
    public int? Organism_ID { get; set; }
    public int Antibiotic_ID { get; set; }
    public string Trigger_Result { get; set; } = string.Empty;
    public string Rule_Action { get; set; } = string.Empty;
    public string Alert_Message { get; set; } = string.Empty;
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
}

public class LabExpertRuleToggleStatusRequest
{
    public int Rule_ID { get; set; }
    public bool Status { get; set; }
    public int? UserId { get; set; }
}

public class LabExpertRuleLookupItem
{
    public int Id { get; set; }
    public string Text { get; set; } = string.Empty;
}
