using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Options;

namespace EMR.Web.Services.Licensing;

/// <summary>
/// Signs the local licence row (HMAC-SHA256), encrypts its hardware columns (AES-GCM, random nonce per value) and
/// decrypts the central SMTP password (AES-CBC with the central mail key, plain text when it is not encrypted).
/// </summary>
public interface ILicenseCrypto
{
    string Sign(LicenseRecord license, string fingerprintHash);
    bool Verify(LicenseRecord license, string fingerprintHash);
    string Encrypt(string plain);
    string Decrypt(string cipher);
    string HashOtp(string otp);
}

public sealed class LicenseCrypto(IOptions<LicensingOptions> options) : ILicenseCrypto
{
    private readonly LicensingOptions _o = options.Value;

    /// <summary>ClientCode | LicenseKey | ProductType | AppUrl | FingerprintHash | ExpiryDate | IsActive | OTP_Verified | LastRemoteValidatedAt
    /// (dates to the second: SQL DATETIME keeps milliseconds only to 1/300 s)</summary>
    private static string Payload(LicenseRecord l, string fingerprintHash) => string.Join("|",
        l.ClientCode, l.LicenseKey, l.ProductType, l.AppUrl, fingerprintHash,
        l.ExpiryDate.ToString("yyyy-MM-ddTHH:mm:ss", CultureInfo.InvariantCulture),
        l.IsActive ? "1" : "0", l.OtpVerified ? "1" : "0",
        l.LastRemoteValidatedAt?.ToString("yyyy-MM-ddTHH:mm:ss", CultureInfo.InvariantCulture) ?? string.Empty);

    public string Sign(LicenseRecord license, string fingerprintHash) =>
        Convert.ToHexString(HMACSHA256.HashData(_o.LocalSigningKey, Encoding.UTF8.GetBytes(Payload(license, fingerprintHash))));

    public bool Verify(LicenseRecord license, string fingerprintHash)
    {
        if (string.IsNullOrWhiteSpace(license.LocalSignature) || _o.LocalSigningKey.Length == 0) return false;
        try
        {
            var expected = Convert.FromHexString(Sign(license, fingerprintHash));
            var actual = Convert.FromHexString(license.LocalSignature.Trim());
            return CryptographicOperations.FixedTimeEquals(expected, actual);
        }
        catch (FormatException) { return false; }
    }

    /// <summary>base64( nonce(12) | ciphertext | tag(16) )</summary>
    public string Encrypt(string plain)
    {
        var nonce = RandomNumberGenerator.GetBytes(12);
        var data = Encoding.UTF8.GetBytes(plain);
        var cipher = new byte[data.Length];
        var tag = new byte[16];
        using var gcm = new AesGcm(_o.LocalEncryptionKey, 16);
        gcm.Encrypt(nonce, data, cipher, tag);
        return Convert.ToBase64String(nonce.Concat(cipher).Concat(tag).ToArray());
    }

    public string Decrypt(string cipherText)
    {
        var all = Convert.FromBase64String(cipherText);
        if (all.Length < 28) throw new CryptographicException("Ciphertext too short.");
        var nonce = all[..12];
        var tag = all[^16..];
        var cipher = all[12..^16];
        var plain = new byte[cipher.Length];
        using var gcm = new AesGcm(_o.LocalEncryptionKey, 16);
        gcm.Decrypt(nonce, cipher, tag, plain);
        return Encoding.UTF8.GetString(plain);
    }

    public string HashOtp(string otp) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(otp)));
}
