using Dapper;
using Microsoft.Data.SqlClient;

namespace EMR.Web.Services.Licensing;

/// <summary>
/// This installation's copy of its licence in the application database (SQLScripts/2216). Hardware columns are
/// stored AES-GCM encrypted with FingerprintHash beside them for lookup; every write re-signs the row (HMAC), and a
/// row whose signature does not verify is "not trusted": it never blocks by itself, it only forces a central check.
/// </summary>
public interface ILocalLicenseRepository
{
    Task EnsureSchemaAsync();
    Task<bool> ExistsAsync(string fingerprintHash, string appUrl);
    Task<(LicenseRecord? License, bool Trusted)> FindAsync(string fingerprintHash, string appUrl);
    Task<(LicenseRecord? License, bool Trusted)> FindLatestAsync(string appUrl);
    Task UpsertAsync(LicenseRecord license);
    Task<int> DeleteAsync(string fingerprintHash, string appUrl);
    Task LogAsync(LicenseRecord? license, string? fingerprintHash, LicenseGateStatus result, bool isMatch, bool isExpired,
        bool remoteReachable, bool offlineGrace, string? reason, string? requestIp, string appUrl);
    Task<IReadOnlyList<LicenseLogEntry>> RecentLogsAsync(int count);
}

public sealed class LocalLicenseRepository(IConfiguration configuration, ILicenseCrypto crypto, ILogger<LocalLicenseRepository> logger) : ILocalLicenseRepository
{
    private readonly string _cs = configuration.GetConnectionString("DefaultConnection")
        ?? throw new InvalidOperationException("ConnectionStrings:DefaultConnection is not set.");

    private SqlConnection Open() => new(_cs);

