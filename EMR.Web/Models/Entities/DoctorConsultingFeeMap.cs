namespace EMR.Web.Models.Entities;

public class DoctorConsultingFeeMap
{
    public int MappingId  { get; set; }
    public int DoctorId   { get; set; }
    public int ServiceId  { get; set; }
    public int BranchId   { get; set; }
    public bool IsActive  { get; set; } = true;
    public int? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;

    // Joined fields (read only)
    public string ItemCode    { get; set; } = string.Empty;
    public string ItemName    { get; set; } = string.Empty;
    public decimal ItemCharges { get; set; }
}
