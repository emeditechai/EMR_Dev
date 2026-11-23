namespace EMR.Api.PatientApp;

/// <summary>
/// Where EMR.Web keeps the files the patient app's PDFs show: the hospital logo and print-template images (EMR.Web wwwroot)
/// and the doctors' signatures (EMR.Web App_Data/signatures). Set "PatientApp:WebRootPath" and "PatientApp:SignaturesPath"
/// on the server; by default the EMR.Web folder next to this API's folder.
/// </summary>
public sealed class PatientAppFiles(IConfiguration config, IWebHostEnvironment env)
{
    private string Web => Path.GetFullPath(Path.Combine(env.ContentRootPath, "..", "EMR.Web"));

    public string WebRootPath => config["PatientApp:WebRootPath"] is { Length: > 0 } p ? p : Path.Combine(Web, "wwwroot");

    public string SignaturesPath => config["PatientApp:SignaturesPath"] is { Length: > 0 } p ? p : Path.Combine(Web, "App_Data", "signatures");
}
