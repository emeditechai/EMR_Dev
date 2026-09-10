namespace EMR.Api.Models;

public class LabSampleRejectionReasonModel
{
    public int Reason_ID { get; set; }
    public int CompanyId { get; set; }
    public string Reason_Text { get; set; } = string.Empty;
    public int? Applicable_Sample_Type_ID { get; set; }
    public string? Applicable_Sample_Type_Name { get; set; }
    public string? Applicable_Sample_Type_Code { get; set; }
    public int Display_Order { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class LabSampleRejectionReasonCreateRequestModel
{
    public string Reason_Text { get; set; } = string.Empty;
    public int? Applicable_Sample_Type_ID { get; set; }
    public int Display_Order { get; set; } = 1;
    public int CompanyId { get; set; } = 1;
    public int? UserId { get; set; }
}

public class LabSampleRejectionReasonUpdateRequestModel
{
    public int Reason_ID { get; set; }
    public string Reason_Text { get; set; } = string.Empty;
    public int? Applicable_Sample_Type_ID { get; set; }
    public int Display_Order { get; set; } = 1;
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
}

public class LabSampleRejectionReasonToggleStatusRequestModel
{
    public int Reason_ID { get; set; }
    public bool Status { get; set; }
    public int? UserId { get; set; }
}
