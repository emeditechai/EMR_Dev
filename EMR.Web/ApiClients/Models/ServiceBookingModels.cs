namespace EMR.Web.ApiClients.Models;

// ── Service Booking list row ──────────────────────────────────────────────────
public class ServiceBookingListItem
{
    public int      OPDServiceId          { get; set; }
    public DateTime VisitDate             { get; set; }
    public string?  OPDBillNo             { get; set; }
    public string?  TokenNo               { get; set; }
    public string   PatientCode           { get; set; } = string.Empty;
    public int      PatientId             { get; set; }
    public string   PatientName           { get; set; } = string.Empty;
    public string?  Gender                { get; set; }
    public int?     Age                   { get; set; }
    public string?  ConsultingDoctorName  { get; set; }
    public decimal  TotalAmount           { get; set; }
    public string   Status                { get; set; } = string.Empty;
    public string   PaymentStatus         { get; set; } = "U";
    public string   ServiceTypesSummary   { get; set; } = string.Empty;
    public string?  CreatedByUser         { get; set; }
    // Aggregates
    public int      TotalCount            { get; set; }
    public decimal  TotalFeesAll          { get; set; }
    public int      RegisteredCount       { get; set; }
    public int      CompletedCount        { get; set; }
}

// ── Paged result ─────────────────────────────────────────────────────────────
public class ServiceBookingPagedResult
{
    public List<ServiceBookingListItem> Items          { get; set; } = new();
    public int     TotalCount      { get; set; }
    public decimal TotalFeesAll    { get; set; }
    public int     RegisteredCount { get; set; }
    public int     CompletedCount  { get; set; }
    public int     Page            { get; set; }
    public int     PageSize        { get; set; }
    public int     TotalPages      => PageSize > 0 ? (int)Math.Ceiling((double)TotalCount / PageSize) : 1;
}

// ── Detail line item ──────────────────────────────────────────────────────────
public class ServiceBookingDetailItem
{
    public int      ItemId          { get; set; }
    public string?  ServiceType     { get; set; }
    public string   ItemName        { get; set; } = string.Empty;
    public decimal  ServiceCharges  { get; set; }
    public bool     IsGstRequired   { get; set; }
    public decimal? GstPercentage   { get; set; }
}

// ── Detail header ─────────────────────────────────────────────────────────────
public class ServiceBookingDetail
{
    public int      OPDServiceId          { get; set; }
    public string?  OPDBillNo             { get; set; }
    public string?  TokenNo               { get; set; }
    public string   PatientCode           { get; set; } = string.Empty;
    public string   PatientName           { get; set; } = string.Empty;
    public string?  PhoneNumber           { get; set; }
    public string?  Gender                { get; set; }
    public DateTime? DateOfBirth          { get; set; }
    public string?  ConsultingDoctorName  { get; set; }
    public DateTime VisitDate             { get; set; }
    public TimeSpan? AppointmentTime      { get; set; }
    public DateTime CreatedDate           { get; set; }
    public string?  CreatedByUser         { get; set; }
    public decimal  TotalAmount           { get; set; }
    public string   Status                { get; set; } = string.Empty;
    public List<ServiceBookingDetailItem> Items { get; set; } = new();

    // Computed — mirrors ViewModels
    public int? Age => DateOfBirth.HasValue
        ? (int)((DateTime.Today - DateOfBirth.Value.Date).TotalDays / 365.25)
        : null;
}

// ── Doctor Dashboard Queue Result ─────────────────────────────────────────────
public class DoctorDashboardQueueItem
{
    public int      OPDServiceId          { get; set; }
    public DateTime VisitDate             { get; set; }
    public string?  OPDBillNo             { get; set; }
    public string?  TokenNo               { get; set; }
    public string   PatientCode           { get; set; } = string.Empty;
    public int      PatientId             { get; set; }
    public string   PatientName           { get; set; } = string.Empty;
    public string?  Gender                { get; set; }
    public int?     Age                   { get; set; }
    public string?  ConsultingDoctorName  { get; set; }
    public decimal  TotalAmount           { get; set; }
    public string   Status                { get; set; } = string.Empty;
    public string   PaymentStatus         { get; set; } = "U";
    public string?  PhotoPath             { get; set; }
    public bool     IsEmrDone             { get; set; }
    // ── Video fields ──────────────────────────────────────────────────────────
    public string   ConsultingType        { get; set; } = "Walk-In";
    public string?  VideoPatientUrl       { get; set; }
    public string?  VideoHostUrl          { get; set; }
    // ── Time fields ───────────────────────────────────────────────────────────
    public TimeSpan? SlotStartTime        { get; set; }
    public int?      SlotDurationMinutes  { get; set; }
}

public class DoctorDashboardQueueResult
{
    public List<DoctorDashboardQueueItem> Data { get; set; } = new();
    public int TotalWaiting { get; set; }
    public int TotalCompleted { get; set; }
}
