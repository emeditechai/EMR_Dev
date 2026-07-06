namespace EMR.Web.Models.Entities;

/// <summary>
/// Stores Whereby video consultation meeting details per OPD booking.
/// Mapped to tbl_VideoConsultation.
/// </summary>
public class VideoConsultation
{
    public int ConsultationId { get; set; }
    public int OPDServiceId { get; set; }
    public int DoctorId { get; set; }
    public int PatientId { get; set; }
    public string WherebyMeetingId { get; set; } = string.Empty;
    public string DoctorHostUrl { get; set; } = string.Empty;
    public string PatientRoomUrl { get; set; } = string.Empty;
    public string RoomNamePrefix { get; set; } = string.Empty;
    public DateTime MeetingStartDate { get; set; }
    public DateTime MeetingEndDate { get; set; }
    public int GraceTimeMinutes { get; set; } = 15;
    /// <summary>Scheduled | InProgress | Completed | Failed | Cancelled</summary>
    public string Status { get; set; } = "Scheduled";
    public bool DoctorEmailSent { get; set; } = false;
    public bool PatientEmailSent { get; set; } = false;
    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public string CreatedBy { get; set; } = "System";
    public string? ErrorMessage { get; set; }
}
