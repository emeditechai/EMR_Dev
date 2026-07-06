namespace EMR.Web.Services;

public class WherebyMeetingResult
{
    public string MeetingId { get; set; } = string.Empty;
    public string RoomUrl { get; set; } = string.Empty;
    public string HostRoomUrl { get; set; } = string.Empty;
    public DateTime StartDate { get; set; }
    public DateTime EndDate { get; set; }
}

public interface IWherebyService
{
    /// <summary>
    /// Generates the unique meeting room name prefix:
    /// "P" + PatientId + Date(yyyyMMdd) + SlotTime(HHmm), alphanumeric only.
    /// </summary>
    string GenerateMeetingPrefix(int patientId, DateTime appointmentDate, TimeSpan slotTime);

    /// <summary>
    /// Creates a Whereby video meeting room via the REST API.
    /// Returns null on failure.
    /// </summary>
    Task<WherebyMeetingResult?> CreateMeetingAsync(
        int patientId, DateTime appointmentDate, TimeSpan slotStartTime,
        TimeSpan slotEndTime, int graceTimeMinutes);
}
