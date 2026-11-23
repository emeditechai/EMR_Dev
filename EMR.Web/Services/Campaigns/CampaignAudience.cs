namespace EMR.Web.Services.Campaigns;

/// <summary>Utility > Campaigns (SQLScripts/2299): the audiences, the merge fields each one fills in (the values are
/// stored per recipient by EMR.Api) and the starting message. Data goes through ICampaignApiClient.</summary>
public static class CampaignAudiences
{
    public static readonly IReadOnlyDictionary<char, string> Names = new Dictionary<char, string> { ['P'] = "Patients", ['U'] = "Users", ['D'] = "Doctors" };
    public static string Name(char type) => Names.TryGetValue(type, out var n) ? n : "Recipients";
    public static string Single(char type) => type switch { 'P' => "Patient", 'U' => "User", 'D' => "Doctor", _ => "Recipient" };

    /// <summary>Merge fields each audience fills in (codes used as {{Code}} in subject and message).</summary>
    public static IReadOnlyList<EmailField> Fields(char type) => type switch
    {
        'P' => [new("Name", "Patient Name", "Mr. Rahul Sharma"), new("FirstName", "First Name", "Rahul"), new("PatientCode", "Patient ID", "PHO2627000053"), Hospital],
        'U' => [new("Name", "User Name", "Priya Das"), new("FirstName", "First Name", "Priya"), new("LoginId", "Login ID", "priya.das"), Hospital],
        'D' => [new("Name", "Doctor Name", "Dr. Anirban Sen"), new("FirstName", "First Name", "Anirban"), new("Speciality", "Speciality", "Cardiology"), Hospital],
        _ => [Hospital]
    };
    private static readonly EmailField Hospital = new("HospitalName", "Hospital Name", "City Care Hospital");

    public static EmailTemplateDesign StarterDesign(char type) => new()
    {
        Heading = type switch { 'P' => "A message from {{HospitalName}}", 'U' => "Staff update", _ => "An update for our doctors" },
        Message = type == 'P'
            ? "<p>Dear <strong>{{Name}}</strong>,</p><p>Write your message here.</p>"
            : "<p>Dear {{FirstName}},</p><p>Write your message here.</p>",
        NoteStyle = "info",
        Closing = "Warm regards,",
        Signature = "{{HospitalName}}"
    };
}
