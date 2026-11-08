using System.Text.Json;

namespace EMR.Web.Models.ViewModels;

/// <summary>The patient workspace: every block of usp_Api_IpdAdmission_Get.</summary>
public class IpdPatientView
{
    public JsonElement Header { get; set; }
    public List<JsonElement> Payers { get; set; } = [];
    public List<JsonElement> Attendants { get; set; } = [];
    public JsonElement Mlc { get; set; }
    public List<JsonElement> Consents { get; set; } = [];
    public List<JsonElement> Movements { get; set; } = [];
    public List<JsonElement> Advances { get; set; } = [];
    public List<JsonElement> Documents { get; set; } = [];
    public List<JsonElement> Log { get; set; } = [];
    public string Tab { get; set; } = "overview";
}

/// <summary>A print: hospital header (template or classic) + the document's rows.</summary>
public class IpdPrintView
{
    public string Title { get; set; } = "";
    public string? DocNo { get; set; }
    public JsonElement Header { get; set; }
    public JsonElement Doc { get; set; }
    public List<JsonElement> Rows { get; set; } = [];
    public List<JsonElement> Rows2 { get; set; } = [];
    public JsonElement Totals { get; set; }
    public string Format { get; set; } = "";
    public string PrintedBy { get; set; } = "";
}

/// <summary>Hospital header of an IPD print when the branch has no Bill print template (Hospital Settings).</summary>
public class IpdPrintHospital
{
    public string? Name { get; set; }
    public string? Address { get; set; }
    public string? Phone { get; set; }
    public string? Email { get; set; }
    public string? Gstin { get; set; }
    public string? RegistrationNo { get; set; }
    public string? Nabh { get; set; }
    public string? LogoPath { get; set; }
}
