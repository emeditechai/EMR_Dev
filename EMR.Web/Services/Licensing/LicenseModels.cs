namespace EMR.Web.Services.Licensing;

/// <summary>The outcome of the licence gate. Only <see cref="Valid"/> lets a request through.</summary>
public enum LicenseGateStatus
{
    Valid,
    Unregistered,
    PendingActivation,
    Inactive,
    Expired,
    DataMismatch,
    HardwareMismatch,
    RemoteNotFound,
    RemoteUnavailable,
    ConfigurationMissing,
    UnknownError
}

public sealed class LicenseGateResult
{
    public LicenseGateStatus Status { get; init; }
    public bool IsAllowed => Status == LicenseGateStatus.Valid;
    public string? Reason { get; init; }
    /// <summary>Valid only because the central server is unreachable and the offline grace is still running.</summary>
    public bool OfflineGrace { get; init; }
    public int OfflineGraceDaysLeft { get; init; }
    /// <summary>Unregistered, but this hardware already holds a licence under another URL.</summary>
    public string? MovedClientCode { get; init; }
    public string? MovedAppUrl { get; init; }

    public static LicenseGateResult Of(LicenseGateStatus status, string? reason = null) => new() { Status = status, Reason = reason };
}

/// <summary>A licence row as it is in the central ClientAppLicense table (and mirrored locally, hardware decrypted).</summary>
public sealed class LicenseRecord
{
    public long Id { get; set; }
    public string ClientCode { get; set; } = string.Empty;
    public string ClientName { get; set; } = string.Empty;
    public string? ContactNumber { get; set; }
    public string? EmailID { get; set; }
    public string LicenseKey { get; set; } = string.Empty;
    public string ServerMacID { get; set; } = string.Empty;
    public string HardDiskNumber { get; set; } = string.Empty;
    public string MotherboardNumber { get; set; } = string.Empty;
    public string? PublicIPAddress { get; set; }
    public string AppUrl { get; set; } = string.Empty;
    public string ProductType { get; set; } = string.Empty;
    public DateTime StartDate { get; set; }
    public DateTime ExpiryDate { get; set; }
    public DateTime? AmcExpiredDate { get; set; }
    public bool IsActive { get; set; }
    public bool OtpVerified { get; set; }
    public DateTime? LastLoginDate { get; set; }
    public bool IsDisplayAlerts { get; set; }
    public DateTime? AlertStartDate { get; set; }
    public TimeSpan? AlertStartTime { get; set; }
    public DateTime? AlertEndDate { get; set; }
    public TimeSpan? AlertEndTime { get; set; }
    public string? AlertMessage { get; set; }
    public DateTime CreatedAt { get; set; }

    // central only (C2): the central server's clock
    public DateTime? CentralNow { get; set; }

    // local only
    public DateTime? LastRemoteValidatedAt { get; set; }
    public string? LocalSignature { get; set; }
    public DateTime? SyncedAt { get; set; }
}

public sealed class MachineFingerprint
{
    public string ServerMacID { get; init; } = "UNAVAILABLE";
    public string HardDiskNumber { get; init; } = "UNAVAILABLE";
    public string MotherboardNumber { get; init; } = "UNAVAILABLE";
    /// <summary>SHA-256 (hex, upper case) of MAC|DISK|BOARD: finds the local row without decrypting every row.</summary>
    public string Hash { get; init; } = string.Empty;
    public DateTime CapturedAt { get; init; }

    public bool Matches(LicenseRecord license) =>
        string.Equals(ServerMacID, MachineFingerprintProvider.Normalize(license.ServerMacID), StringComparison.Ordinal)
        && string.Equals(HardDiskNumber, MachineFingerprintProvider.Normalize(license.HardDiskNumber), StringComparison.Ordinal)
        && string.Equals(MotherboardNumber, MachineFingerprintProvider.Normalize(license.MotherboardNumber), StringComparison.Ordinal);

    public string Describe(LicenseRecord license)
    {
        var parts = new List<string>();
        if (!string.Equals(ServerMacID, MachineFingerprintProvider.Normalize(license.ServerMacID), StringComparison.Ordinal)) parts.Add("MAC address");
        if (!string.Equals(HardDiskNumber, MachineFingerprintProvider.Normalize(license.HardDiskNumber), StringComparison.Ordinal)) parts.Add("hard disk");
        if (!string.Equals(MotherboardNumber, MachineFingerprintProvider.Normalize(license.MotherboardNumber), StringComparison.Ordinal)) parts.Add("motherboard");
        return parts.Count == 0 ? "Hardware matches." : "Different " + string.Join(", ", parts) + " from the registered server.";
    }

    public string DeviceInfo() =>
        $"Host={Environment.MachineName};OS={(OperatingSystem.IsWindows() ? "Windows" : OperatingSystem.IsMacOS() ? "macOS" : OperatingSystem.IsLinux() ? "Linux" : "Unknown")};"
        + $"MAC={ServerMacID};HardDisk={HardDiskNumber};Motherboard={MotherboardNumber}";
}

/// <summary>A message shown at the top of every page while it applies.</summary>
public sealed record LicenseBanner(string Kind, string Message);

/// <summary>What the Settings > Licence page shows about this installation.</summary>
public sealed class LicenseOverview
{
    public bool Enabled { get; init; }
    public LicenseGateStatus Status { get; init; }
    public string? Reason { get; init; }
    public LicenseRecord? License { get; init; }
    public bool SignatureTrusted { get; init; }
    public MachineFingerprint Machine { get; init; } = new();
    public string AppUrl { get; init; } = string.Empty;
    public string ProductType { get; init; } = string.Empty;
    public IReadOnlyList<LicenseLogEntry> RecentChecks { get; init; } = Array.Empty<LicenseLogEntry>();
}

public sealed record LicenseLogEntry(DateTime ValidatedAt, string Result, bool IsRemoteReachable, bool IsOfflineGrace, string? FailureReason, string? RequestIp);
