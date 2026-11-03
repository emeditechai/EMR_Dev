using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Utility > App Downloads (SQLScripts/2394): the Android apps uploaded in Hospital Settings > App (APK) Upload
/// (SQLScripts/2393) - the latest version of each app, then the earlier ones - fetched from the App FTP server.
/// An open link: no sign-in and no permission (e.g. shared with phlebotomists to install the app); without a sign-in
/// the apps of the default company are listed.
/// </summary>
[AllowAnonymous]
public class AppDownloadsController(IAppApkService apps, ILabFtpService ftp, IAuditLogService audit, IWebHostEnvironment env) : Controller
{
    /// <summary>The web server's copy of the uploaded apps (App_Data/apk-cache/&lt;sha256&gt;.apk): the FTP server is slow for a
    /// large file, so it is read from FTP once and served from here afterwards. Filled at upload too (HospitalSettings).</summary>
    public static string CacheFile(string contentRoot, string sha256) => Path.Combine(contentRoot, "App_Data", "apk-cache", sha256 + ".apk");

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        var rows = await apps.ListAsync(User.GetCompanyId());
        return View(rows);
    }

    [HttpGet]
    public async Task<IActionResult> Download(int id)
    {
        var r = await apps.GetAsync(User.GetCompanyId(), id);
        if (r is null) return NotFound("The app file was not found.");
        var settings = await apps.GetFtpAsync(User.GetCompanyId(), r.BranchId, ownOnly: false);
        if (settings is null) return Problem("The FTP server for App (APK) upload is not set (Hospital Settings > Lab).", statusCode: 503);

        // the web server's copy (checked by size): served at full speed
        var cached = r.Sha256 is { Length: 64 } ? CacheFile(env.ContentRootPath, r.Sha256) : null;
        if (cached is not null && System.IO.File.Exists(cached) && new FileInfo(cached).Length == r.FileSizeBytes)
        {
            try { await audit.LogAsync("Download", "AppDownloads", $"App downloaded: {r.AppName} v{r.VersionName} ({r.FileName}) from {HttpContext.Connection.RemoteIpAddress}",
                    User.Identity?.IsAuthenticated == true && User.GetUserId() > 0 ? User.GetUserId() : null, User.GetCurrentBranchId()); } catch { }
            return PhysicalFile(cached, "application/vnd.android.package-archive", r.FileName, enableRangeProcessing: true);
        }

        // streamed from the FTP server to the browser as it arrives (a large app starts downloading at once)
        int? userId = User.Identity?.IsAuthenticated == true && User.GetUserId() > 0 ? User.GetUserId() : null;   // an open link: no user
        var started = false;
        try
        {
            // the browser gets it as it arrives, and the web server keeps a copy for the next downloads
            string? temp = cached is null ? null : cached + "." + Guid.NewGuid().ToString("N") + ".part";
            if (temp is not null) Directory.CreateDirectory(Path.GetDirectoryName(temp)!);
            await using var copy = temp is null ? null : new FileStream(temp, FileMode.CreateNew);
            await using var target = new TeeStream(Response.Body, copy);
            var found = await ftp.CopyToAsync(settings, r.FilePath, target, async size =>
            {
                started = true;
                Response.ContentType = "application/vnd.android.package-archive";
                Response.Headers.ContentDisposition = new Microsoft.Net.Http.Headers.ContentDispositionHeaderValue("attachment") { FileNameStar = r.FileName, FileName = r.FileName }.ToString();
                if (size > 0) Response.ContentLength = size;
                await Response.StartAsync();
            }, HttpContext.RequestAborted);
            if (copy is not null) await copy.DisposeAsync();
            if (!found) { if (temp is not null) System.IO.File.Delete(temp); return NotFound("The app file is no longer on the FTP server."); }
            if (temp is not null && cached is not null)
            {
                try
                {
                    if (new FileInfo(temp).Length == r.FileSizeBytes) System.IO.File.Move(temp, cached, overwrite: true);
                    else System.IO.File.Delete(temp);
                }
                catch { /* another download put it there first */ }
            }
        }
        catch (Exception ex) when (!started)
        {
            return Problem("The app file could not be read from the FTP server: " + ex.Message, statusCode: 502);
        }

        try { await audit.LogAsync("Download", "AppDownloads", $"App downloaded: {r.AppName} v{r.VersionName} ({r.FileName}) from {HttpContext.Connection.RemoteIpAddress}", userId, User.GetCurrentBranchId()); }
        catch { /* the download itself is done */ }
        return new EmptyResult();
    }
}

/// <summary>Writes to the response and, when given, to a second stream (the web server's copy of the file).</summary>
internal sealed class TeeStream(Stream main, Stream? copy) : Stream
{
    public override bool CanRead => false;
    public override bool CanSeek => false;
    public override bool CanWrite => true;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override void Flush() { main.Flush(); copy?.Flush(); }
    public override async Task FlushAsync(CancellationToken ct) { await main.FlushAsync(ct); if (copy is not null) await copy.FlushAsync(ct); }
    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) { main.Write(buffer, offset, count); copy?.Write(buffer, offset, count); }
    public override async ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken ct = default)
    {
        await main.WriteAsync(buffer, ct);
        if (copy is not null) await copy.WriteAsync(buffer, ct);
    }
    public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken ct) => WriteAsync(buffer.AsMemory(offset, count), ct).AsTask();
}
