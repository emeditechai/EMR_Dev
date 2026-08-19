using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Models.ViewModels;

public class BedRoomTariffListItemViewModel
{
    public int BedRateId { get; set; }
    public int WardId { get; set; }
    public string WardName { get; set; } = string.Empty;
    public string WardCode { get; set; } = string.Empty;
    public int RoomId { get; set; }
    public string RoomNumber { get; set; } = string.Empty;
    public string? RoomType { get; set; }
    public int BedCategoryId { get; set; }
    public string BedCategoryName { get; set; } = string.Empty;
    public int TariffCategoryId { get; set; }
    public string TariffCategoryName { get; set; } = string.Empty;
    public string? TariffCategoryCode { get; set; }
    public string? PatientCategory { get; set; }
    public DateTime EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
    public decimal RoomCharge { get; set; }
    public decimal BedCharge { get; set; }
    public decimal NursingCharge { get; set; }
    public decimal AttendantCharge { get; set; }
    public decimal IsolationCharge { get; set; }
    public decimal GstPercentage { get; set; }
    public decimal TotalBaseCharge => RoomCharge + BedCharge + NursingCharge + AttendantCharge + IsolationCharge;
    public decimal TotalGstAmount => Math.Round(TotalBaseCharge * (GstPercentage / 100m), 2);
    public decimal TotalGrossAmount => TotalBaseCharge + TotalGstAmount;
    public bool IsActive { get; set; }
}

public class BedRoomTariffFormViewModel : IValidatableObject
{
    public int BedRateId { get; set; }

    public int CompanyId { get; set; } = 1;

    [Display(Name = "Branch")]
    public int BranchId { get; set; }

    [Required(ErrorMessage = "Ward is required.")]
    [Display(Name = "Ward")]
    public int? WardId { get; set; }

    [Required(ErrorMessage = "IPD Room is required.")]
    [Display(Name = "IPD Room")]
    public int? RoomId { get; set; }

    [Required(ErrorMessage = "Bed Category is required.")]
    [Display(Name = "Bed Category")]
    public int? BedCategoryId { get; set; }

    [Required(ErrorMessage = "Tariff Category is required.")]
    [Display(Name = "Tariff Category (Payer / Rate Schedule)")]
    public int? TariffCategoryId { get; set; }

    [Required(ErrorMessage = "Effective From Date is required.")]
    [DataType(DataType.Date)]
    [Display(Name = "Effective From")]
    public DateTime EffectiveFrom { get; set; } = DateTime.Today;

    [DataType(DataType.Date)]
    [Display(Name = "Effective To (Optional / Open-ended)")]
    public DateTime? EffectiveTo { get; set; }

    [Range(0, 9999999.99, ErrorMessage = "Room charge cannot be negative.")]
    [Display(Name = "Room Charge (₹)")]
    public decimal RoomCharge { get; set; } = 0;

    [Range(0, 9999999.99, ErrorMessage = "Bed charge cannot be negative.")]
    [Display(Name = "Bed Charge (₹)")]
    public decimal BedCharge { get; set; } = 0;

    [Range(0, 9999999.99, ErrorMessage = "Nursing charge cannot be negative.")]
    [Display(Name = "Nursing Charge (₹)")]
    public decimal NursingCharge { get; set; } = 0;

    [Range(0, 9999999.99, ErrorMessage = "Attendant charge cannot be negative.")]
    [Display(Name = "Attendant Charge (₹)")]
    public decimal AttendantCharge { get; set; } = 0;

    [Range(0, 9999999.99, ErrorMessage = "Isolation Charge (₹)")]
    [Display(Name = "Isolation Charge (₹)")]
    public decimal IsolationCharge { get; set; } = 0;

    [Range(0, 100, ErrorMessage = "GST % must be between 0 and 100.")]
    [Display(Name = "GST %")]
    public decimal GstPercentage { get; set; } = 0;

    [MaxLength(500, ErrorMessage = "Maximum 500 characters allowed.")]
    [Display(Name = "Change Reason / Pricing Justification")]
    public string? ChangeReason { get; set; }

    [Display(Name = "Active")]
    public bool IsActive { get; set; } = true;

    // Dropdowns
    public IEnumerable<SelectListItem> WardOptions { get; set; } = new List<SelectListItem>();
    public IEnumerable<SelectListItem> RoomOptions { get; set; } = new List<SelectListItem>();
    public IEnumerable<SelectListItem> BedCategoryOptions { get; set; } = new List<SelectListItem>();
    public IEnumerable<SelectListItem> TariffCategoryOptions { get; set; } = new List<SelectListItem>();

    public IEnumerable<ValidationResult> Validate(ValidationContext validationContext)
    {
        if (EffectiveTo.HasValue && EffectiveTo.Value.Date < EffectiveFrom.Date)
        {
            yield return new ValidationResult(
                "Effective To Date cannot be earlier than Effective From Date.",
                new[] { nameof(EffectiveTo) });
        }
    }
}

public class BedRoomTariffDetailsViewModel
{
    public int BedRateId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string? BranchName { get; set; }
    public int WardId { get; set; }
    public string WardName { get; set; } = string.Empty;
    public string WardCode { get; set; } = string.Empty;
    public int RoomId { get; set; }
    public string RoomNumber { get; set; } = string.Empty;
    public string? RoomType { get; set; }
    public int BedCategoryId { get; set; }
    public string BedCategoryName { get; set; } = string.Empty;
    public int TariffCategoryId { get; set; }
    public string TariffCategoryName { get; set; } = string.Empty;
    public string? TariffCategoryCode { get; set; }
    public string? PatientCategory { get; set; }
    public DateTime EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
    public decimal RoomCharge { get; set; }
    public decimal BedCharge { get; set; }
    public decimal NursingCharge { get; set; }
    public decimal AttendantCharge { get; set; }
    public decimal IsolationCharge { get; set; }
    public decimal GstPercentage { get; set; }
    public decimal TotalBaseCharge => RoomCharge + BedCharge + NursingCharge + AttendantCharge + IsolationCharge;
    public decimal TotalGstAmount => Math.Round(TotalBaseCharge * (GstPercentage / 100m), 2);
    public decimal TotalGrossAmount => TotalBaseCharge + TotalGstAmount;
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public int? CreatedBy { get; set; }
    public int? ModifiedBy { get; set; }

    public List<BedRoomTariffHistoryItemViewModel> HistoryLogs { get; set; } = new();
}

public class BedRoomTariffHistoryItemViewModel
{
    public int HistoryId { get; set; }
    public int BedRateId { get; set; }
    public DateTime EffectiveFrom { get; set; }
    public DateTime? EffectiveTo { get; set; }
    public decimal RoomCharge { get; set; }
    public decimal BedCharge { get; set; }
    public decimal NursingCharge { get; set; }
    public decimal AttendantCharge { get; set; }
    public decimal IsolationCharge { get; set; }
    public decimal GstPercentage { get; set; }
    public decimal TotalBaseCharge => RoomCharge + BedCharge + NursingCharge + AttendantCharge + IsolationCharge;
    public decimal TotalGstAmount => Math.Round(TotalBaseCharge * (GstPercentage / 100m), 2);
    public decimal TotalGrossAmount => TotalBaseCharge + TotalGstAmount;
    public bool IsActive { get; set; }
    public string ChangeAction { get; set; } = string.Empty;
    public string? ChangeReason { get; set; }
    public string? ChangedByName { get; set; }
    public DateTime ChangedDate { get; set; }
}
