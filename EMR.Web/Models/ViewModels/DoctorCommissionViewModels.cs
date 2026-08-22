using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

// ── 1. Doctor Visit Process Configuration ViewModels ────────────────────────
public class DoctorVisitProcessConfigListItemViewModel
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
}

public class DoctorVisitProcessConfigFormViewModel
{
    public int ProcessConfigId { get; set; }
    public int CompanyId { get; set; } = 1;

    [Display(Name = "Branch")]
    public int? BranchId { get; set; }

    [Display(Name = "Specialty")]
    public int? SpecialityId { get; set; }

    [Display(Name = "Doctor")]
    public int? DoctorId { get; set; }

    [Required(ErrorMessage = "Visit Type is required.")]
    [Display(Name = "Visit Type")]
    public string VisitType { get; set; } = "All"; // All, New, Follow-up, Emergency, Review, Consultation

    [Required(ErrorMessage = "Payment Timing is required.")]
    [Display(Name = "Payment Timing")]
    public string PaymentTiming { get; set; } = "Before Consultation"; // Before Consultation, After Consultation, At Discharge

    [Display(Name = "Vitals Required")]
    public bool VitalsRequired { get; set; } = true;

    [Display(Name = "Diagnosis Required")]
    public bool DiagnosisRequired { get; set; } = true;

    [Display(Name = "ICD-10 Required")]
    public bool Icd10Required { get; set; } = true;

    [Display(Name = "Procedure Allowed")]
    public bool ProcedureAllowed { get; set; } = true;

    [Display(Name = "Billing Required")]
    public bool BillingRequired { get; set; } = true;

    [Display(Name = "Payment Required Before Closure")]
    public bool PaymentBeforeClosure { get; set; } = true;

    [Required(ErrorMessage = "Effective From date is required.")]
    [DataType(DataType.Date)]
    [Display(Name = "Effective From")]
    public DateTime EffectiveFrom { get; set; } = DateTime.Today;

    [DataType(DataType.Date)]
    [Display(Name = "Effective To")]
    public DateTime? EffectiveTo { get; set; }

    [Display(Name = "Active Status")]
    public bool IsActive { get; set; } = true;

    // Dropdown options
    public List<SelectListItem> BranchOptions { get; set; } = [];
    public List<SelectListItem> SpecialityOptions { get; set; } = [];
    public List<SelectListItem> DoctorOptions { get; set; } = [];
    public List<SelectListItem> VisitTypeOptions { get; set; } = [];
    public List<SelectListItem> PaymentTimingOptions { get; set; } = [];
}

public class DoctorVisitProcessConfigIndexViewModel
{
    public IEnumerable<DoctorVisitProcessConfigListItemViewModel> Items { get; set; } = [];
    public int? SelectedBranchId { get; set; }
    public int? SelectedSpecialityId { get; set; }
    public int? SelectedDoctorId { get; set; }
    public string? SelectedVisitType { get; set; }
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }

    public List<SelectListItem> BranchOptions { get; set; } = [];
    public List<SelectListItem> SpecialityOptions { get; set; } = [];
    public List<SelectListItem> DoctorOptions { get; set; } = [];
}

// ── 2. Doctor Commission Configuration ViewModels ───────────────────────────
public class DoctorCommissionConfigListItemViewModel
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
}

public class DoctorCommissionConfigFormViewModel
{
    public int CommissionConfigId { get; set; }
    public int CompanyId { get; set; } = 1;

    [Display(Name = "Branch (Optional)")]
    public int? BranchId { get; set; }

    [Display(Name = "Doctor (Optional — All in Speciality if blank)")]
    public int? DoctorId { get; set; }

    [Display(Name = "Specialty (Optional)")]
    public int? SpecialityId { get; set; }

    [Required(ErrorMessage = "Revenue Type is required.")]
    [Display(Name = "Revenue Type")]
    public string RevenueType { get; set; } = "Consultation"; // Consultation, Procedure, Investigation, Package, Emergency, Telemedicine, All Services

    [Required(ErrorMessage = "Calculation Type is required.")]
    [Display(Name = "Calculation Type")]
    public string CalculationType { get; set; } = "Percentage"; // Percentage, Fixed Amount, Tiered

    [Required(ErrorMessage = "Commission Basis is required.")]
    [Display(Name = "Commission Basis")]
    public string CommissionBasis { get; set; } = "Net Collected"; // Net Collected, Gross Bill, Net Bill (After Discount), Base Tariff

    [Required(ErrorMessage = "Doctor Share is required.")]
    [Range(0, 1000000, ErrorMessage = "Doctor Share must be greater than or equal to 0.")]
    [Display(Name = "Doctor Share (% or Flat ₹)")]
    public decimal DoctorShare { get; set; } = 70.00m;

