using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace EMR.Web.Services.Licensing;

/// <summary>
/// The only code that talks to the vendor's central licensing database. It runs nothing but the agreed statements
/// C1 to C11 (plus the read-only "same hardware, other URL" lookup), never DDL, and every licence lookup is filtered
/// by this application's ProductType, so eCare360 rows live beside the other products' rows in the same tables.
/// </summary>
public interface ICentralLicenseRepository
{
    Task<LicenseRecord?> FindByAppUrlAsync(string appUrl);                                         // C1
    Task<LicenseRecord?> FindByKeyAsync(string clientCode, string licenseKey);                    // C2 (+ CentralNow)
    Task<LicenseRecord?> FindByHardwareAsync(MachineFingerprint fp, string? appUrl);              // C3 (appUrl null: any URL)
    Task<LicenseRecord> InsertAsync(LicenseRecord license);                                        // C4 + C5, SERIALIZABLE
    Task TouchAsync(string clientCode, string licenseKey, string? publicIp, bool ok);              // C6
    Task<LicenseRecord?> FindByLicenseKeyAsync(string licenseKey);                                // C7
    Task UpdateHardwareAsync(string clientCode, string licenseKey, MachineFingerprint fp);        // C8
    Task LogValidationAsync(string? clientCode, string? licenseKey, bool isValid, string? reason, string? publicIp, string deviceInfo, string appUrl); // C9
    Task InsertOtpChallengeAsync(Guid challengeId, string clientName, string? contact, string? email, string otpHash,
        string? clientCode, string? licenseKey, DateTime generatedAt, DateTime expiresAt, string? requestIp);   // C10
    Task UpdateOtpChallengeAsync(Guid challengeId, bool isValidated, DateTime? validatedAt, string? failureReason,
        string? clientCode = null, string? licenseKey = null);                                     // C11
}

public sealed class CentralLicenseRepository(IOptions<LicensingOptions> options) : ICentralLicenseRepository
{
    private readonly LicensingOptions _o = options.Value;

    private const string Columns = @"
    Id, ClientCode, ISNULL(ClientName, '') AS ClientName, ContactNumber, EmailID, LicenseKey,
    ISNULL(ServerMacID, '') AS ServerMacID, ISNULL(HardDiskNumber, '') AS HardDiskNumber, ISNULL(MotherboardNumber, '') AS MotherboardNumber,
    PublicIPAddress, ISNULL(appurl, '') AS AppUrl, ISNULL(ProductType, '') AS ProductType,
    ISNULL(Startdate, CreatedAt) AS StartDate, ISNULL(ExpiryDate, CAST('19000101' AS DATETIME)) AS ExpiryDate, AMC_Expireddate AS AmcExpiredDate,
    IsActive, CAST(ISNULL(OTP_Verified, 0) AS BIT) AS OtpVerified, LastLoginDate,
    CAST(ISNULL(IsDisplayAlerts, 0) AS BIT) AS IsDisplayAlerts, AlertStartdate AS AlertStartDate, AlertStartTime,
    AlertEnddate AS AlertEndDate, AlertEndTime, AlertMessage, CreatedAt";

    private SqlConnection Open() => new(_o.CentralConnectionString);

    // C1: no local row - is this URL registered?
    public async Task<LicenseRecord?> FindByAppUrlAsync(string appUrl)
    {
        await using var cn = Open();
        return await cn.QueryFirstOrDefaultAsync<LicenseRecord>(
            $"SELECT TOP 1 {Columns} FROM dbo.ClientAppLicense WHERE appurl = @AppUrl AND ProductType = @ProductType ORDER BY CreatedAt DESC, Id DESC",
            new { AppUrl = appUrl, _o.ProductType }, commandTimeout: _o.RemoteConnectionTimeoutSeconds * 2);
    }

    // C2: the daily check, with the central server's clock
    public async Task<LicenseRecord?> FindByKeyAsync(string clientCode, string licenseKey)
    {
        await using var cn = Open();
        return await cn.QueryFirstOrDefaultAsync<LicenseRecord>(
            $"SELECT TOP 1 {Columns}, GETDATE() AS CentralNow FROM dbo.ClientAppLicense WHERE ClientCode = @ClientCode AND LicenseKey = @LicenseKey AND ProductType = @ProductType",
            new { ClientCode = clientCode, LicenseKey = licenseKey, _o.ProductType }, commandTimeout: _o.RemoteConnectionTimeoutSeconds * 2);
    }

