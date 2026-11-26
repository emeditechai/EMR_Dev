namespace EMR.Web.Services;

/// <summary>
/// Doctor Master signature images (SQLScripts/2559): kept in App_Data/doctor-signatures, never web-served directly (read through
/// Doctors/Signature and IpdDischarge/DoctorSignature). Separate from the pathologist signatures of User Master (App_Data/signatures).
/// </summary>
public static class DoctorSignatureStore
{
    public const long MaxBytes = 2 * 1024 * 1024;

    private static string Root(IWebHostEnvironment env) => Path.Combine(env.ContentRootPath, "App_Data", "doctor-signatures");

    /// <summary>Only the file-name part is used, so a tampered value cannot leave the folder.</summary>
    public static string FullPath(IWebHostEnvironment env, string storedName) => Path.Combine(Root(env), Path.GetFileName(storedName));

    /// <summary>"png" / "jpg" from the file's first bytes, else null.</summary>
    private static async Task<string?> DetectAsync(IFormFile file)
    {
        var header = new byte[8];
        await using var s = file.OpenReadStream();
        var read = await s.ReadAsync(header.AsMemory(0, header.Length));
        if (read >= 8 && header[0] == 0x89 && header[1] == 0x50 && header[2] == 0x4E && header[3] == 0x47) return "png";
        if (read >= 3 && header[0] == 0xFF && header[1] == 0xD8 && header[2] == 0xFF) return "jpg";
        return null;
    }

    /// <summary>Checks and saves an upload; returns (stored name, null) or (null, error).</summary>
    public static async Task<(string? Name, string? Error)> SaveAsync(IWebHostEnvironment env, IFormFile? file)
    {
        if (file is null || file.Length == 0) return (null, "Choose the signature image.");
        var ext = Path.GetExtension(file.FileName).ToLowerInvariant();
        if (ext is not (".png" or ".jpg" or ".jpeg")) return (null, "The signature must be a .png, .jpg or .jpeg file.");
        if (file.Length > MaxBytes) return (null, "The signature image must be up to 2 MB.");
        var type = await DetectAsync(file);
        if (type is null) return (null, "The selected file is not a valid PNG or JPEG image.");
        Directory.CreateDirectory(Root(env));
        var name = $"docsig_{Guid.NewGuid():N}.{type}";
        await using (var stream = new FileStream(FullPath(env, name), FileMode.CreateNew)) await file.CopyToAsync(stream);
        return (name, null);
    }

    public static void Delete(IWebHostEnvironment env, string? storedName)
    {
        if (string.IsNullOrWhiteSpace(storedName)) return;
        try { var f = FullPath(env, storedName); if (File.Exists(f)) File.Delete(f); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    /// <summary>The image as a file result, or null when there is none.</summary>
    public static (string Path, string ContentType)? Find(IWebHostEnvironment env, string? storedName)
    {
        if (string.IsNullOrWhiteSpace(storedName)) return null;
        var f = FullPath(env, storedName);
        return File.Exists(f) ? (f, storedName.EndsWith(".png", StringComparison.OrdinalIgnoreCase) ? "image/png" : "image/jpeg") : null;
    }
}
