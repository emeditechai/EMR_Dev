namespace EMR.Api.Models;

public class ConsentMasterListItemDto
{
    public int Consent_ID { get; set; }
    public int CompanyId { get; set; }
    public int Branch_ID { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCode { get; set; }
    public string ConsentType { get; set; } = string.Empty;
    public string Type { get; set; } = string.Empty; // IPD, OPD, LAB, MED
    public int? Procedure_ID { get; set; }
    public string? ProcedureCode { get; set; }
    public string? ProcedureName { get; set; }
    public string? ProcedureCategory { get; set; }
    public string Language { get; set; } = "English";
    public string ConsentTemplateContent { get; set; } = string.Empty;
    public string Version { get; set; } = "1.0";
    public string ValidityPeriod { get; set; } = "Per Admission";
    public bool WitnessRequired { get; set; } = true;
    public bool Status { get; set; } = true;
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class ConsentMasterDetailDto : ConsentMasterListItemDto
{
}

public class ConsentMasterSaveRequest
{
    public int? Consent_ID { get; set; }
    public int CompanyId { get; set; } = 1;
    public int Branch_ID { get; set; }
    public string ConsentType { get; set; } = string.Empty;
    public string Type { get; set; } = "IPD"; // IPD, OPD, LAB, MED
    public int? Procedure_ID { get; set; }
    public string Language { get; set; } = "English";
    public string ConsentTemplateContent { get; set; } = string.Empty;
    public string Version { get; set; } = "1.0";
    public string ValidityPeriod { get; set; } = "Per Admission";
    public bool WitnessRequired { get; set; } = true;
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
}

public class ConsentProcedureOptionDto
{
    public int ProcedureId { get; set; }
    public string ProcedureCode { get; set; } = string.Empty;
    public string ProcedureName { get; set; } = string.Empty;
    public string? ProcedureCategory { get; set; }
    public string? DepartmentName { get; set; }
    public string? SpecialityName { get; set; }
}
