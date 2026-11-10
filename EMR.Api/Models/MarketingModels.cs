namespace EMR.Api.Models;

/// <summary>The signed-in marketing executive: user, company and branch from the token, phone from X-Device-Id.</summary>
public sealed record MarketingCaller(int UserId, int CompanyId, int BranchId, string DeviceId);

public sealed class MarketingLeadRequest
{
    public string? NamePrefix { get; set; }
    public string? FullName { get; set; }
    public string? PhoneNumber { get; set; }
    public int? PrimarySpecialityId { get; set; }
    public string? ClinicName { get; set; }
    public string? Address { get; set; }
    public int ExpectedMonthlyReferrals { get; set; }
    public DateTime? NextFollowUpDate { get; set; }
    public string? Remarks { get; set; }
    /// <summary>On add only: the clinic pin when the executive is at the clinic.</summary>
    public decimal? Latitude { get; set; }
    public decimal? Longitude { get; set; }
}

public sealed class MarketingPinRequest
{
    public decimal? Latitude { get; set; }
    public decimal? Longitude { get; set; }
    public decimal? AccuracyM { get; set; }
    public bool IsMock { get; set; }
}

public sealed class MarketingStageRequest
{
    public string Stage { get; set; } = "";
    public string? Reason { get; set; }
}

public sealed class MarketingPromoteRequest
{
    public string? Gender { get; set; }
    public string? EmailId { get; set; }
    public int PrimarySpecialityId { get; set; }
    public string? MedicalLicenseNo { get; set; }
    public DateTime? DateOfBirth { get; set; }
}

public sealed class MarketingVisitRequest : PhleboGpsRequest
{
    public string ClientEventId { get; set; } = "";
    public string Outcome { get; set; } = "";
    public string? Notes { get; set; }
    public DateTime? NextFollowUpDate { get; set; }
}

public sealed class MarketingFieldDayRequest
{
    public string Action { get; set; } = "";
    public decimal? Latitude { get; set; }
    public decimal? Longitude { get; set; }
}
