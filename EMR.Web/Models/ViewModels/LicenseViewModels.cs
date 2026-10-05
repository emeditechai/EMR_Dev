using EMR.Web.Services.Licensing;

namespace EMR.Web.Models.ViewModels;

/// <summary>License/Register: this server's hardware (read-only) and the client's details.</summary>
public sealed class LicenseRegisterViewModel
{
    public string ProductName { get; set; } = "eCare360";
    public string AppUrl { get; set; } = string.Empty;
    public string ServerName { get; set; } = string.Empty;
    public string ServerMacID { get; set; } = string.Empty;
    public string HardDiskNumber { get; set; } = string.Empty;
    public string MotherboardNumber { get; set; } = string.Empty;
    public DateTime DefaultEndDate { get; set; }
    public DateTime MaxEndDate { get; set; }
    public int OtpLength { get; set; } = 6;
    public int OtpLifetimeSeconds { get; set; } = 120;
    /// <summary>This hardware already holds a licence under another URL: show the vendor message, not the form.</summary>
    public string? MovedClientCode { get; set; }
    public string? MovedAppUrl { get; set; }
    public string? VendorContact { get; set; }
}

/// <summary>License/Blocked: why the application is blocked and what can be done.</summary>
public sealed class LicenseBlockedViewModel
{
    public string ProductName { get; set; } = "eCare360";
    public LicenseGateStatus Status { get; set; }
    public string Title { get; set; } = string.Empty;
    public string Message { get; set; } = string.Empty;
    public string? Detail { get; set; }
    public bool CanRetry { get; set; }
    public bool CanRenew { get; set; }
    public string? VendorContact { get; set; }
    public LicenseLogEntry? LastCheck { get; set; }
    public string AppUrl { get; set; } = string.Empty;
    public string ServerName { get; set; } = string.Empty;
    public int OtpLength { get; set; } = 6;
}

public sealed class LicenseOtpInput
{
    public string? Otp { get; set; }
    public string? LicenseKey { get; set; }
}

public sealed class LicenseRegisterInput
{
    public string? ClientName { get; set; }
    public string? ContactNumber { get; set; }
    public string? EmailID { get; set; }
    public DateTime? EndDate { get; set; }
    public DateTime? AmcDate { get; set; }
}
