namespace EMR.Web.Models.ViewModels;

/// <summary>Drives the shared bulk upload modal on a lab master Index page.</summary>
/// <param name="Module">API module key, e.g. "sub-category".</param>
/// <param name="Title">Display name of the master.</param>
/// <param name="DependentMasters">Masters shipped as dropdown/reference sheets in the template.</param>
public record LabBulkUploadModalModel(string Module, string Title, string DependentMasters);
