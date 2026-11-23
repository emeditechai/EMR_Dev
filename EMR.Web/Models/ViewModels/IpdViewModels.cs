namespace EMR.Web.Models.ViewModels;

/// <summary>IPD > New Admission (SQLScripts/2422-2424): the patient (Patient Master, as OPD / LAB) and the admission.</summary>
public class IpdAdmissionForm
{
    public Guid? RequestKey { get; set; }

    // ── patient (same fields as OPD / LAB registration) ──
    public int PatientId { get; set; }
    public string? PatientCode { get; set; }
    public string? Salutation { get; set; }
    public string? FirstName { get; set; }
    public string? MiddleName { get; set; }
    public string? LastName { get; set; }
    public string? PhoneNumber { get; set; }
    public string? SecondaryPhoneNumber { get; set; }
    public string? EmailId { get; set; }
    public string? Gender { get; set; }
    public DateTime? DateOfBirth { get; set; }
    public int? AgeYears { get; set; }
    public int? AgeMonths { get; set; }
    public int? AgeDays { get; set; }
    public int? RelationId { get; set; }
    public int? ReligionId { get; set; }
    public string? BloodGroup { get; set; }
    public string? GuardianName { get; set; }
    public int? CountryId { get; set; }
    public int? StateId { get; set; }
    public int? DistrictId { get; set; }
    public int? CityId { get; set; }
    public int? AreaId { get; set; }
    public string? Address { get; set; }
    public string? Pincode { get; set; }
    public int? IdentificationTypeId { get; set; }
    public string? IdentificationNumber { get; set; }
    public string? IdentificationFilePath { get; set; }
    public string? PhotoPath { get; set; }
    public string? AbhaNumber { get; set; }
    public string? AbhaAddress { get; set; }
    public int? OccupationId { get; set; }
    public int? MaritalStatusId { get; set; }
    public int? LanguageId { get; set; }
    public string? KnownAllergies { get; set; }
    public string? PatientRemarks { get; set; }

    // ── admission ──
    public DateTime? AdmissionAt { get; set; }
    public string AdmissionType { get; set; } = "ELECTIVE";
    public string AdmissionSource { get; set; } = "DIRECT";
    public int? OpdServiceId { get; set; }
    public int? ReferralDoctorId { get; set; }
    public int AdmittingDoctorId { get; set; }
    public int ConsultantDoctorId { get; set; }
    public int? DepartmentId { get; set; }
    public string? ProvisionalDiagnosis { get; set; }
    public string? DiagnosisCode { get; set; }
    public string? ReasonForAdmission { get; set; }
    public DateTime? ExpectedDischargeAt { get; set; }
    public int BedId { get; set; }
    public int TariffCategoryId { get; set; }
    public string PayerType { get; set; } = "CASH";
    public int? PackageId { get; set; }
    public int? EstimateId { get; set; }
    public string? Remarks { get; set; }
    public string? PayersJson { get; set; }
    public string? AttendantsJson { get; set; }
    public bool IsMlc { get; set; }
    public string? MlcJson { get; set; }
    public string? PaymentsJson { get; set; }
    public string? AdvanceWaiveReason { get; set; }

    // ── consent ──
    public int? ConsentId { get; set; }
    public string? ConsentSignedByName { get; set; }
    public string? ConsentSignedByRelation { get; set; }
    public string? ConsentWitnessName { get; set; }
    /// <summary>Signature drawn on the pad (data:image/png;base64,...).</summary>
    public string? ConsentSignature { get; set; }
    public string? WitnessSignature { get; set; }
}
