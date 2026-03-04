namespace EMR.Api.Models;

// ── Doctor list row ──────────────────────────────────────────────────────────
public class DoctorListItem
{
    public int     DoctorId              { get; set; }
    public string  FullName              { get; set; } = string.Empty;
    public string? PrimarySpecialityName { get; set; }
    public string? DepartmentNames       { get; set; }
    public string? PhoneNumber           { get; set; }
    public string? EmailId               { get; set; }
    public bool    IsActive              { get; set; }
    public string? ConsultingFeeNames    { get; set; }    /// <summary>True when doctor has at least one OPD-type department mapped.</summary>
    public bool    HasOPDDept             { get; set; }}

// ── Doctor full detail ───────────────────────────────────────────────────────
public class DoctorDetail
{
    public int      DoctorId              { get; set; }
    public string   FullName              { get; set; } = string.Empty;
    public string   Gender                { get; set; } = string.Empty;
    public DateTime? DateOfBirth          { get; set; }
    public string   EmailId              { get; set; } = string.Empty;
    public string   PhoneNumber          { get; set; } = string.Empty;
    public string?  MedicalLicenseNo     { get; set; }
    public int      PrimarySpecialityId  { get; set; }
    public string?  PrimarySpeciality    { get; set; }
    public int?     SecondarySpecialityId { get; set; }
    public string?  SecondarySpeciality  { get; set; }
    public DateTime? JoiningDate         { get; set; }
    public bool     IsActive             { get; set; }
    public int      CreatedBranchId      { get; set; }
    public DateTime CreatedDate          { get; set; }
    public DateTime? ModifiedDate        { get; set; }
    public List<int> BranchIds           { get; set; } = [];
    public List<int> DepartmentIds       { get; set; } = [];
}

// ── Create / Update request ──────────────────────────────────────────────────
public class DoctorCreateRequest
{
    public string   FullName              { get; set; } = string.Empty;
    public string   Gender                { get; set; } = string.Empty;
    public DateTime? DateOfBirth          { get; set; }
    public string   EmailId               { get; set; } = string.Empty;
    public string   PhoneNumber           { get; set; } = string.Empty;
    public string?  MedicalLicenseNo      { get; set; }
    public int      PrimarySpecialityId   { get; set; }
    public int?     SecondarySpecialityId { get; set; }
    public DateTime? JoiningDate          { get; set; }
    public bool     IsActive              { get; set; } = true;
    public int      CreatedBranchId       { get; set; }
    public List<int> BranchIds            { get; set; } = [];
    public List<int> DepartmentIds        { get; set; } = [];
    public int?     RequestedByUserId     { get; set; }
}

public class DoctorUpdateRequest : DoctorCreateRequest
{
    public int DoctorId { get; set; }
}
