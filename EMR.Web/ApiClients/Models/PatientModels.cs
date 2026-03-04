namespace EMR.Web.ApiClients.Models;

public class PatientListItem
{
    public int       PatientId     { get; set; }
    public string    PatientCode   { get; set; } = string.Empty;
    public string    FullName      { get; set; } = string.Empty;
    public string?   PhoneNumber   { get; set; }
    public string?   Gender        { get; set; }
    public DateTime? DateOfBirth   { get; set; }
    public string?   BloodGroup    { get; set; }
    public string?   Address       { get; set; }
    public int?      BranchId      { get; set; }
    public bool      IsActive      { get; set; }
    public DateTime  CreatedDate   { get; set; }
    public int       TotalCount    { get; set; }   // populated by paged SP
}

public class PatientDetail : PatientListItem
{
    public string?   Salutation             { get; set; }
    public string?   FirstName              { get; set; }
    public string?   MiddleName             { get; set; }
    public string?   LastName               { get; set; }
    public string?   SecondaryPhoneNumber   { get; set; }
    public string?   EmailId                { get; set; }
    public string?   GuardianName           { get; set; }
    public int?      RelationId             { get; set; }
    public string?   RelationName           { get; set; }
    public string?   KnownAllergies         { get; set; }
    public string?   Remarks                { get; set; }
    public string?   LastOpdBillNo          { get; set; }
}

public class PagedResult<T>
{
    public List<T> Items       { get; set; } = new();
    public int     TotalCount  { get; set; }
    public int     Page        { get; set; }
    public int     PageSize    { get; set; }
    public int     TotalPages  => PageSize > 0 ? (int)Math.Ceiling((double)TotalCount / PageSize) : 0;
}

public class PatientCreateRequest
{
    public string    PhoneNumber          { get; set; } = string.Empty;
    public string?   SecondaryPhoneNumber { get; set; }
    public string?   Salutation           { get; set; }
    public string    FirstName            { get; set; } = string.Empty;
    public string?   MiddleName           { get; set; }
    public string    LastName             { get; set; } = string.Empty;
    public string    Gender               { get; set; } = string.Empty;
    public DateTime? DateOfBirth          { get; set; }
    public string?   EmailId              { get; set; }
    public string?   GuardianName         { get; set; }
    public string?   Address              { get; set; }
    public int?      RelationId           { get; set; }
    public string?   BloodGroup           { get; set; }
    public string?   KnownAllergies       { get; set; }
    public string?   Remarks              { get; set; }
    public int?      BranchId             { get; set; }
    public int?      UserId               { get; set; }
}

public class PatientUpdateRequest : PatientCreateRequest
{
    public int PatientId { get; set; }
}