    // C3: registration, before insert (appUrl null = the read-only "this hardware under another URL" lookup)
    public async Task<LicenseRecord?> FindByHardwareAsync(MachineFingerprint fp, string? appUrl)
    {
        await using var cn = Open();
        return await cn.QueryFirstOrDefaultAsync<LicenseRecord>(
            $@"SELECT TOP 1 {Columns} FROM dbo.ClientAppLicense
               WHERE ServerMacID = @Mac AND HardDiskNumber = @Disk AND MotherboardNumber = @Board
                 AND (@AppUrl IS NULL OR appurl = @AppUrl) AND ProductType = @ProductType
               ORDER BY CreatedAt DESC, Id DESC",
            new { Mac = fp.ServerMacID, Disk = fp.HardDiskNumber, Board = fp.MotherboardNumber, AppUrl = appUrl, _o.ProductType },
            commandTimeout: _o.RemoteConnectionTimeoutSeconds * 2);
    }

    // C4 + C5: next client code (shared with every product) and the full row, in one SERIALIZABLE transaction
    public async Task<LicenseRecord> InsertAsync(LicenseRecord l)
    {
        await using var cn = Open();
        await cn.OpenAsync();
        await using var tx = (SqlTransaction)await cn.BeginTransactionAsync(IsolationLevel.Serializable);
        // C3 again inside the transaction: two registrations racing for the same server and URL make one licence, not two
        var existing = await cn.QueryFirstOrDefaultAsync<LicenseRecord>(
            $@"SELECT TOP 1 {Columns} FROM dbo.ClientAppLicense WITH (UPDLOCK, HOLDLOCK)
               WHERE ServerMacID = @Mac AND HardDiskNumber = @Disk AND MotherboardNumber = @Board AND appurl = @AppUrl AND ProductType = @ProductType
               ORDER BY CreatedAt DESC, Id DESC",
            new { Mac = l.ServerMacID, Disk = l.HardDiskNumber, Board = l.MotherboardNumber, l.AppUrl, _o.ProductType }, tx);
        if (existing != null)
        {
            await tx.CommitAsync();
            return existing;
        }
        var now = DateTime.Now;
        var fyStart = now.Month >= 4 ? now.Year : now.Year - 1;
        var prefix = $"Cl-{fyStart % 100:D2}{(fyStart + 1) % 100:D2}";
        var last = await cn.ExecuteScalarAsync<int?>(
            "SELECT ISNULL(MAX(TRY_CAST(RIGHT(ClientCode, 4) AS INT)), 0) FROM dbo.ClientAppLicense WITH (UPDLOCK, HOLDLOCK) WHERE ClientCode LIKE @Prefix + '%'",
            new { Prefix = prefix }, tx) ?? 0;
        if (last + 1 > 9999) throw new InvalidOperationException($"Client code sequence is full for financial year {prefix[3..]}.");
        l.ClientCode = $"{prefix}{last + 1:D4}";
        l.LicenseKey = Guid.NewGuid().ToString("D").ToUpperInvariant();
        l.Id = await cn.ExecuteScalarAsync<long>(@"
INSERT INTO dbo.ClientAppLicense
    (ClientCode, ClientName, ContactNumber, LicenseKey, HardDiskNumber, ServerMacID, MotherboardNumber, Startdate, ExpiryDate,
     IsActive, CreatedAt, OTP_Verified, PublicIPAddress, LastLoginDate, EmailID, AMC_Expireddate, appurl, ProductType,
     IsDisplayAlerts, AlertStartdate, AlertStartTime, AlertEnddate, AlertEndTime, AlertMessage)
VALUES
    (@ClientCode, @ClientName, @ContactNumber, @LicenseKey, @HardDiskNumber, @ServerMacID, @MotherboardNumber, @StartDate, @ExpiryDate,
     1, @CreatedAt, 1, @PublicIPAddress, @LastLoginDate, @EmailID, @AmcExpiredDate, @AppUrl, @ProductType,
     0, NULL, NULL, NULL, NULL, NULL);
SELECT CAST(SCOPE_IDENTITY() AS BIGINT);",
            new
            {
                l.ClientCode, ClientName = Cut(l.ClientName, 100), ContactNumber = Cut(l.ContactNumber, 10), l.LicenseKey,
                l.HardDiskNumber, l.ServerMacID, l.MotherboardNumber, l.StartDate, l.ExpiryDate, l.CreatedAt,
                PublicIPAddress = Cut(l.PublicIPAddress, 60), l.LastLoginDate, EmailID = Cut(l.EmailID, 100), l.AmcExpiredDate,
                AppUrl = Cut(l.AppUrl, 500), l.ProductType
            }, tx);
        await tx.CommitAsync();
        l.IsActive = true;
        l.OtpVerified = true;
        return l;
    }

    // C6: every central check, and after registration or renewal
    public async Task TouchAsync(string clientCode, string licenseKey, string? publicIp, bool ok)
    {
        await using var cn = Open();
        await cn.ExecuteAsync(
            "UPDATE dbo.ClientAppLicense SET PublicIPAddress = @Ip, LastLoginDate = CASE WHEN @Ok = 1 THEN @Now ELSE LastLoginDate END WHERE ClientCode = @ClientCode AND LicenseKey = @LicenseKey",
            new { Ip = Cut(publicIp, 60), Ok = ok, Now = DateTime.Now, ClientCode = clientCode, LicenseKey = licenseKey });
    }

