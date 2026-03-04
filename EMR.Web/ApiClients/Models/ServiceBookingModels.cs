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
    public string   ServiceTypesSummary   { get; set; } = string.Empty;
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
    public string?  ServiceType     { get; set; }
    public string   ItemName        { get; set; } = string.Empty;
    public decimal  ServiceCharges  { get; set; }
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
    public decimal  TotalAmount           { get; set; }
    public string   Status                { get; set; } = string.Empty;
    public List<ServiceBookingDetailItem> Items { get; set; } = new();

    // Computed — mirrors ViewModels
    public int? Age => DateOfBirth.HasValue
        ? (int)((DateTime.Today - DateOfBirth.Value.Date).TotalDays / 365.25)
        : null;
}
