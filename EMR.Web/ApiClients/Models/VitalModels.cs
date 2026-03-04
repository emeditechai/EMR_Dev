namespace EMR.Web.ApiClients.Models;

// ── Create request sent to API ────────────────────────────────────────────────
public class VitalCreateRequest
{
    public int      PatientId         { get; set; }
    public decimal? Height            { get; set; }
    public decimal? Weight            { get; set; }
    public int?     BPSystolic        { get; set; }
    public int?     BPDiastolic       { get; set; }
    public int?     PulseRate         { get; set; }
    public decimal? SpO2              { get; set; }
    public decimal? Temperature       { get; set; }
    public int?     RespiratoryRate   { get; set; }
    public decimal? BloodGlucose      { get; set; }
    public string?  GlucoseType       { get; set; }
    public int?     PainScore         { get; set; }
    public string?  Notes             { get; set; }
    public int?     RecordedByUserId  { get; set; }
}

// ── Update request ────────────────────────────────────────────────────────────
public class VitalUpdateRequest
{
    public int      PatientVitalId    { get; set; }
    public decimal? Height            { get; set; }
    public decimal? Weight            { get; set; }
    public int?     BPSystolic        { get; set; }
    public int?     BPDiastolic       { get; set; }
    public int?     PulseRate         { get; set; }
    public decimal? SpO2              { get; set; }
    public decimal? Temperature       { get; set; }
    public int?     RespiratoryRate   { get; set; }
    public decimal? BloodGlucose      { get; set; }
    public string?  GlucoseType       { get; set; }
    public int?     PainScore         { get; set; }
    public string?  Notes             { get; set; }
    public int?     UpdatedByUserId   { get; set; }
}

// ── Vital row returned by API ─────────────────────────────────────────────────
public class VitalRow
{
    public int      PatientVitalId    { get; set; }
    public int      PatientId         { get; set; }
    public decimal? Height            { get; set; }
    public decimal? Weight            { get; set; }
    public decimal? BMI               { get; set; }
    public string?  BMICategory       { get; set; }
    public int?     BPSystolic        { get; set; }
    public int?     BPDiastolic       { get; set; }
    public int?     PulseRate         { get; set; }
    public decimal? SpO2              { get; set; }
    public decimal? Temperature       { get; set; }
    public int?     RespiratoryRate   { get; set; }
    public decimal? BloodGlucose      { get; set; }
    public string?  GlucoseType       { get; set; }
    public int?     PainScore         { get; set; }
    public string?  Notes             { get; set; }
    public DateTime RecordedOn        { get; set; }
    public string?  RecordedByName    { get; set; }
    public int      TotalCount        { get; set; }
    public bool     CanModify         { get; set; }
}

// ── Paged history result ──────────────────────────────────────────────────────
public class VitalHistoryResult
{
    public List<VitalRow> Rows       { get; set; } = [];
    public int            TotalCount { get; set; }
    public int            Page       { get; set; }
    public int            PageSize   { get; set; }
}

// ── Hospital print info ───────────────────────────────────────────────────────
public class HospitalPrintInfo
{
    public string? HospitalName    { get; set; }
    public string? Address         { get; set; }
    public string? ContactNumber1  { get; set; }
    public string? ContactNumber2  { get; set; }
    public string? EmailAddress    { get; set; }
    public string? Website         { get; set; }
    public string? LogoPath        { get; set; }
}

// ── Patient print info ────────────────────────────────────────────────────────
public class PatientPrintInfo
{
    public int       PatientId    { get; set; }
    public string    PatientCode  { get; set; } = string.Empty;
    public string    FullName     { get; set; } = string.Empty;
    public string?   PhoneNumber  { get; set; }
    public string?   Gender       { get; set; }
    public DateTime? DateOfBirth  { get; set; }
    public string?   BloodGroup   { get; set; }
    public string?   Address      { get; set; }
}

// ── Full print payload ────────────────────────────────────────────────────────
public class VitalPrintData
{
    public HospitalPrintInfo? Hospital      { get; set; }
    public PatientPrintInfo?  Patient       { get; set; }
    public VitalRow?          LatestVital   { get; set; }
    public string?            LastOpdBillNo { get; set; }
}