    [Display(Name = "Procedure Specific Override (Optional)")]
    public int? ProcedureId { get; set; }

    [Display(Name = "Service Specific Override (Optional)")]
    public int? ServiceId { get; set; }

    [Display(Name = "Corporate Specific Rule (Optional)")]
    public int? CorporateId { get; set; }

    [Display(Name = "Insurance / TPA Rule (Optional)")]
    public int? InsuranceTPAId { get; set; }

    [Display(Name = "Approval Required Before Disbursal")]
    public bool ApprovalRequired { get; set; } = true;

    [Required(ErrorMessage = "Effective From date is required.")]
    [DataType(DataType.Date)]
    [Display(Name = "Effective From")]
    public DateTime EffectiveFrom { get; set; } = DateTime.Today;

    [DataType(DataType.Date)]
    [Display(Name = "Effective To")]
    public DateTime? EffectiveTo { get; set; }

    [Display(Name = "Active Status")]
    public bool IsActive { get; set; } = true;

    // Dropdowns
    public List<SelectListItem> BranchOptions { get; set; } = [];
    public List<SelectListItem> DoctorOptions { get; set; } = [];
    public List<SelectListItem> SpecialityOptions { get; set; } = [];
    public List<SelectListItem> RevenueTypeOptions { get; set; } = [];
    public List<SelectListItem> CalculationTypeOptions { get; set; } = [];
    public List<SelectListItem> CommissionBasisOptions { get; set; } = [];
    public List<SelectListItem> ProcedureOptions { get; set; } = [];
    public List<SelectListItem> ServiceOptions { get; set; } = [];
    public List<SelectListItem> CorporateOptions { get; set; } = [];
    public List<SelectListItem> InsuranceOptions { get; set; } = [];
}

public class DoctorCommissionConfigIndexViewModel
{
    public IEnumerable<DoctorCommissionConfigListItemViewModel> Items { get; set; } = [];
    public int? SelectedBranchId { get; set; }
    public int? SelectedDoctorId { get; set; }
    public int? SelectedSpecialityId { get; set; }
    public string? SelectedRevenueType { get; set; }
    public bool? SelectedStatus { get; set; }
    public string? SearchTerm { get; set; }

    public List<SelectListItem> BranchOptions { get; set; } = [];
    public List<SelectListItem> DoctorOptions { get; set; } = [];
    public List<SelectListItem> SpecialityOptions { get; set; } = [];
    public List<SelectListItem> RevenueTypeOptions { get; set; } = [];
}

// ── 3. Doctor Disbursal Workbench ViewModels ────────────────────────────────
public class DoctorDisbursalListItemViewModel
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

public class DoctorBillingAdjustmentViewModel
{
    public int AdjustmentId { get; set; }
    public string AdjustmentType { get; set; } = string.Empty;
    public decimal Amount { get; set; }
    public string Reason { get; set; } = string.Empty;
    public DateTime AdjustmentDate { get; set; }
    public string? RequestedByName { get; set; }
    public string? ApprovedByName { get; set; }
}

public class DoctorDisbursalDetailsViewModel : DoctorDisbursalListItemViewModel
{
    public List<DoctorBillingAdjustmentViewModel> Adjustments { get; set; } = [];
}

public class DoctorDisbursalIndexViewModel
{
    public IEnumerable<DoctorDisbursalListItemViewModel> Items { get; set; } = [];

    // KPI Metrics
    public int TotalVisitsCount => Items.Count();
    public decimal TotalEligibleCollection => Items.Sum(x => x.EligibleAmount);
    public decimal TotalCommissionCalculated => Items.Sum(x => x.CalculatedAmount);
    public decimal TotalNetPayable => Items.Sum(x => x.NetPayable);
    public decimal TotalPaid => Items.Where(x => x.PaymentStatus == "Paid").Sum(x => x.NetPayable);
    public decimal TotalYetToPay => Items.Where(x => x.PaymentStatus != "Paid").Sum(x => x.NetPayable);

    // Filters
    public int? SelectedDoctorId { get; set; }
    public string? SelectedPeriod { get; set; }
    public string? SelectedApprovalStatus { get; set; }
    public string? SelectedPaymentStatus { get; set; }
    public DateTime? FromDate { get; set; }
    public DateTime? ToDate { get; set; }
    public string? SearchTerm { get; set; }