    public async Task EnsureSchemaAsync()
    {
        await using var cn = Open();
        await cn.ExecuteAsync(@"
IF OBJECT_ID('dbo.ClientAppLicense', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ClientAppLicense (
        Id BIGINT IDENTITY(1,1) PRIMARY KEY, ClientCode VARCHAR(32) NOT NULL, ClientName NVARCHAR(200) NOT NULL,
        ContactNumber VARCHAR(30) NULL, EmailID NVARCHAR(200) NULL, LicenseKey NVARCHAR(100) NOT NULL,
        ServerMacID NVARCHAR(512) NOT NULL, HardDiskNumber NVARCHAR(512) NOT NULL, MotherboardNumber NVARCHAR(512) NOT NULL,
        FingerprintHash CHAR(64) NOT NULL, PublicIPAddress VARCHAR(60) NULL, AppUrl NVARCHAR(500) NOT NULL, ProductType NVARCHAR(100) NOT NULL,
        StartDate DATETIME NOT NULL, ExpiryDate DATETIME NOT NULL, AMC_Expireddate DATETIME NULL, IsActive BIT NOT NULL, OTP_Verified BIT NOT NULL,
        LastLoginDate DATETIME NULL, IsDisplayAlerts BIT NOT NULL CONSTRAINT DF_ClientAppLicense_IsDisplayAlerts DEFAULT 0,
        AlertStartdate DATE NULL, AlertStartTime TIME(0) NULL, AlertEnddate DATE NULL, AlertEndTime TIME(0) NULL, AlertMessage NVARCHAR(MAX) NULL,
        CreatedAt DATETIME NOT NULL, LastRemoteValidatedAt DATETIME NULL, LocalSignature CHAR(64) NULL,
        SyncedAt DATETIME NOT NULL CONSTRAINT DF_ClientAppLicense_SyncedAt DEFAULT GETDATE());
    CREATE UNIQUE INDEX UX_Local_ClientCode ON dbo.ClientAppLicense(ClientCode);
    CREATE UNIQUE INDEX UX_Local_LicenseKey ON dbo.ClientAppLicense(LicenseKey);
    CREATE INDEX IX_Local_Fingerprint_Url ON dbo.ClientAppLicense(FingerprintHash, AppUrl);
END
IF OBJECT_ID('dbo.ClientAppLicenseValidationLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ClientAppLicenseValidationLog (
        Id BIGINT IDENTITY(1,1) PRIMARY KEY, ClientCode VARCHAR(32) NULL, LicenseKey NVARCHAR(100) NULL, ValidatedAt DATETIME NOT NULL,
        FingerprintHash CHAR(64) NULL, IsMatch BIT NOT NULL, IsExpired BIT NOT NULL, IsRemoteReachable BIT NOT NULL,
        IsOfflineGrace BIT NOT NULL CONSTRAINT DF_ClientAppLicenseValidationLog_Grace DEFAULT 0, Result VARCHAR(40) NOT NULL,
        FailureReason NVARCHAR(500) NULL, RequestIp VARCHAR(60) NULL, AppUrl NVARCHAR(500) NULL,
        CreatedAt DATETIME NOT NULL CONSTRAINT DF_ClientAppLicenseValidationLog_CreatedAt DEFAULT GETDATE());
    CREATE INDEX IX_LocalLog_ClientCode_ValidatedAt ON dbo.ClientAppLicenseValidationLog(ClientCode, ValidatedAt DESC);
END");
    }

    private const string Select = @"
SELECT TOP 1 Id, ClientCode, ClientName, ContactNumber, EmailID, LicenseKey, ServerMacID, HardDiskNumber, MotherboardNumber,
       FingerprintHash, PublicIPAddress, AppUrl, ProductType, StartDate, ExpiryDate, AMC_Expireddate AS AmcExpiredDate,
       IsActive, OTP_Verified AS OtpVerified, LastLoginDate, IsDisplayAlerts, AlertStartdate AS AlertStartDate, AlertStartTime,
       AlertEnddate AS AlertEndDate, AlertEndTime, AlertMessage, CreatedAt, LastRemoteValidatedAt, LocalSignature, SyncedAt
FROM dbo.ClientAppLicense";

    public async Task<bool> ExistsAsync(string fingerprintHash, string appUrl)
    {
        await using var cn = Open();
        return await cn.ExecuteScalarAsync<int>(
            "SELECT COUNT(1) FROM dbo.ClientAppLicense WHERE FingerprintHash = @H AND AppUrl = @U", new { H = fingerprintHash, U = appUrl }) > 0;
    }

    public Task<(LicenseRecord? License, bool Trusted)> FindAsync(string fingerprintHash, string appUrl) =>
        ReadAsync(Select + " WHERE FingerprintHash = @H AND AppUrl = @U ORDER BY Id DESC", new { H = fingerprintHash, U = appUrl });

    public Task<(LicenseRecord? License, bool Trusted)> FindLatestAsync(string appUrl) =>
        ReadAsync(Select + " WHERE AppUrl = @U ORDER BY SyncedAt DESC, Id DESC", new { U = appUrl });

    private async Task<(LicenseRecord?, bool)> ReadAsync(string sql, object args)
    {
        await using var cn = Open();
        var row = await cn.QueryFirstOrDefaultAsync(sql, args);
        if (row is null) return (null, false);
        var d = (IDictionary<string, object?>)row;
        var l = new LicenseRecord
        {
            Id = (long)d["Id"]!, ClientCode = (string)d["ClientCode"]!, ClientName = (string)d["ClientName"]!,
            ContactNumber = d["ContactNumber"] as string, EmailID = d["EmailID"] as string, LicenseKey = (string)d["LicenseKey"]!,
            PublicIPAddress = d["PublicIPAddress"] as string, AppUrl = (string)d["AppUrl"]!, ProductType = (string)d["ProductType"]!,
            StartDate = (DateTime)d["StartDate"]!, ExpiryDate = (DateTime)d["ExpiryDate"]!, AmcExpiredDate = d["AmcExpiredDate"] as DateTime?,
            IsActive = (bool)d["IsActive"]!, OtpVerified = (bool)d["OtpVerified"]!, LastLoginDate = d["LastLoginDate"] as DateTime?,
            IsDisplayAlerts = (bool)d["IsDisplayAlerts"]!, AlertStartDate = d["AlertStartDate"] as DateTime?, AlertStartTime = d["AlertStartTime"] as TimeSpan?,
            AlertEndDate = d["AlertEndDate"] as DateTime?, AlertEndTime = d["AlertEndTime"] as TimeSpan?, AlertMessage = d["AlertMessage"] as string,
            CreatedAt = (DateTime)d["CreatedAt"]!, LastRemoteValidatedAt = d["LastRemoteValidatedAt"] as DateTime?,
            LocalSignature = (d["LocalSignature"] as string)?.Trim(), SyncedAt = d["SyncedAt"] as DateTime?
        };
        var hash = ((string)d["FingerprintHash"]!).Trim();
        try
        {
            l.ServerMacID = crypto.Decrypt((string)d["ServerMacID"]!);
            l.HardDiskNumber = crypto.Decrypt((string)d["HardDiskNumber"]!);
            l.MotherboardNumber = crypto.Decrypt((string)d["MotherboardNumber"]!);
        }
        catch (Exception ex)
        {
            // encrypted with another key, or edited by hand: the row is not trusted, so the central check decides
            logger.LogWarning(ex, "Local licence {ClientCode}: hardware columns could not be decrypted.", l.ClientCode);
            return (l, false);
        }
        var trusted = string.Equals(hash, MachineFingerprintProvider.HashOf(l.ServerMacID, l.HardDiskNumber, l.MotherboardNumber), StringComparison.OrdinalIgnoreCase)
                      && crypto.Verify(l, hash);
        return (l, trusted);
    }

    /// <summary>Removes this machine's copy for the URL (Re-validate); it is rebuilt from the licence server. Logs are kept.</summary>
    public async Task<int> DeleteAsync(string fingerprintHash, string appUrl)
    {
        await using var cn = Open();
        return await cn.ExecuteAsync("DELETE FROM dbo.ClientAppLicense WHERE FingerprintHash = @H AND AppUrl = @U", new { H = fingerprintHash, U = appUrl });
    }

    public async Task UpsertAsync(LicenseRecord l)
    {
        var mac = MachineFingerprintProvider.Normalize(l.ServerMacID);
        var disk = MachineFingerprintProvider.Normalize(l.HardDiskNumber);
        var board = MachineFingerprintProvider.Normalize(l.MotherboardNumber);
        var hash = MachineFingerprintProvider.HashOf(mac, disk, board);
        var signature = crypto.Sign(l, hash);
        await using var cn = Open();
        await cn.ExecuteAsync(@"
MERGE dbo.ClientAppLicense WITH (HOLDLOCK) AS t
USING (SELECT @ClientCode AS ClientCode) AS s ON t.ClientCode = s.ClientCode
WHEN MATCHED THEN UPDATE SET
    ClientName = @ClientName, ContactNumber = @ContactNumber, EmailID = @EmailID, LicenseKey = @LicenseKey,
    ServerMacID = @Mac, HardDiskNumber = @Disk, MotherboardNumber = @Board, FingerprintHash = @Hash,
    PublicIPAddress = @PublicIPAddress, AppUrl = @AppUrl, ProductType = @ProductType, StartDate = @StartDate, ExpiryDate = @ExpiryDate,
    AMC_Expireddate = @AmcExpiredDate, IsActive = @IsActive, OTP_Verified = @OtpVerified, LastLoginDate = @LastLoginDate,
    IsDisplayAlerts = @IsDisplayAlerts, AlertStartdate = @AlertStartDate, AlertStartTime = @AlertStartTime, AlertEnddate = @AlertEndDate,
    AlertEndTime = @AlertEndTime, AlertMessage = @AlertMessage, CreatedAt = @CreatedAt,
    LastRemoteValidatedAt = @LastRemoteValidatedAt, LocalSignature = @Signature, SyncedAt = GETDATE()
WHEN NOT MATCHED THEN INSERT
    (ClientCode, ClientName, ContactNumber, EmailID, LicenseKey, ServerMacID, HardDiskNumber, MotherboardNumber, FingerprintHash,
     PublicIPAddress, AppUrl, ProductType, StartDate, ExpiryDate, AMC_Expireddate, IsActive, OTP_Verified, LastLoginDate,
     IsDisplayAlerts, AlertStartdate, AlertStartTime, AlertEnddate, AlertEndTime, AlertMessage, CreatedAt, LastRemoteValidatedAt, LocalSignature, SyncedAt)
VALUES
    (@ClientCode, @ClientName, @ContactNumber, @EmailID, @LicenseKey, @Mac, @Disk, @Board, @Hash,
     @PublicIPAddress, @AppUrl, @ProductType, @StartDate, @ExpiryDate, @AmcExpiredDate, @IsActive, @OtpVerified, @LastLoginDate,
     @IsDisplayAlerts, @AlertStartDate, @AlertStartTime, @AlertEndDate, @AlertEndTime, @AlertMessage, @CreatedAt, @LastRemoteValidatedAt, @Signature, GETDATE());",
            new
            {
                l.ClientCode, l.ClientName, l.ContactNumber, l.EmailID, l.LicenseKey,
                Mac = crypto.Encrypt(mac), Disk = crypto.Encrypt(disk), Board = crypto.Encrypt(board), Hash = hash,
                l.PublicIPAddress, l.AppUrl, l.ProductType, l.StartDate, l.ExpiryDate, l.AmcExpiredDate, l.IsActive, l.OtpVerified, l.LastLoginDate,
                l.IsDisplayAlerts, AlertStartDate = l.AlertStartDate?.Date, l.AlertStartTime, AlertEndDate = l.AlertEndDate?.Date, l.AlertEndTime, l.AlertMessage,
                l.CreatedAt, l.LastRemoteValidatedAt, Signature = signature
            });
        l.LocalSignature = signature;
    }

    public async Task LogAsync(LicenseRecord? license, string? fingerprintHash, LicenseGateStatus result, bool isMatch, bool isExpired,
        bool remoteReachable, bool offlineGrace, string? reason, string? requestIp, string appUrl)
    {
        try
        {
            await using var cn = Open();
            await cn.ExecuteAsync(@"
INSERT INTO dbo.ClientAppLicenseValidationLog
    (ClientCode, LicenseKey, ValidatedAt, FingerprintHash, IsMatch, IsExpired, IsRemoteReachable, IsOfflineGrace, Result, FailureReason, RequestIp, AppUrl)
VALUES (@ClientCode, @LicenseKey, GETDATE(), @Hash, @IsMatch, @IsExpired, @Remote, @Grace, @Result, @Reason, @Ip, @AppUrl)",
                new
                {
                    license?.ClientCode, license?.LicenseKey, Hash = fingerprintHash, IsMatch = isMatch, IsExpired = isExpired, Remote = remoteReachable,
                    Grace = offlineGrace, Result = result.ToString(), Reason = reason is { Length: > 500 } ? reason[..500] : reason,
                    Ip = requestIp is { Length: > 60 } ? requestIp[..60] : requestIp, AppUrl = appUrl
                });
        }
        catch (Exception ex) { logger.LogWarning(ex, "Licence evaluation could not be logged locally."); }
    }

    public async Task<IReadOnlyList<LicenseLogEntry>> RecentLogsAsync(int count)
    {
        await using var cn = Open();
        return (await cn.QueryAsync<LicenseLogEntry>(
            "SELECT TOP (@N) ValidatedAt, Result, IsRemoteReachable, IsOfflineGrace, FailureReason, RequestIp FROM dbo.ClientAppLicenseValidationLog ORDER BY Id DESC",
            new { N = count })).ToList();
    }
}
