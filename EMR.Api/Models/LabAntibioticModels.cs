namespace EMR.Api.Models;

public class LabAntibioticListItem
{
    public int Antibiotic_ID { get; set; }
    public int CompanyId { get; set; }
    public string Antibiotic_Code { get; set; } = string.Empty;
    public string Antibiotic_Name { get; set; } = string.Empty;
    public string? Abbreviation { get; set; }
    public string Antibiotic_Class { get; set; } = string.Empty;
    public string Route { get; set; } = string.Empty;
    public string? WHONET_Code { get; set; }
    public string? Description { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class LabAntibioticCreateRequest
{
    public string Antibiotic_Name { get; set; } = string.Empty;
    public string? Abbreviation { get; set; }
    public string Antibiotic_Class { get; set; } = string.Empty;
    public string Route { get; set; } = string.Empty;
    public string? WHONET_Code { get; set; }
    public string? Description { get; set; }
    public int CompanyId { get; set; } = 1;
    public int? UserId { get; set; }
}

public class LabAntibioticUpdateRequest
{
    public int Antibiotic_ID { get; set; }
    public string Antibiotic_Name { get; set; } = string.Empty;
    public string? Abbreviation { get; set; }
    public string Antibiotic_Class { get; set; } = string.Empty;
    public string Route { get; set; } = string.Empty;
    public string? WHONET_Code { get; set; }
    public string? Description { get; set; }
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
}

public class LabAntibioticToggleStatusRequest
{
    public int Antibiotic_ID { get; set; }
    public bool Status { get; set; }
    public int? UserId { get; set; }
}

public class LabAntibioticLookupItem
{
    public int Id { get; set; }
    public string Text { get; set; } = string.Empty;
}
