using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public interface IPatientService
{
    /// <summary>Returns all patients for a branch (list view).</summary>
    Task<IEnumerable<PatientListItemViewModel>> GetListForBranchAsync(int? branchId);

    /// <summary>Returns a single patient entity by ID.</summary>
    Task<PatientMaster?> GetByIdAsync(int patientId);

    /// <summary>Quick search by phone number – returns matching patients for popup.</summary>
    Task<IEnumerable<PatientQuickSearchResult>> SearchByPhoneAsync(string phone);

    /// <summary>Quick search by patient code.</summary>
    Task<IEnumerable<PatientQuickSearchResult>> SearchByCodeAsync(string code);

    /// <summary>Creates a new patient + first OPD service visit. Returns the generated PatientCode.</summary>
    Task<string> CreateAsync(PatientMaster patient, PatientOPDService opdService, int? userId);

    /// <summary>Updates patient demographics; upserts the OPD service row (insert if OPDServiceId == 0, else update).</summary>
    Task UpdateAsync(PatientMaster patient, PatientOPDService opdService, int? userId);

    /// <summary>Updates ONLY patient demographics (Sections 1 &amp; 2). No OPD service row is touched.</summary>
    Task UpdateDemographicsAsync(PatientMaster patient, int? userId);

    /// <summary>Soft-deletes a patient.</summary>
    Task DeleteAsync(int patientId, int? userId);

    /// <summary>Returns the most recent PatientOPDService row for a patient, or null.</summary>
    Task<PatientOPDService?> GetLatestOPDServiceAsync(int patientId);

    /// <summary>Returns OPD doctors (Doctor with at least one OPD department).</summary>
    Task<IEnumerable<(int DoctorId, string FullName)>> GetOpdDoctorsAsync(int? branchId);

    /// <summary>Returns services filtered by type ('Consulting' or 'Services').</summary>
    Task<IEnumerable<(int ServiceId, string ItemName, decimal ItemCharges)>> GetServicesByTypeAsync(string serviceType, int? branchId);
}
