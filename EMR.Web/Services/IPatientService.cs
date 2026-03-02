using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public interface IPatientService
{
    /// <summary>Returns all patients for a branch (list view).</summary>
    Task<IEnumerable<PatientListItemViewModel>> GetListForBranchAsync(int? branchId);

    /// <summary>Server-side paged patient list via usp_GetPatientListPaged.</summary>
    Task<PatientPagedListViewModel> GetPagedListAsync(int? branchId, int page, int pageSize, string? search);

    /// <summary>Returns a single patient entity by ID.</summary>
    Task<PatientMaster?> GetByIdAsync(int patientId);

    /// <summary>Quick search by phone number – returns matching patients for popup.</summary>
    Task<IEnumerable<PatientQuickSearchResult>> SearchByPhoneAsync(string phone, int? branchId = null);

    /// <summary>Quick search by patient code.</summary>
    Task<IEnumerable<PatientQuickSearchResult>> SearchByCodeAsync(string code, int? branchId = null);

    /// <summary>
    /// Creates a new patient + OPD bill with line items.
    /// Returns (PatientCode, OPDBillNo, TokenNo, NewPatientId, NewOPDServiceId).
    /// </summary>
    Task<(string PatientCode, string OPDBillNo, string TokenNo, int NewPatientId, int NewOPDServiceId)>
        CreateAsync(PatientMaster patient, PatientOPDService opdBill, string lineItemsJson, int? userId);

    /// <summary>
    /// Updates patient demographics; creates a new OPD bill (or updates existing) with line items.
    /// Returns (OPDBillNo, TokenNo, NewOPDServiceId).
    /// </summary>
    Task<(string OPDBillNo, string TokenNo, int NewOPDServiceId)>
        UpdateAsync(PatientMaster patient, PatientOPDService opdBill, string lineItemsJson, int? userId);

    /// <summary>Updates ONLY patient demographics (Sections 1 &amp; 2). No OPD bill row is touched.</summary>
    Task UpdateDemographicsAsync(PatientMaster patient, int? userId);

    /// <summary>Soft-deletes a patient.</summary>
    Task DeleteAsync(int patientId, int? userId);

    /// <summary>Returns the most recent PatientOPDService (bill header) for a patient, or null.</summary>
    Task<PatientOPDService?> GetLatestOPDServiceAsync(int patientId);

    /// <summary>Returns OPD doctors (Doctor with at least one OPD department).</summary>
    Task<IEnumerable<(int DoctorId, string FullName)>> GetOpdDoctorsAsync(int? branchId);

    /// <summary>Returns services filtered by type ('Consulting' or 'Service').</summary>
    Task<IEnumerable<(int ServiceId, string ItemName, decimal ItemCharges)>> GetServicesByTypeAsync(string serviceType, int? branchId);

    /// <summary>Returns paged/filtered OPD service bookings for the list page.</summary>
    Task<IEnumerable<ServiceBookingListItem>> GetServiceBookingsAsync(int? branchId, DateOnly? fromDate, DateOnly? toDate);

    /// <summary>Server-side paged service bookings via usp_GetServiceBookingsPaged.</summary>
    Task<ServiceBookingPagedListViewModel> GetServiceBookingsPagedAsync(
        int? branchId, DateOnly? fromDate, DateOnly? toDate, int page, int pageSize, string? search);

    /// <summary>Returns full detail of a single OPD bill (header + line items) for the View popup.</summary>
    Task<ServiceBookingDetailViewModel?> GetServiceBookingDetailAsync(int opdServiceId);

    /// <summary>Returns the display name for a given IdentificationTypeId, or null if not found.</summary>
    Task<string?> GetIdentificationTypeNameAsync(int identificationTypeId);

    /// <summary>
    /// Returns resolved display names for all picklist-ID fields on a patient
    /// (Religion, MaritalStatus, Occupation, Area, City, District, State, Country).
    /// </summary>
    Task<(string? ReligionName, string? MaritalStatusName, string? OccupationName,
          string? AreaName, string? CityName, string? DistrictName, string? StateName, string? CountryName)>
        GetDemographicNamesAsync(int patientId);

    /// <summary>
    /// Creates a new OPD bill + line items for an existing patient WITHOUT touching any patient demographic fields.
    /// Use this from NewServiceBooking so that patient data is never overwritten from the booking screen.
    /// </summary>
    Task<(string OPDBillNo, string TokenNo, int NewOPDServiceId)>
        CreateServiceBookingOnlyAsync(PatientOPDService bill, string lineItemsJson, int? userId);
}
