namespace EMR.Web.Models.DTOs;

/// <summary>SQLScripts/2465: a bill's "print with due" state - the branch setting and the newest approval request.</summary>
public class LabDuePrintStateDto
{
    public int LabOrderId { get; set; }
    public bool AllowPrintInDue { get; set; }
    public decimal BalanceDue { get; set; }
    public bool IsB2B { get; set; }
    public int? Request_ID { get; set; }
    public string? Status { get; set; }          // P pending / A approved / S sent back / null none
    public string? Remarks { get; set; }
    public DateTime? Requested_Date { get; set; }
    public DateTime? Actioned_Date { get; set; }
    public string? RequestedByName { get; set; }
    public string? ActionedByName { get; set; }
}

public class LabDuePrintSubmitRequest
{
    public int LabOrderId { get; set; }
    public int UserId { get; set; }
    public string? Reason { get; set; }
}

public class LabDuePrintSubmitResult
{
    public int Request_ID { get; set; }
    public string? ErrorMessage { get; set; }
    public string? BillNo { get; set; }
    public string? PatientName { get; set; }
    public int? BranchId { get; set; }
    public string? BranchName { get; set; }
    public string? Scope { get; set; }
    public decimal BalanceDue { get; set; }
    public List<int> ApproverIds { get; set; } = new();
}
