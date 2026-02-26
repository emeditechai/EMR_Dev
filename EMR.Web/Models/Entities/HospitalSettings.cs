using System.ComponentModel.DataAnnotations;

namespace EMR.Web.Models.Entities;

public class HospitalSettings
{
    public int Id { get; set; }

    public int BranchId { get; set; }

    [MaxLength(200)]
    public string? HospitalName { get; set; }

    [MaxLength(500)]
    public string? Address { get; set; }

    [MaxLength(20)]
    public string? ContactNumber1 { get; set; }

    [MaxLength(20)]
    public string? ContactNumber2 { get; set; }

    [MaxLength(150)]
    public string? EmailAddress { get; set; }

    [MaxLength(200)]
    public string? Website { get; set; }

    [MaxLength(50)]
    public string? GSTCode { get; set; }

    [MaxLength(500)]
    public string? LogoPath { get; set; }

    public TimeSpan? CheckInTime { get; set; }

    public TimeSpan? CheckOutTime { get; set; }

    public bool IsActive { get; set; } = true;

    public DateTime CreatedDate { get; set; } = DateTime.UtcNow;
    public int? CreatedBy { get; set; }
    public DateTime? LastModifiedDate { get; set; }
    public int? LastModifiedBy { get; set; }

    public BranchMaster? Branch { get; set; }
}
