namespace EMR.Api.Models;

public class DailyCollectionRegisterItem
{
    public int PaymentHeaderId { get; set; }
    public string OPDBillNo { get; set; } = string.Empty;
    public string PatientCode { get; set; } = string.Empty;
    public string PatientName { get; set; } = string.Empty;
    public DateTime PaymentDate { get; set; }
    
    public decimal TotalAmount { get; set; }
    public decimal DiscountAmount { get; set; }
    public decimal NetAmount { get; set; }
    public decimal GstAmount { get; set; }
    public decimal TotalPaid { get; set; }
    public string? PaymentStatus { get; set; }
    public string? PaymentModes { get; set; }

    // Detailed Report (Item Wise) specific fields
    public string? ItemName { get; set; }
    public string? ServiceType { get; set; }
    public decimal ServiceCharges { get; set; }
    public decimal ItemDiscount { get; set; }
    public decimal GstPercentage { get; set; }
    public decimal ItemGstAmount { get; set; }
    public decimal ItemTotalAmount { get; set; }
    
    public string? CollectedBy { get; set; }
}

public class PatientRegisterItem
{
    public int PatientId { get; set; }
    public string PatientCode { get; set; } = string.Empty;
    public string PatientName { get; set; } = string.Empty;
    public string? PhoneNumber { get; set; }
    public string? Gender { get; set; }
    public int? Age { get; set; }
    public DateTime RegistrationDate { get; set; }
    public string? RelationName { get; set; }
    public string? ParentName { get; set; }
}
