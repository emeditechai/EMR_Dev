using System.Security.Cryptography;
using System.Text;
using System.Web;
using Microsoft.Extensions.Configuration;

namespace EMR.Web.Services;

public interface IQueryStringEncryptionService
{
    string Encrypt(string plainText);
    string Decrypt(string cipherText);
    string EncryptParameters(IDictionary<string, string?> parameters);
    IDictionary<string, string> DecryptToDictionary(string encryptedQueryString);
}

public class QueryStringEncryptionService : IQueryStringEncryptionService
{
    private readonly byte[] _key;

    // Standard 256-bit Default Encryption Key if none is provided in appsettings.json
    private const string Default256BitKey = "EMR_Dev_System_QueryString_SecretKey_2026_AES256Bit_Key!";

    public QueryStringEncryptionService(IConfiguration configuration)
    {
        var secretKey = configuration["QueryStringEncryption:Key"] ?? Default256BitKey;
        using var sha = SHA256.Create();
        _key = sha.ComputeHash(Encoding.UTF8.GetBytes(secretKey)); // Guaranteed 256-bit (32 bytes)
    }

    public string Encrypt(string plainText)
    {
        if (string.IsNullOrEmpty(plainText))
            return string.Empty;

        using var aes = Aes.Create();
        aes.Key = _key;
        aes.GenerateIV(); // 128-bit IV

        using var encryptor = aes.CreateEncryptor(aes.Key, aes.IV);
        byte[] plainBytes = Encoding.UTF8.GetBytes(plainText);
        byte[] cipherBytes = encryptor.TransformFinalBlock(plainBytes, 0, plainBytes.Length);

        // Prepend IV to ciphertext (16 bytes IV + cipherBytes)
        byte[] result = new byte[aes.IV.Length + cipherBytes.Length];
        Buffer.BlockCopy(aes.IV, 0, result, 0, aes.IV.Length);
        Buffer.BlockCopy(cipherBytes, 0, result, aes.IV.Length, cipherBytes.Length);

        // Convert to Base64Url string (URL safe)
        return Base64UrlEncode(result);
    }

    public string Decrypt(string cipherText)
    {
        if (string.IsNullOrEmpty(cipherText))
            return string.Empty;

        try
        {
            byte[] fullBytes = Base64UrlDecode(cipherText);
            if (fullBytes.Length < 16)
                return string.Empty;

            byte[] iv = new byte[16];
            byte[] cipherBytes = new byte[fullBytes.Length - 16];

            Buffer.BlockCopy(fullBytes, 0, iv, 0, 16);
            Buffer.BlockCopy(fullBytes, 16, cipherBytes, 0, cipherBytes.Length);

            using var aes = Aes.Create();
            aes.Key = _key;
            aes.IV = iv;

            using var decryptor = aes.CreateDecryptor(aes.Key, aes.IV);
            byte[] plainBytes = decryptor.TransformFinalBlock(cipherBytes, 0, cipherBytes.Length);

            return Encoding.UTF8.GetString(plainBytes);
        }
        catch
        {
            return string.Empty;
        }
    }

    public string EncryptParameters(IDictionary<string, string?> parameters)
    {
        if (parameters == null || parameters.Count == 0)
            return string.Empty;

        var nvc = HttpUtility.ParseQueryString(string.Empty);
        foreach (var kvp in parameters)
        {
            if (kvp.Value != null)
            {
                nvc[kvp.Key] = kvp.Value;
            }
        }

        string rawQuery = nvc.ToString() ?? string.Empty;
        return Encrypt(rawQuery);
    }

    public IDictionary<string, string> DecryptToDictionary(string encryptedQueryString)
    {
        var dict = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string decryptedRaw = Decrypt(encryptedQueryString);
        if (string.IsNullOrEmpty(decryptedRaw))
            return dict;

        var nvc = HttpUtility.ParseQueryString(decryptedRaw);
        foreach (string? key in nvc.AllKeys)
        {
            if (!string.IsNullOrEmpty(key))
            {
                dict[key] = nvc[key] ?? string.Empty;
            }
        }

        return dict;
    }

    private static string Base64UrlEncode(byte[] input)
    {
        string base64 = Convert.ToBase64String(input);
        return base64.Replace('+', '-').Replace('/', '_').TrimEnd('=');
    }

    private static byte[] Base64UrlDecode(string input)
    {
        string base64 = input.Replace('-', '+').Replace('_', '/');
        switch (base64.Length % 4)
        {
            case 2: base64 += "=="; break;
            case 3: base64 += "="; break;
        }
        return Convert.FromBase64String(base64);
    }
}