    // C7: renewal - the licence being moved to this hardware
    public async Task<LicenseRecord?> FindByLicenseKeyAsync(string licenseKey)
    {
        await using var cn = Open();
        return await cn.QueryFirstOrDefaultAsync<LicenseRecord>(
            $"SELECT TOP 1 {Columns} FROM dbo.ClientAppLicense WHERE LicenseKey = @Key AND ProductType = @ProductType",
            new { Key = licenseKey, _o.ProductType });
    }

    // C8: renewal, after the OTP
    public async Task UpdateHardwareAsync(string clientCode, string licenseKey, MachineFingerprint fp)
    {
        await using var cn = Open();
        await cn.ExecuteAsync(
            "UPDATE dbo.ClientAppLicense SET ServerMacID = @Mac, HardDiskNumber = @Disk, MotherboardNumber = @Board WHERE LicenseKey = @Key AND ClientCode = @ClientCode",
            new { Mac = fp.ServerMacID, Disk = fp.HardDiskNumber, Board = fp.MotherboardNumber, Key = licenseKey, ClientCode = clientCode });
    }

    // C9: one row per central check (the vendor's audit trail)
    public async Task LogValidationAsync(string? clientCode, string? licenseKey, bool isValid, string? reason, string? publicIp, string deviceInfo, string appUrl)
    {
        await using var cn = Open();
        await cn.ExecuteAsync(@"
INSERT INTO dbo.LicenseValidationHistory (ClientCode, LicenseKey, IsValid, FailureReason, PublicIPAddress, DeviceInfo, CreatedAt, AppUrl, ProductType)
VALUES (@ClientCode, @LicenseKey, @IsValid, @FailureReason, @Ip, @DeviceInfo, @CreatedAt, @AppUrl, @ProductType)",
            new
            {
                ClientCode = Cut(clientCode, 50), LicenseKey = Cut(licenseKey, 100), IsValid = isValid, FailureReason = Cut(reason, 200),
                Ip = Cut(publicIp, 200), DeviceInfo = Cut(deviceInfo, 2000), CreatedAt = DateTime.Now, AppUrl = Cut(appUrl, 1000), _o.ProductType
            });
    }

    // C10: OTP sent (registration and renewal alike; only the SHA-256 of the OTP is stored)
    public async Task InsertOtpChallengeAsync(Guid challengeId, string clientName, string? contact, string? email, string otpHash,
        string? clientCode, string? licenseKey, DateTime generatedAt, DateTime expiresAt, string? requestIp)
    {
        await using var cn = Open();
        await cn.ExecuteAsync(@"
INSERT INTO dbo.ClientOTPValidationHistory
    (ChallengeId, ClientName, ContactNumber, EmailID, OTPCodeHash, ClientCode, LicenseKey, IsValidated, GeneratedAt, ExpiresAt, ValidatedAt, RequestIp, FailureReason, CreatedAt)
VALUES
    (@ChallengeId, @ClientName, @ContactNumber, @EmailID, @OTPCodeHash, @ClientCode, @LicenseKey, 0, @GeneratedAt, @ExpiresAt, NULL, @RequestIp, NULL, @GeneratedAt)",
            new
            {
                ChallengeId = challengeId, ClientName = Cut(clientName, 200), ContactNumber = Cut(contact, 30),
                EmailID = Cut(email ?? string.Empty, 200),           // never NULL
                OTPCodeHash = otpHash, ClientCode = clientCode, LicenseKey = licenseKey,
                GeneratedAt = generatedAt, ExpiresAt = expiresAt, RequestIp = Cut(requestIp, 60)
            });
    }

    // C11: OTP verified, failed, expired, or the registration finished
    public async Task UpdateOtpChallengeAsync(Guid challengeId, bool isValidated, DateTime? validatedAt, string? failureReason,
        string? clientCode = null, string? licenseKey = null)
    {
        await using var cn = Open();
        await cn.ExecuteAsync(@"
UPDATE dbo.ClientOTPValidationHistory
SET IsValidated = @IsValidated, ValidatedAt = @ValidatedAt, FailureReason = @FailureReason,
    ClientCode = COALESCE(@ClientCode, ClientCode), LicenseKey = COALESCE(@LicenseKey, LicenseKey)
WHERE ChallengeId = @ChallengeId",
            new { ChallengeId = challengeId, IsValidated = isValidated, ValidatedAt = validatedAt, FailureReason = Cut(failureReason, 500), ClientCode = clientCode, LicenseKey = licenseKey });
    }

    private static string? Cut(string? value, int max) => value is null ? null : value.Length <= max ? value : value[..max];
}
