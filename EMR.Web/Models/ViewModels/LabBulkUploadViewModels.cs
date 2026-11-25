namespace EMR.Web.Models.ViewModels;

/// <summary>Drives the shared Excel bulk upload modal (lab masters, Doctor Master).</summary>
/// <param name="Module">API module key, e.g. "sub-category".</param>
/// <param name="Title">Display name of the master.</param>
/// <param name="DependentMasters">Masters shipped as dropdown/reference sheets in the template.</param>
/// <param name="Controller">Web controller with the Template / Import actions.</param>
/// <param name="Permission">asp-permission of the template links; null = the lab master IMPORT controls.</param>
/// <param name="ElementId">Modal element id, so a page can hold more than one modal.</param>
/// <param name="KeyColumn">Name of the column that identifies an existing record.</param>
public record LabBulkUploadModalModel(
    string Module, string Title, string DependentMasters,
    string Controller = "LabBulkUpload",
    string? Permission = null,
    string ElementId = "labBulkUploadModal",
    string KeyColumn = "Code")
{
    public const string LabImportPermissions =
        "MASTER.LABFRANCHISES:IMPORT,MASTER.LABINVESTIGATIONPROFILES:IMPORT,MASTER.LABINVESTIGATIONS:IMPORT,MASTER.LABRATELISTB2C:IMPORT," +
        "MASTER.LABRATELISTFRANCHISE:IMPORT,MASTER.LABRATELISTCORPORATE:IMPORT,MASTER.LABTESTMETHODS:IMPORT,MASTER.LABTESTSUBCATEGORIES:IMPORT";

    public string TemplatePermission => Permission ?? LabImportPermissions;
}
