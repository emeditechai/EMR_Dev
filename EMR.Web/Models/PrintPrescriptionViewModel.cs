using EMR.Web.ApiClients.Models;

namespace EMR.Web.Models;

public class PrintPrescriptionViewModel
{
    public ServiceBookingDetail Booking { get; set; } = null!;
    public DoctorDetail Doctor { get; set; } = null!;
    public VitalRow? Vitals { get; set; }
    
    public EmrConsultationResponse? EmrData { get; set; }
    
    // For standard Indian format
    public string HospitalName { get; set; } = "eClinicPlus+";
    public string HospitalAddress { get; set; } = "123, Health Avenue, Kolkata - 700001";
    public string HospitalContact { get; set; } = "+91 9876543210";
}
