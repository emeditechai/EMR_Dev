namespace EMR.Web.ApiClients.Models;

public class LabDescriptiveTestTemplateModel
{
    public int Template_ID { get; set; }
    public int Test_ID { get; set; }
    public string Test_Name { get; set; } = string.Empty;
    public string Test_Code { get; set; } = string.Empty;
    public string Section_Name { get; set; } = string.Empty;
    public int Section_Sequence { get; set; }
    public bool Is_Mandatory { get; set; }
    public string? Default_Content_Html { get; set; }
    public string? Placeholder_Tags { get; set; }
    public string? Modality { get; set; }
    public string? Body_Part { get; set; }
    public string? Laterality { get; set; }
    public bool Contrast_Required { get; set; }
    public string? Contrast_Agent { get; set; }
    public string? Views_Projections { get; set; }
    public string? Preparation_Instructions { get; set; }
    public bool IsActive { get; set; }
    public int CompanyId { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class LabDescriptiveTestTemplateCreateRequestModel
{
    public int Test_ID { get; set; }
    public string Section_Name { get; set; } = string.Empty;
    public int Section_Sequence { get; set; } = 1;
    public bool Is_Mandatory { get; set; }
    public string? Default_Content_Html { get; set; }
    public string? Placeholder_Tags { get; set; }
    public string? Modality { get; set; }
    public string? Body_Part { get; set; }
    public string? Laterality { get; set; }
    public bool Contrast_Required { get; set; }
    public string? Contrast_Agent { get; set; }
    public string? Views_Projections { get; set; }
    public string? Preparation_Instructions { get; set; }
    public int CompanyId { get; set; } = 1;
    public int? UserId { get; set; }
}

public class LabDescriptiveTestTemplateUpdateRequestModel
{
    public int Template_ID { get; set; }
    public int Test_ID { get; set; }
    public string Section_Name { get; set; } = string.Empty;
    public int Section_Sequence { get; set; } = 1;
    public bool Is_Mandatory { get; set; }
    public string? Default_Content_Html { get; set; }
    public string? Placeholder_Tags { get; set; }
    public string? Modality { get; set; }
    public string? Body_Part { get; set; }
    public string? Laterality { get; set; }
    public bool Contrast_Required { get; set; }
    public string? Contrast_Agent { get; set; }
    public string? Views_Projections { get; set; }
    public string? Preparation_Instructions { get; set; }
    public bool IsActive { get; set; }
    public int? UserId { get; set; }
}

public class LabDescriptiveTestTemplateToggleStatusRequestModel
{
    public int Template_ID { get; set; }
    public bool IsActive { get; set; }
    public int? UserId { get; set; }
}

public class RadiologyTestItemModel
{
    public int Test_ID { get; set; }
    public string Test_Code { get; set; } = string.Empty;
    public string Test_Name { get; set; } = string.Empty;
}
