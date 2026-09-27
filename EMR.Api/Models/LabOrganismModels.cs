namespace EMR.Api.Models;

public class LabOrganismListItem
{
    public int Organism_ID { get; set; }
    public int CompanyId { get; set; }
    public string Organism_Code { get; set; } = string.Empty;
    public string Organism_Name { get; set; } = string.Empty;
    public string Gram_Type { get; set; } = string.Empty;
    public string Organism_Type { get; set; } = string.Empty;
    public string Organism_Category { get; set; } = string.Empty;
    public string? WHONET_Code { get; set; }
    public string? Description { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class LabOrganismCreateRequest
{
    public string Organism_Name { get; set; } = string.Empty;
    public string Gram_Type { get; set; } = string.Empty;
    public string Organism_Type { get; set; } = string.Empty;
    public string Organism_Category { get; set; } = string.Empty;
    public string? WHONET_Code { get; set; }
    public string? Description { get; set; }
    public int CompanyId { get; set; } = 1;
    public int? UserId { get; set; }
}

public class LabOrganismUpdateRequest
{
    public int Organism_ID { get; set; }
    public string Organism_Name { get; set; } = string.Empty;
    public string Gram_Type { get; set; } = string.Empty;
    public string Organism_Type { get; set; } = string.Empty;
    public string Organism_Category { get; set; } = string.Empty;
    public string? WHONET_Code { get; set; }
    public string? Description { get; set; }
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
}

public class LabOrganismToggleStatusRequest
{
    public int Organism_ID { get; set; }
    public bool Status { get; set; }
    public int? UserId { get; set; }
}

public class LabOrganismLookupItem
{
    public int Id { get; set; }
    public string Text { get; set; } = string.Empty;
}
