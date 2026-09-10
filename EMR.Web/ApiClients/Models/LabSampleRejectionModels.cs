namespace EMR.Web.ApiClients.Models;

public class LabSampleRejectionModel
{
    public int Rejection_ID { get; set; }
    public int CompanyId { get; set; }
    public string Rejection_Code { get; set; } = string.Empty;
    public string Rejection_Reason { get; set; } = string.Empty;
    public string? Description { get; set; }
    public int Display_Order { get; set; }
    public bool Status { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; }
    public int? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}

public class LabSampleRejectionCreateRequestModel
{
    public string Rejection_Reason { get; set; } = string.Empty;
    public string? Description { get; set; }
    public int Display_Order { get; set; } = 1;
    public int CompanyId { get; set; } = 1;
    public int? UserId { get; set; }
}

public class LabSampleRejectionUpdateRequestModel
{
    public int Rejection_ID { get; set; }
    public string Rejection_Reason { get; set; } = string.Empty;
    public string? Description { get; set; }
    public int Display_Order { get; set; } = 1;
    public bool Status { get; set; } = true;
    public int? UserId { get; set; }
}

public class LabSampleRejectionToggleStatusRequestModel
{
    public int Rejection_ID { get; set; }
    public bool Status { get; set; }
    public int? UserId { get; set; }
}
