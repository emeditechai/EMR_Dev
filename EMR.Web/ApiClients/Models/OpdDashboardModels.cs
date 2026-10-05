using System;
using System.Collections.Generic;

namespace EMR.Web.ApiClients.Models;

public class OpdDashboardData
{
    public OpdSummaryStats Summary { get; set; } = new();
    public List<OpdStatusCount> BookingsByStatus { get; set; } = new();
    public List<OpdServiceTypeCount> BookingsByServiceType { get; set; } = new();
    public List<OpdDoctorRosterSummary> TodayRoster { get; set; } = new();
    public List<OpdRecentBooking> RecentBookings { get; set; } = new();
    public List<OpdRecentBooking> Appointments { get; set; } = new();
    /// <summary>The 7 days ending on the date (SQLScripts/2215).</summary>
    public List<OpdDayTrend> Trend { get; set; } = new();
}

public class OpdSummaryStats
{
    public int TotalPatientsCount { get; set; }
    public int TodayNewRegistrations { get; set; }
    public int TodayTotalBookings { get; set; }
    public decimal TodayTotalRevenue { get; set; }
    public int TodayRegisteredCount { get; set; }
    public int TodayCompletedCount { get; set; }
    public int TodayCancelledCount { get; set; }
    // SQLScripts/2215
    public int TodayConsultingCount { get; set; }
    public decimal TodayNetAmount { get; set; }
    public decimal TodayDiscount { get; set; }
    public decimal TodayCollected { get; set; }
    public decimal TodayDue { get; set; }
    public int TodayDueBills { get; set; }
    public int TodayBookedCount { get; set; }
    public int TodayWalkInCount { get; set; }
}

public class OpdStatusCount
{
    public string Status { get; set; } = string.Empty;
    public int Count { get; set; }
}

public class OpdServiceTypeCount
{
    public string ServiceType { get; set; } = string.Empty;
    public int Count { get; set; }
    public decimal Revenue { get; set; }
}

public class OpdDoctorRosterSummary
{
    public int DoctorId { get; set; }
    public string DoctorName { get; set; } = string.Empty;
    public int? ScheduleId { get; set; }
    public TimeSpan StartTime { get; set; }
    public TimeSpan EndTime { get; set; }
    public string? RoomName { get; set; }
    public string? FloorName { get; set; }
    public string? Speciality { get; set; }
    public int TotalVisits { get; set; }
    public int CompletedVisits { get; set; }
    public int PendingVisits { get; set; }
    public int InConsultationVisits { get; set; }
}

public class OpdRecentBooking
{
    public int OPDServiceId { get; set; }
    public string PatientCode { get; set; } = string.Empty;
    public string PatientName { get; set; } = string.Empty;
    public string? TokenNo { get; set; }
    public string? OPDBillNo { get; set; }
    public string? ConsultingDoctorName { get; set; }
    public decimal TotalAmount { get; set; }
    public decimal TotalPaid { get; set; }
    public string PaymentStatus { get; set; } = "U";
    public string Status { get; set; } = string.Empty;
    public DateTime VisitDate { get; set; }
    public TimeSpan? AppointmentTime { get; set; }
    // SQLScripts/2215
    public decimal NetAmount { get; set; }
    public bool IsBooked { get; set; }
    public string? Speciality { get; set; }
    public DateTime? RegisteredAt { get; set; }
}

public class OpdDayTrend
{
    public DateTime Day { get; set; }
    public int Visits { get; set; }
    public decimal Revenue { get; set; }
    public int NewPatients { get; set; }
}
