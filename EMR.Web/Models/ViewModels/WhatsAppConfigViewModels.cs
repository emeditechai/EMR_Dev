using System;
using System.Collections.Generic;
using System.ComponentModel.DataAnnotations;
using EMR.Web.Models.Entities;

namespace EMR.Web.Models.ViewModels;

public class WhatsAppConfigViewModel
{
    public int Id { get; set; }

    public int BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;

    [Required(ErrorMessage = "Config Name is required")]
    [Display(Name = "Configuration Name")]
    public string ConfigName { get; set; } = "Primary WaSender API";

    [Required(ErrorMessage = "API URL is required")]
    [Display(Name = "API Endpoint URL")]
    public string ApiUrl { get; set; } = "https://wasenderapi.com/api/send-message";

    [Display(Name = "Auth Header Name")]
    public string AuthHeaderKey { get; set; } = "Authorization";

    [Required(ErrorMessage = "Bearer Token / API Key is required")]
    [Display(Name = "API Token (Bearer Key)")]
    public string ApiKey { get; set; } = string.Empty;

    [Display(Name = "Default Country Code")]
    public string DefaultCountryCode { get; set; } = "+91";

    [Display(Name = "Sender Phone (Optional)")]
    public string? SenderPhone { get; set; }

    [Display(Name = "Enable WhatsApp Service")]
    public bool IsEnabled { get; set; } = true;

    [Display(Name = "Send WhatsApp for OPD Bills")]
    public bool OpdNotificationEnabled { get; set; } = true;

    [Display(Name = "Send WhatsApp for LAB Bills")]
    public bool LabNotificationEnabled { get; set; } = true;

    [Display(Name = "OPD Bill Message Template")]
    public string OpdMessageTemplate { get; set; } = "Dear {PatientName}, thank you for visiting {HospitalName}. Your OPD Bill {BillNo} of Rs. {Amount} has been generated. Token: {TokenNo}, Doctor: {DoctorName}. Please find your bill attached. Wish you a speedy recovery!";

    [Display(Name = "LAB Bill Message Template")]
    public string LabMessageTemplate { get; set; } = "Dear {PatientName}, thank you for choosing {HospitalName}. Your Lab Order {BillNo} of Rs. {Amount} has been registered. Token: {TokenNo}. Please find your bill attached. Thank you!";

    [Display(Name = "Send WhatsApp for Video Consultations")]
    public bool VideoNotificationEnabled { get; set; } = true;

    [Display(Name = "Video Consultation Patient Template")]
    public string VideoPatientMessageTemplate { get; set; } = "Dear {PatientName}, your Video Consultation with Dr. {DoctorName} on {Date} at {Time} is confirmed. Join using: {Link}";

    [Display(Name = "Video Consultation Doctor Template")]
    public string VideoDoctorMessageTemplate { get; set; } = "Dear Dr. {DoctorName}, you have a Video Consultation scheduled with {PatientName} on {Date} at {Time}. Start using: {Link}";

    public bool IsHOBranch { get; set; }
    public List<Microsoft.AspNetCore.Mvc.Rendering.SelectListItem> TargetBranches { get; set; } = new();

    public DateTime? LastTestedDate { get; set; }
    public string? LastTestResult { get; set; }

    // Logs for active branch
    public List<WhatsAppLog> RecentLogs { get; set; } = new();
}

public class WhatsAppTestRequest
{
    [Required]
    public string ToPhone { get; set; } = string.Empty;

    public string? MessageText { get; set; }
}

public class CopyWhatsAppConfigRequest
{
    public int TargetBranchId { get; set; }
    public bool CopyToAll { get; set; }
}
