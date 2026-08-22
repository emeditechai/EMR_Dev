namespace EMR.Api.Models;

// ── 1. Doctor Visit Process Configuration DTOs ──────────────────────────────
public class DoctorVisitProcessConfigDto
{
    public int ProcessConfigId { get; set; }
    public int CompanyId { get; set; }
    public int? BranchId { get; set; }
    public string? BranchName { get; set; }
    public int? SpecialityId { get; set; }
    public string? SpecialityName { get; set; }
    public int? DoctorId { get; set; }
    public string? DoctorName { get; set; }
    public string VisitType { get; set; } = "All";
    public string PaymentTiming { get; set; } = "Before Consultation";
    public bool VitalsRequired { get; set; } = true;
    public bool DiagnosisRequired { get; set; } = true;
    public bool Icd10Required { get; set; } = true;
    public bool ProcedureAllowed { get; set; } = true;
    public bool BillingRequired { get; set; } = true;
    public bool PaymentBeforeClosure { get; set; } = true;
    public DateTime EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
    public bool IsActive { get; set; } = true;
    public DateTime CreatedDate { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public int? ModifiedBy { get; set; }
}

public class DoctorVisitProcessConfigSaveRequest
{
    public int? ProcessConfigId { get; set; }
    public int CompanyId { get; set; } = 1;
    public int? BranchId { get; set; }
    public int? SpecialityId { get; set; }
    public int? DoctorId { get; set; }
    public string VisitType { get; set; } = "All";
    public string PaymentTiming { get; set; } = "Before Consultation";
    public bool VitalsRequired { get; set; } = true;
    public bool DiagnosisRequired { get; set; } = true;
    public bool Icd10Required { get; set; } = true;
    public bool ProcedureAllowed { get; set; } = true;
    public bool BillingRequired { get; set; } = true;
    public bool PaymentBeforeClosure { get; set; } = true;
    public DateTime? EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
    public bool IsActive { get; set; } = true;
    public int? UserId { get; set; }
}

// ── 2. Doctor Commission Configuration DTOs ─────────────────────────────────
public class DoctorCommissionConfigDto
{
    public int CommissionConfigId { get; set; }
    public int CompanyId { get; set; }
    public int? BranchId { get; set; }
    public string? BranchName { get; set; }
    public int? DoctorId { get; set; }
    public string? DoctorName { get; set; }
    public int? SpecialityId { get; set; }
    public string? SpecialityName { get; set; }
    public string RevenueType { get; set; } = "Consultation";
    public string CalculationType { get; set; } = "Percentage";
    public string CommissionBasis { get; set; } = "Net Collected";
    public decimal DoctorShare { get; set; } = 70.00m;
    public int? ProcedureId { get; set; }
    public string? ProcedureName { get; set; }
    public int? ServiceId { get; set; }
    public string? ServiceName { get; set; }
    public int? CorporateId { get; set; }
    public string? CorporateName { get; set; }
    public int? InsuranceTPAId { get; set; }
    public string? InsuranceName { get; set; }
    public bool ApprovalRequired { get; set; } = true;
    public DateTime EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
    public bool IsActive { get; set; } = true;
    public DateTime CreatedDate { get; set; }
    public int? CreatedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public int? ModifiedBy { get; set; }
}

public class DoctorCommissionConfigSaveRequest
{
    public int? CommissionConfigId { get; set; }
    public int CompanyId { get; set; } = 1;
    public int? BranchId { get; set; }
    public int? DoctorId { get; set; }
    public int? SpecialityId { get; set; }
    public string RevenueType { get; set; } = "Consultation";
    public string CalculationType { get; set; } = "Percentage";
    public string CommissionBasis { get; set; } = "Net Collected";
    public decimal DoctorShare { get; set; } = 70.00m;
    public int? ProcedureId { get; set; }
    public int? ServiceId { get; set; }
    public int? CorporateId { get; set; }
    public int? InsuranceTPAId { get; set; }
    public bool ApprovalRequired { get; set; } = true;
    public DateTime? EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
    public bool IsActive { get; set; } = true;
    public int? UserId { get; set; }
}

// ── 3. Doctor Disbursal DTOs ────────────────────────────────────────────────
public class DoctorDisbursalDto
{
    public int DisbursalId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string? BranchName { get; set; }
    public int DoctorId { get; set; }
    public string DoctorName { get; set; } = string.Empty;
    public string? DoctorCode { get; set; }
    public string? SpecialityName { get; set; }
    public int VisitId { get; set; }
    public DateTime VisitDate { get; set; }
    public string? OPDBillNo { get; set; }
    public string? PatientCode { get; set; }
    public string? PatientName { get; set; }
    public int? BillId { get; set; }
    public int? ConsultationId { get; set; }
    public string RevenueType { get; set; } = "Consultation";
    public decimal GrossBillAmount { get; set; }
    public decimal DiscountAmount { get; set; }
    public decimal ApprovedAdjustment { get; set; }
    public decimal NetBillAmount { get; set; }
    public decimal CollectedAmount { get; set; }
    public string CommissionBasis { get; set; } = "Net Collected";
    public decimal EligibleAmount { get; set; }
    public int? CommissionConfigId { get; set; }
    public string CommissionRule { get; set; } = string.Empty;
    public decimal? CommissionPercentage { get; set; }
    public decimal CalculatedAmount { get; set; }
    public decimal AdjustmentAmount { get; set; }
    public string? AdjustmentReason { get; set; }
    public decimal NetPayable { get; set; }
    public string SettlementPeriod { get; set; } = string.Empty;
    public string ApprovalStatus { get; set; } = "CALCULATED";
    public string PaymentStatus { get; set; } = "Pending";
    public int? ApprovedBy { get; set; }
    public string? ApprovedByName { get; set; }
    public DateTime? ApprovedDate { get; set; }
    public string? PaymentMethod { get; set; }
    public string? PaymentReference { get; set; }
    public DateTime? PaidDate { get; set; }
    public int? PaidBy { get; set; }
    public string? PaidByName { get; set; }
    public string? DisbursalNotes { get; set; }
    public bool IsActive { get; set; } = true;
    public DateTime CreatedDate { get; set; }
}

public class DoctorBillingAdjustmentDto
{
    public int AdjustmentId { get; set; }
    public string AdjustmentType { get; set; } = string.Empty;
    public decimal Amount { get; set; }
    public string Reason { get; set; } = string.Empty;
    public DateTime AdjustmentDate { get; set; }
    public string? RequestedByName { get; set; }
    public string? ApprovedByName { get; set; }
}

public class DoctorDisbursalDetailDto : DoctorDisbursalDto
{
    public List<DoctorBillingAdjustmentDto> Adjustments { get; set; } = [];
}

public class DoctorDisbursalCalculateRequest
{
    public int BranchId { get; set; } = 1;
    public int? DoctorId { get; set; }
    public DateTime? FromDate { get; set; }
    public DateTime? ToDate { get; set; }
    public string? SettlementPeriod { get; set; }
    public int? UserId { get; set; }
    public int CompanyId { get; set; } = 1;
}

public class DoctorDisbursalAdjustmentRequest
{
    public int DisbursalId { get; set; }
    public string AdjustmentType { get; set; } = "Manual Correction";
    public decimal AdjustmentAmount { get; set; }
    public string Reason { get; set; } = string.Empty;
    public int? UserId { get; set; }
}

public class DoctorDisbursalStatusRequest
{
    public int DisbursalId { get; set; }
    public string ApprovalStatus { get; set; } = "APPROVED"; // APPROVED, ON_HOLD, REJECTED, SUBMITTED
    public string? DisbursalNotes { get; set; }
    public int? UserId { get; set; }
}

public class DoctorDisbursalBulkApproveRequest
{
    public string DisbursalIds { get; set; } = string.Empty; // e.g. "1,2,3"
    public int? UserId { get; set; }
}

public class DoctorDisbursalPayoutRequest
{
    public int DisbursalId { get; set; }
    public string PaymentMethod { get; set; } = "Bank Transfer";
    public string PaymentReference { get; set; } = string.Empty;
    public DateTime? PaidDate { get; set; }
    public string? DisbursalNotes { get; set; }
    public int? UserId { get; set; }
}

// ── 4. Financial Report DTOs (RPT-01 to RPT-08) ─────────────────────────────
public class VisitPaymentStatusReportItemDto
{
    public DateTime VisitDate { get; set; }
    public int VisitNo { get; set; }
    public string Patient { get; set; } = string.Empty;
    public string Doctor { get; set; } = string.Empty;
    public string? Bill { get; set; }
    public decimal NetAmount { get; set; }
    public decimal Paid { get; set; }
    public decimal Outstanding { get; set; }
    public string Status { get; set; } = "Unpaid";
}

public class OutstandingByVisitReportItemDto
{
    public DateTime VisitDate { get; set; }
    public int VisitNo { get; set; }
    public string Patient { get; set; } = string.Empty;
    public string Doctor { get; set; } = string.Empty;
    public string? Bill { get; set; }
    public decimal NetAmount { get; set; }
    public decimal Paid { get; set; }
    public decimal Outstanding { get; set; }
    public int DaysOld { get; set; }
    public string Aging { get; set; } = "Current"; // Current, 1–7 days, 8–30 days, 31–60 days, 61–90 days, 90+ days
    public string Status { get; set; } = "Unpaid"; // Unpaid, Partial, Paid, Overdue
}

public class DoctorCommissionReportItemDto
{
    public string Doctor { get; set; } = string.Empty;
    public int Visits { get; set; }
    public decimal EligibleCollection { get; set; }
    public decimal CommissionPercent { get; set; }
    public decimal CommissionAmount { get; set; }
    public decimal Adjustments { get; set; }
    public decimal NetPayable { get; set; }
    public decimal Paid { get; set; }
    public decimal YetToPay { get; set; }
}

public class DoctorDisbursalRegisterItemDto
{
    public int DisbursalId { get; set; }
    public string Doctor { get; set; } = string.Empty;
    public string Period { get; set; } = string.Empty;
    public decimal EligibleAmount { get; set; }
    public decimal Commission { get; set; }
    public decimal ApprovedAmount { get; set; }
    public decimal PaidAmount { get; set; }
    public string PaymentRef { get; set; } = "—";
    public DateTime? PaidDate { get; set; }
    public string Status { get; set; } = string.Empty;
}

public class PaymentTransactionReportItemDto
{
    public DateTime DateTime { get; set; }
    public int VisitNo { get; set; }
    public string Bill { get; set; } = string.Empty;
    public string Patient { get; set; } = string.Empty;
    public string PaymentMode { get; set; } = string.Empty;
    public decimal Amount { get; set; }
    public string TransactionReference { get; set; } = string.Empty;
    public string ReceivedBy { get; set; } = string.Empty;
}

public class BillingAdjustmentReportItemDto
{
    public DateTime Date { get; set; }
    public int VisitNo { get; set; }
    public string? Bill { get; set; }
    public string Doctor { get; set; } = string.Empty;
    public string AdjustmentType { get; set; } = string.Empty;
    public decimal Amount { get; set; }
    public string Reason { get; set; } = string.Empty;
    public string RequestedBy { get; set; } = string.Empty;
    public string ApprovedBy { get; set; } = string.Empty;
}

public class RefundReversalReportItemDto
{
    public DateTime? Date { get; set; }
    public int VisitNo { get; set; }
    public string? Bill { get; set; }
    public string Doctor { get; set; } = string.Empty;
    public decimal OriginalAmount { get; set; }
    public decimal RefundAmount { get; set; }
    public string? Reason { get; set; }
    public string ApprovedBy { get; set; } = string.Empty;
    public decimal CommissionReversal { get; set; }
}

public class DoctorSettlementSummaryItemDto
{
    public string Doctor { get; set; } = string.Empty;
    public string? Specialty { get; set; }
    public int Visits { get; set; }
    public decimal Collection { get; set; }
    public decimal Commission { get; set; }
    public decimal Paid { get; set; }
    public decimal YetToPay { get; set; }
}
