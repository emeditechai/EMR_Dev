namespace EMR.Web.ApiClients.Models;

public class PortalDashboardSummary
{
    public int TotalBookings { get; set; }
    public int UpcomingBookings { get; set; }
    public int TotalPrescriptions { get; set; }
    public string LastVisitDate { get; set; } = string.Empty;
}

public class PortalFullProfile
{
    public int PatientId { get; set; }
    public string PatientCode { get; set; } = string.Empty;
    public string FullName { get; set; } = string.Empty;
    public string Initials { get; set; } = string.Empty;
    public string? PhotoPath { get; set; }
    public bool IsActive { get; set; }
    public string Gender { get; set; } = string.Empty;
    public string Age { get; set; } = string.Empty;
    public string BloodGroup { get; set; } = string.Empty;
    
    public string PhoneNumber { get; set; } = string.Empty;
    public string? SecondaryPhoneNumber { get; set; }
    public string? EmailId { get; set; }
    public string RegistrationDate { get; set; } = string.Empty;

    public string Address { get; set; } = string.Empty;
    public string Area { get; set; } = string.Empty;
    public string City { get; set; } = string.Empty;
    public string District { get; set; } = string.Empty;
    public string State { get; set; } = string.Empty;
    public string Country { get; set; } = string.Empty;

    public string DateOfBirth { get; set; } = string.Empty;
    public string Salutation { get; set; } = string.Empty;
    public string Religion { get; set; } = string.Empty;
    public string Occupation { get; set; } = string.Empty;
    public string MaritalStatus { get; set; } = string.Empty;
    public string GuardianName { get; set; } = string.Empty;
    public string IdentificationDoc { get; set; } = string.Empty;

    public string KnownAllergies { get; set; } = string.Empty;
    public string Remarks { get; set; } = string.Empty;
}

public class PortalDependent
{
    public int PatientId { get; set; }
    public string PatientCode { get; set; } = string.Empty;
    public string FullName { get; set; } = string.Empty;
    public string Relation { get; set; } = string.Empty;
    public string Gender { get; set; } = string.Empty;
    public string Age { get; set; } = string.Empty;
}

public class PortalVital
{
    public int VitalId { get; set; }
    public DateTime RecordDate { get; set; }
    public string BpSystolic { get; set; } = string.Empty;
    public string BpDiastolic { get; set; } = string.Empty;
    public string HeartRate { get; set; } = string.Empty;
    public string Temperature { get; set; } = string.Empty;
    public string Weight { get; set; } = string.Empty;
    public string Height { get; set; } = string.Empty;
    public string Spo2 { get; set; } = string.Empty;
}

public class PortalBooking
{
    public int OpdServiceId { get; set; }
    public string TokenNo { get; set; } = string.Empty;
    public DateTime VisitDate { get; set; }
    public string DoctorName { get; set; } = string.Empty;
    public string Department { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public decimal TotalAmount { get; set; }
    public string PaymentStatus { get; set; } = string.Empty;
}

public class PortalPrescription
{
    public int ConsultationId { get; set; }
    public DateTime ConsultationDate { get; set; }
    public int DoctorId { get; set; }
    public string DoctorName { get; set; } = string.Empty;
    public int OpdServiceId { get; set; }
    public string EmrDataJson { get; set; } = string.Empty;
}