    public List<SelectListItem> DoctorOptions { get; set; } = [];
    public List<SelectListItem> PeriodOptions { get; set; } = [];
    public List<SelectListItem> ApprovalStatusOptions { get; set; } = [];
    public List<SelectListItem> PaymentStatusOptions { get; set; } = [];
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
    public string Aging { get; set; } = "Current";
    public string Status { get; set; } = "Unpaid";
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

// ── 5. Financial Report ViewModels ──────────────────────────────────────────
public class VisitPaymentStatusReportViewModel
{
    public IEnumerable<VisitPaymentStatusReportItemDto> Rows { get; set; } = [];
    public int? SelectedDoctorId { get; set; }
    public DateTime? FromDate { get; set; }
    public DateTime? ToDate { get; set; }
    public List<SelectListItem> DoctorOptions { get; set; } = [];
    public decimal TotalNet => Rows.Sum(x => x.NetAmount);
    public decimal TotalPaid => Rows.Sum(x => x.Paid);
    public decimal TotalOutstanding => Rows.Sum(x => x.Outstanding);
}

public class OutstandingByVisitReportViewModel
{
    public IEnumerable<OutstandingByVisitReportItemDto> Rows { get; set; } = [];
    public int? SelectedDoctorId { get; set; }
    public DateTime? FromDate { get; set; }
    public DateTime? ToDate { get; set; }
    public List<SelectListItem> DoctorOptions { get; set; } = [];
    public decimal TotalOutstanding => Rows.Sum(x => x.Outstanding);
    public int OverdueCount => Rows.Count(x => x.Status == "Overdue");
}

public class DoctorCommissionReportViewModel
{
    public IEnumerable<DoctorCommissionReportItemDto> Rows { get; set; } = [];
    public int? SelectedDoctorId { get; set; }
    public string? SelectedPeriod { get; set; }
    public DateTime? FromDate { get; set; }
    public DateTime? ToDate { get; set; }
    public List<SelectListItem> DoctorOptions { get; set; } = [];
    public List<SelectListItem> PeriodOptions { get; set; } = [];
    public decimal TotalCollection => Rows.Sum(x => x.EligibleCollection);
    public decimal TotalCommission => Rows.Sum(x => x.CommissionAmount);
    public decimal TotalNetPayable => Rows.Sum(x => x.NetPayable);
    public decimal TotalPaid => Rows.Sum(x => x.Paid);
    public decimal TotalYetToPay => Rows.Sum(x => x.YetToPay);
}

public class DoctorDisbursalRegisterReportViewModel
{
    public IEnumerable<DoctorDisbursalRegisterItemDto> Rows { get; set; } = [];
    public int? SelectedDoctorId { get; set; }
    public string? SelectedPeriod { get; set; }
    public string? SelectedPaymentStatus { get; set; }
    public DateTime? FromDate { get; set; }
    public DateTime? ToDate { get; set; }
    public List<SelectListItem> DoctorOptions { get; set; } = [];
    public List<SelectListItem> PeriodOptions { get; set; } = [];
    public decimal TotalApproved => Rows.Sum(x => x.ApprovedAmount);
    public decimal TotalPaid => Rows.Sum(x => x.PaidAmount);
}

public class PaymentTransactionReportViewModel
{
    public IEnumerable<PaymentTransactionReportItemDto> Rows { get; set; } = [];
    public int? SelectedPaymentMethodId { get; set; }
    public DateTime? FromDate { get; set; }
    public DateTime? ToDate { get; set; }
    public List<SelectListItem> PaymentMethodOptions { get; set; } = [];
    public decimal TotalAmount => Rows.Sum(x => x.Amount);
}

public class BillingAdjustmentReportViewModel
{
    public IEnumerable<BillingAdjustmentReportItemDto> Rows { get; set; } = [];
    public int? SelectedDoctorId { get; set; }
    public DateTime? FromDate { get; set; }
    public DateTime? ToDate { get; set; }
    public List<SelectListItem> DoctorOptions { get; set; } = [];
    public decimal TotalAdjustments => Rows.Sum(x => x.Amount);
}

public class RefundReversalReportViewModel
{
    public IEnumerable<RefundReversalReportItemDto> Rows { get; set; } = [];
    public DateTime? FromDate { get; set; }
    public DateTime? ToDate { get; set; }
    public decimal TotalRefunded => Rows.Sum(x => x.RefundAmount);
    public decimal TotalReversedCommission => Rows.Sum(x => x.CommissionReversal);
}

public class DoctorSettlementSummaryReportViewModel
{
    public IEnumerable<DoctorSettlementSummaryItemDto> Rows { get; set; } = [];
    public int? SelectedDoctorId { get; set; }
    public string? SelectedPeriod { get; set; }
    public List<SelectListItem> DoctorOptions { get; set; } = [];
    public List<SelectListItem> PeriodOptions { get; set; } = [];
    public decimal TotalCollection => Rows.Sum(x => x.Collection);
    public decimal TotalCommission => Rows.Sum(x => x.Commission);
    public decimal TotalPaid => Rows.Sum(x => x.Paid);
    public decimal TotalYetToPay => Rows.Sum(x => x.YetToPay);
}
