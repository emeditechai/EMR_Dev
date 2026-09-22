namespace EMR.Web.Models.DTOs;

/// <summary>One approval level already signed for a bill - printed as a signature block on the report.</summary>
public class LabReportSignoffLevelDto
{
    public int LevelNo { get; set; }
    public int TotalLevels { get; set; }
    public string? LevelTitle { get; set; }
    public bool IsFinalLevel { get; set; }
    public int UserId { get; set; }
    public string? FullName { get; set; }
    public string? RegistrationNo { get; set; }
    public string? SignaturePath { get; set; }
    public bool IsPathologist { get; set; }
    /// <summary>Null for a signatory configured in Hospital Settings (nothing was signed).</summary>
    public DateTime? SignedOn { get; set; }
    public int TestsSigned { get; set; }
    /// <summary>FLOW (Pathologist Dashboard), ENTRY (Report Entry screen) or CONFIG (Hospital Settings signatories).</summary>
    public string? Source { get; set; }
}
