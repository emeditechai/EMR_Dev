namespace EMR.Api.Models;

// OPD Dashboard > visit Audit History with workflow (SQLScripts/2304): api/opd-visits over usp_Api_OpdVisit_*.

/// <summary>One activity of an OPD visit (same shape as the LAB bill's activity rows).</summary>
public class OpdVisitActivityDto
{
    public DateTime EventDate { get; set; }
    public string Source { get; set; } = "";
    public string? EventType { get; set; }
    public string ActionName { get; set; } = "";
    public string? Description { get; set; }
    public int? UserId { get; set; }
    public string? UserName { get; set; }
    public string? BranchName { get; set; }
    public string? IpAddress { get; set; }
    public string? MetadataJson { get; set; }
}

/// <summary>What the visit's workflow is worked out from (usp_Api_OpdVisit_WorkflowFacts).</summary>
public class OpdVisitWorkflowFacts
{
    public int OPDServiceId { get; set; }
    public string? OPDBillNo { get; set; }
    public string? TokenNo { get; set; }
    public string? Status { get; set; }
    public bool IsActive { get; set; }
    public DateTime? VisitDate { get; set; }
    public TimeSpan? AppointmentTime { get; set; }
    public bool IsBooked { get; set; }
    public DateTime? BookedAt { get; set; }
    public string? BookedBy { get; set; }
    public string? PatientName { get; set; }
    public string? PatientCode { get; set; }
    public string? DoctorName { get; set; }
    public decimal? NetAmount { get; set; }
    public decimal? TotalPaid { get; set; }
    public decimal? BalanceDue { get; set; }
    public DateTime? PaidAt { get; set; }
    public DateTime? TokenAt { get; set; }
    public string? TokenBy { get; set; }
    public DateTime? ConsultStartAt { get; set; }
    public string? ConsultStartBy { get; set; }
    public DateTime? CompletedAt { get; set; }
    public string? CompletedBy { get; set; }
    public DateTime? VitalsAt { get; set; }
    public string? VitalsBy { get; set; }
    public int VitalsCount { get; set; }
    public DateTime? ConsultationSavedAt { get; set; }
    public string? ConsultationBy { get; set; }
    public DateTime? FollowUpDate { get; set; }
    public string? ReferredTo { get; set; }
    public bool IsVideo { get; set; }
    public DateTime? CancelledAt { get; set; }
    public string? CancelledBy { get; set; }
    public string? CancellationType { get; set; }
    public decimal? CancelledAmount { get; set; }
    public string? CancelReason { get; set; }
    public string? CancellationNo { get; set; }
}

/// <summary>A line of the visit's bill: Consulting or Service (the registration service is a Service with IsRegistration).</summary>
public class OpdVisitItem
{
    public string ServiceType { get; set; } = "";
    public string ItemName { get; set; } = "";
    public decimal ServiceCharges { get; set; }
    public bool IsRegistration { get; set; }
}

/// <summary>The branch's registration validity and the patient's last registration before this visit.</summary>
public class OpdVisitRegistrationFacts
{
    public int? ValidityDays { get; set; }
    public DateTime? LastRegisteredAt { get; set; }
    public string? LastRegisteredBillNo { get; set; }
}

/// <summary>A cancellation of the visit's bill: full (F) or part of it (P).</summary>
public class OpdVisitCancellation
{
    public DateTime CancellationDate { get; set; }
    public string? CancellationNo { get; set; }
    public string? CancellationType { get; set; }
    public decimal? CancelledAmount { get; set; }
    public string? Reason { get; set; }
    public string? CancelledBy { get; set; }
}

/// <summary>A stage of the visit: done / current / pending / issue / skipped.</summary>
public class OpdWorkflowStep
{
    public string Key { get; set; } = "";
    public string Label { get; set; } = "";
    public string Icon { get; set; } = "";
    public string State { get; set; } = "pending";
    public string Detail { get; set; } = "";
    public string? At { get; set; }
    public string? By { get; set; }
}

public class OpdWorkflowChange
{
    public string At { get; set; } = "";
    public string Kind { get; set; } = "";
    public string Title { get; set; } = "";
    public string Detail { get; set; } = "";
    public string? By { get; set; }
}

public class OpdVisitWorkflow
{
    public bool Success { get; set; }
    public string? Message { get; set; }
    public bool Cancelled { get; set; }
    public string? PatientName { get; set; }
    public string? BillNo { get; set; }
    /// <summary>CONSULT (consultation only), SERVICE (services only) or MIXED (both on one bill).</summary>
    public string VisitKind { get; set; } = "";
    public List<OpdWorkflowStep> Steps { get; set; } = [];
    /// <summary>Changes after billing: cancellation, refund.</summary>
    public List<OpdWorkflowChange> Rework { get; set; } = [];
}
