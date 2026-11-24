namespace EMR.Web.Services;

/// <summary>Files uploaded on IPD screens (TPA documents, SQLScripts/2540): checked type and size, saved under wwwroot/uploads.</summary>
public static class IpdUploads
{
    public static readonly string[] Documents = [".pdf", ".jpg", ".jpeg", ".png", ".doc", ".docx"];

    /// <summary>The saved file's web path, or null when no file was chosen. Throws InvalidOperationException with a message for the user.</summary>
    public static async Task<string?> SaveAsync(IWebHostEnvironment env, IFormFile? file, string folder, string[] allowed)
    {
        if (file is null || file.Length == 0) return null;
        var ext = Path.GetExtension(file.FileName).ToLowerInvariant();
        if (!allowed.Contains(ext)) throw new InvalidOperationException($"{file.FileName}: only {string.Join(", ", allowed)} files can be uploaded.");
        if (file.Length > 10 * 1024 * 1024) throw new InvalidOperationException($"{file.FileName} is larger than 10 MB.");
        var dir = Path.Combine(env.WebRootPath, "uploads", folder);
        Directory.CreateDirectory(dir);
        var name = $"{Guid.NewGuid()}{ext}";
        await using (var stream = new FileStream(Path.Combine(dir, name), FileMode.Create)) await file.CopyToAsync(stream);
        return $"/uploads/{folder}/{name}";
    }
}
