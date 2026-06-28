namespace EMR.Api.Models;

public class EmrConsultationResponse
{
    public EmrBookingInfo Booking { get; set; } = null!;
    public EmrTemplateInfo Template { get; set; } = null!;
    public EmrSavedConsultationInfo? SavedConsultation { get; set; }
}

public class EmrBookingInfo
{
    public string OpdBillNo { get; set; } = string.Empty;
    public int PatientId { get; set; }
    public string PatientCode { get; set; } = string.Empty;
    public string PatientName { get; set; } = string.Empty;
    public string Gender { get; set; } = string.Empty;
    public string Age { get; set; } = string.Empty;
    public string MobileNumber { get; set; } = string.Empty;
    public string VisitDate { get; set; } = string.Empty;
    public string BookedConsultingType { get; set; } = string.Empty;
}

public class EmrTemplateInfo
{
    public int TemplateId { get; set; }
    public string TemplateName { get; set; } = string.Empty;
    public List<EmrSectionInfo> Sections { get; set; } = new();
}

public class EmrSectionInfo
{
    public int SectionId { get; set; }
    public string SectionName { get; set; } = string.Empty;
    public List<EmrFieldInfo> Fields { get; set; } = new();
}

public class EmrFieldInfo
{
    public int FieldId { get; set; }
    public string FieldName { get; set; } = string.Empty;
    public string FieldType { get; set; } = string.Empty;
    public bool IsRequired { get; set; }
    public List<string> Options { get; set; } = new();
}

public class EmrSavedConsultationInfo
{
    public int ConsultationId { get; set; }
    public string VisitType { get; set; } = string.Empty;
    public string ConsultationType { get; set; } = string.Empty;
    public string EmrDataJson { get; set; } = string.Empty;
}

public class SaveConsultationRequest
{
    public int OPDServiceId { get; set; }
    public int PatientId { get; set; }
    public int DoctorId { get; set; }
    public int TemplateId { get; set; }
    
    public string OPDBillNo { get; set; } = string.Empty;
    public string PatientCode { get; set; } = string.Empty;
    public string PatientName { get; set; } = string.Empty;
    public string Gender { get; set; } = string.Empty;
    public string Age { get; set; } = string.Empty;
    public string MobileNumber { get; set; } = string.Empty;
    
    public string VisitType { get; set; } = string.Empty;
    public string ConsultationType { get; set; } = string.Empty;
    public string EmrDataJson { get; set; } = string.Empty;
    
    // For logging/auditing on API side
    public int RequestedByUserId { get; set; }
}
