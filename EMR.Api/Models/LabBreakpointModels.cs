namespace EMR.Api.Models;

public class LabBreakpointListItem
{
    public int Breakpoint_ID { get; set; }
    public int CompanyId { get; set; }
    public string Breakpoint_Code { get; set; } = string.Empty;
    public string Organism_Category { get; set; } = string.Empty;
    public int? Organism_ID { get; set; }
    public string? Organism_Name { get; set; }
    public int Antibiotic_ID { get; set; }
    public string? Antibiotic_Name { get; set; }
    public string Standard { get; set; } = string.Empty;
    public string Standard_Version { get; set; } = string.Empty;
    public string Method { get; set; } = string.Empty;
    public string Specimen_Scope { get; set; } = string.Empty;
    public decimal? S_Breakpoint { get; set; }
    public decimal? R_Breakpoint { get; set; }
    public string? Remarks { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class LabBreakpointCreateRequest
{
    public string Organism_Category { get; set; } = string.Empty;
    public int? Organism_ID { get; set; }
    public int Antibiotic_ID { get; set; }
    public string Standard { get; set; } = string.Empty;
    public string Standard_Version { get; set; } = string.Empty;
    public string Method { get; set; } = string.Empty;
    public string Specimen_Scope { get; set; } = string.Empty;
    public decimal? S_Breakpoint { get; set; }
    public decimal? R_Breakpoint { get; set; }
    public string? Remarks { get; set; }
    public int CompanyId { get; set; } = 1;
    public int? UserId { get; set; }
}

public class LabBreakpointUpdateRequest
{
    public int Breakpoint_ID { get; set; }
    public string Organism_Category { get; set; } = string.Empty;
    public int? Organism_ID { get; set; }
    public int Antibiotic_ID { get; set; }
    public string Standard { get; set; } = string.Empty;
    public string Standard_Version { get; set; } = string.Empty;
    public string Method { get; set; } = string.Empty;
    public string Specimen_Scope { get; set; } = string.Empty;
    public decimal? S_Breakpoint { get; set; }
    public decimal? R_Breakpoint { get; set; }
    public string? Remarks { get; set; }
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
}

public class LabBreakpointToggleStatusRequest
{
    public int Breakpoint_ID { get; set; }
    public bool Status { get; set; }
    public int? UserId { get; set; }
}

public class LabBreakpointLookupItem
{
    public int Id { get; set; }
    public string Text { get; set; } = string.Empty;
}
