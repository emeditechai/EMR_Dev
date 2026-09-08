using System;

namespace EMR.Web.Models.Entities;

public class WhatsAppConfiguration
{
    public int Id { get; set; }
    public int BranchId { get; set; }
    public int? CompanyId { get; set; }
    public string ConfigName { get; set; } = "Primary WaSender API";
    public string ApiUrl { get; set; } = "https://wasenderapi.com/api/send-message";
    public string AuthHeaderKey { get; set; } = "Authorization";
    public string ApiKey { get; set; } = string.Empty;
    public string DefaultCountryCode { get; set; } = "+91";
    public string? SenderPhone { get; set; }
    public bool IsEnabled { get; set; } = true;
    public bool OpdNotificationEnabled { get; set; } = true;
    public bool LabNotificationEnabled { get; set; } = true;
    public string OpdMessageTemplate { get; set; } = "Dear {PatientName}, thank you for visiting {HospitalName}. Your OPD Bill {BillNo} of Rs. {Amount} has been generated. Token: {TokenNo}, Doctor: {DoctorName}. Please find your bill attached. Wish you a speedy recovery!";
    public string LabMessageTemplate { get; set; } = "Dear {PatientName}, thank you for choosing {HospitalName}. Your Lab Order {BillNo} of Rs. {Amount} has been registered. Token: {TokenNo}. Please find your bill attached. Thank you!";
    public bool VideoNotificationEnabled { get; set; } = true;
    public string VideoPatientMessageTemplate { get; set; } = "Dear {PatientName}, your Video Consultation with Dr. {DoctorName} on {Date} at {Time} is confirmed. Join using: {Link}";
    public string VideoDoctorMessageTemplate { get; set; } = "Dear Dr. {DoctorName}, you have a Video Consultation scheduled with {PatientName} on {Date} at {Time}. Start using: {Link}";
    public bool IsDefault { get; set; } = true;
    public bool IsActive { get; set; } = true;
    public DateTime? LastTestedDate { get; set; }
    public string? LastTestResult { get; set; }
    public string? CreatedBy { get; set; }
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public string? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}
