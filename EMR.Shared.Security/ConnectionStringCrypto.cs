using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Primitives;

namespace EMR.Shared.Security;

/// <summary>AES-256-GCM for connection strings in appsettings.json; encrypted values carry the "ENC:" prefix.</summary>
public static class ConnectionStringCrypto
{
    public const string Prefix = "ENC:";

    private const int NonceSize = 12;
    private const int TagSize   = 16;

    // Built-in 256-bit key: lets any deployment (cloud or on-premise) decrypt without key setup.
    // Changing it invalidates every ENC: value already issued.
    private static readonly byte[] Key =
    [
        0xcb, 0x13, 0xfb, 0x07, 0x3c, 0x9f, 0x48, 0x3d, 0x72, 0x9c, 0x0b, 0x99, 0x69, 0xf6, 0xbf, 0x37,
        0x28, 0xc8, 0x22, 0x22, 0x0b, 0xd1, 0xf4, 0xab, 0x64, 0x03, 0x34, 0x20, 0x1c, 0x2c, 0x19, 0xb8
    ];

    public static string Encrypt(string plainText)
    {
        ArgumentNullException.ThrowIfNull(plainText);

        var nonce       = RandomNumberGenerator.GetBytes(NonceSize);
        var plainBytes  = Encoding.UTF8.GetBytes(plainText);
        var cipherBytes = new byte[plainBytes.Length];
        var tag         = new byte[TagSize];

        using (var aes = new AesGcm(Key, TagSize))
            aes.Encrypt(nonce, plainBytes, cipherBytes, tag);

        // Layout: nonce(12) + tag(16) + ciphertext
        return Prefix + Convert.ToBase64String([.. nonce, .. tag, .. cipherBytes]);
    }

    public static string Decrypt(string encryptedValue)
    {
        if (!IsEncrypted(encryptedValue))
            throw new ArgumentException("Value does not start with ENC:.");

        var combined    = Convert.FromBase64String(encryptedValue[Prefix.Length..].Trim());
        if (combined.Length < NonceSize + TagSize)
            throw new ArgumentException("Encrypted value is too short.");

        var nonce       = combined[..NonceSize];
        var tag         = combined[NonceSize..(NonceSize + TagSize)];
        var cipherBytes = combined[(NonceSize + TagSize)..];
        var plainBytes  = new byte[cipherBytes.Length];

        using (var aes = new AesGcm(Key, TagSize))
            aes.Decrypt(nonce, cipherBytes, tag, plainBytes);

        return Encoding.UTF8.GetString(plainBytes);
    }

    public static bool IsEncrypted(string? value) =>
        value?.StartsWith(Prefix, StringComparison.Ordinal) == true;

    /// <summary>
    /// Replaces every ENC: value under ConnectionStrings with its plain text, so all readers get a usable string.
    /// Runs again whenever appsettings.json reloads (it is edited while the site runs), which puts the ENC: text back.
    /// </summary>
    public static void DecryptConnectionStrings(this IConfiguration configuration)
    {
        DecryptAll(configuration, throwOnError: true);
        // an exception here would surface on the file watcher thread and stop the process; a bad value fails at the next start instead
        ChangeToken.OnChange(configuration.GetReloadToken, () => DecryptAll(configuration, throwOnError: false));
    }

    private static void DecryptAll(IConfiguration configuration, bool throwOnError)
    {
        foreach (var entry in configuration.GetSection("ConnectionStrings").GetChildren())
        {
            if (!IsEncrypted(entry.Value)) continue;
            try
            {
                entry.Value = Decrypt(entry.Value!);
            }
            catch (Exception ex) when (ex is CryptographicException or FormatException or ArgumentException)
            {
                if (!throwOnError) continue;
                throw new InvalidOperationException(
                    $"ConnectionStrings:{entry.Key} could not be decrypted. Re-create it with the ConnStringEncryptor tool.", ex);
            }
        }
    }
}
