using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class HospitalSettings
{
    public int Id { get; set; }

    public int CompanyId { get; set; } = 1;
    public int BranchId { get; set; }

    [MaxLength(200)]
    public string? HospitalName { get; set; }

    [MaxLength(100)]
    public string? HospitalType { get; set; }

    [MaxLength(100)]
    public string? RegistrationNumber { get; set; }

    [MaxLength(500)]
    public string? Address { get; set; }

    [MaxLength(20)]
    public string? ContactNumber1 { get; set; }

    [MaxLength(20)]
    public string? ContactNumber2 { get; set; }

    [MaxLength(50)]
    public string? EmergencyNumber { get; set; }

    [MaxLength(150)]
    public string? EmailAddress { get; set; }

    [MaxLength(200)]
    public string? Website { get; set; }

    [MaxLength(50)]
    public string? GSTCode { get; set; }

    [MaxLength(500)]
    public string? LogoPath { get; set; }

    // ── Accreditation & Classification ───────────────────────────────────────
    [MaxLength(100)]
    public string? NabhStatus { get; set; }

    [MaxLength(100)]
    public string? NabhCertificateNo { get; set; }

    public DateTime? NabhValidFrom { get; set; }

    public DateTime? NabhValidTo { get; set; }

    public bool IsTeachingHospital { get; set; } = false;

    public TimeSpan? CheckInTime { get; set; }

    public TimeSpan? CheckOutTime { get; set; }


    // ── OPD Module Settings ──────────────────────────────────────────────────
    public int? OpdRegistrationValidityDays { get; set; }

    public bool GlobalPatientSearchRequired { get; set; } = false;

    public bool EmailNotificationRequired { get; set; } = true;

    public bool LabEmailNotificationRequired { get; set; } = true;
    public bool IsSampleCollectionMandatory { get; set; } = true;
    public bool BarcodeGenerateAtBilling { get; set; } = false;
    /// <summary>When true a B2C Lab bill gets its Token No even while a payment is still due (default: only when fully paid).</summary>
    public bool TokenGenerateOnDuePayment { get; set; } = false;
    /// <summary>Email the finished LAB report to the patient (default No).</summary>
    public bool LabReportEmailNotificationRequired { get; set; } = false;
    /// <summary>A pathologist must approve LAB reports (default No).</summary>
    public bool PathologistApprovalRequired { get; set; } = false;
    /// <summary>Show a "Print" action against each report row in LAB listing screens (default No).</summary>
    public bool ShowLabReportPrintOnList { get; set; } = false;
    /// <summary>Critical / Panic results need a "who was informed" record before final approval (default No = approval as before). SQLScripts/2202.</summary>
    public bool CriticalValueCommunicationRequired { get; set; } = false;
    /// <summary>Critical / Panic result: target minutes from result entry to informing the doctor / patient (empty = 30). SQLScripts/2202.</summary>
    public int? CriticalValueInformMinutes { get; set; }
    /// <summary>B2C LAB bill prints the hospital letterhead (default Yes; No = blank space for pre-printed letterhead). SQLScripts/2206.</summary>
    public bool LabB2CBillPrintHeaderRequired { get; set; } = true;
    /// <summary>Printed B2C LAB report carries the hospital letterhead (default Yes; No = blank space for pre-printed letterhead). SQLScripts/2206.</summary>
    public bool LabB2CReportPrintHeaderRequired { get; set; } = true;

    public bool IsActive { get; set; } = true;

    public DateTime CreatedDate { get; set; } = DateTime.Now;
    public int? CreatedBy { get; set; }
    public DateTime? LastModifiedDate { get; set; }
    public int? LastModifiedBy { get; set; }

    public BranchMaster? Branch { get; set; }
}
