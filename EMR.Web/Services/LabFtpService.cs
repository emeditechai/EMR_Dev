using System.Text.RegularExpressions;
using Dapper;
using EMR.Web.Data;
using FluentFTP;
using Microsoft.AspNetCore.DataProtection;

namespace EMR.Web.Services;

/// <summary>FTP server used for external lab documents (dbo.LabFtpSettings, SQLScripts/2354).</summary>
public class LabFtpSettings
{
    public int FtpSettingId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string Host { get; set; } = "";
    public int Port { get; set; } = 21;
    public string UserName { get; set; } = "";
    public string? PasswordEnc { get; set; }
    public string RootFolder { get; set; } = "emedidoc/reports";
    public bool UsePassive { get; set; } = true;
    public bool UseFtps { get; set; }
    public DateTime ModifiedDate { get; set; }
}

public interface ILabFtpService
{
    /// <summary>The branch's FTP settings, else the head office's, else any of the company's.</summary>
    Task<LabFtpSettings?> GetForBranchAsync(int companyId, int branchId);

    /// <summary>The branch's own row only (for the settings page).</summary>
    Task<LabFtpSettings?> GetOwnAsync(int branchId);

    /// <summary>Saves the branch's settings; a blank password keeps the stored one.</summary>
    Task SaveAsync(LabFtpSettings settings, string? newPassword, int userId);

    /// <summary>Connects and checks the root folder can be reached (created when missing).</summary>
    Task<(bool Ok, string Message)> TestAsync(LabFtpSettings settings, string? passwordOverride);

    /// <summary>Uploads a file to folder (created when missing) under the root folder and returns its full path.</summary>
    Task<string> UploadAsync(LabFtpSettings settings, IEnumerable<string> folders, string fileName, Stream content, CancellationToken ct);

    /// <summary>A folder / file name safe on FTP servers.</summary>
    string SafeName(string value);
}

public class LabFtpService(IDbConnectionFactory db, IDataProtectionProvider protection, ILogger<LabFtpService> logger) : ILabFtpService
{
    private readonly IDataProtector protector = protection.CreateProtector("EMR.LabFtpSettings.Password.v1");

    private const string Columns = "FtpSettingId, CompanyId, BranchId, Host, Port, UserName, PasswordEnc, RootFolder, UsePassive, UseFtps, ModifiedDate";

    public async Task<LabFtpSettings?> GetForBranchAsync(int companyId, int branchId)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<LabFtpSettings>(@"
            SELECT TOP 1 s.FtpSettingId, s.CompanyId, s.BranchId, s.Host, s.Port, s.UserName, s.PasswordEnc, s.RootFolder,
                   s.UsePassive, s.UseFtps, s.ModifiedDate
              FROM dbo.LabFtpSettings s
              LEFT JOIN dbo.Branchmaster b ON b.BranchID = s.BranchId
             WHERE s.CompanyId = @companyId AND s.IsActive = 1
             ORDER BY CASE WHEN s.BranchId = @branchId THEN 0 WHEN ISNULL(b.IsHOBranch, 0) = 1 THEN 1 ELSE 2 END, s.FtpSettingId",
            new { companyId, branchId });
    }

    public async Task<LabFtpSettings?> GetOwnAsync(int branchId)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<LabFtpSettings>(
            $"SELECT {Columns} FROM dbo.LabFtpSettings WHERE BranchId = @branchId", new { branchId });
    }

    public async Task SaveAsync(LabFtpSettings s, string? newPassword, int userId)
    {
        var enc = string.IsNullOrEmpty(newPassword) ? null : protector.Protect(newPassword);
        using var con = db.CreateConnection();
        await con.ExecuteAsync(@"
            MERGE dbo.LabFtpSettings AS t
            USING (SELECT @BranchId AS BranchId) AS src ON t.BranchId = src.BranchId
            WHEN MATCHED THEN UPDATE SET Host = @Host, Port = @Port, UserName = @UserName,
                 PasswordEnc = COALESCE(@enc, t.PasswordEnc), RootFolder = @RootFolder, UsePassive = @UsePassive,
                 UseFtps = @UseFtps, IsActive = 1, ModifiedBy = @userId, ModifiedDate = GETDATE()
            WHEN NOT MATCHED THEN INSERT (CompanyId, BranchId, Host, Port, UserName, PasswordEnc, RootFolder, UsePassive, UseFtps, ModifiedBy)
                 VALUES (@CompanyId, @BranchId, @Host, @Port, @UserName, @enc, @RootFolder, @UsePassive, @UseFtps, @userId);",
            new { s.CompanyId, s.BranchId, s.Host, s.Port, s.UserName, enc, s.RootFolder, s.UsePassive, s.UseFtps, userId });
    }

    public async Task<(bool Ok, string Message)> TestAsync(LabFtpSettings s, string? passwordOverride)
    {
        try
        {
            await using var client = Create(s, passwordOverride);
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            await client.Connect(cts.Token);
            var root = Root(s);
            if (!string.IsNullOrEmpty(root) && !await client.DirectoryExists(root, cts.Token))
                await client.CreateDirectory(root, true, cts.Token);
            await client.Disconnect(cts.Token);
            return (true, $"Connected to {s.Host}. The folder '{(string.IsNullOrEmpty(root) ? "/" : root)}' is ready.");
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "FTP test to {Host} failed", s.Host);
            return (false, "Could not connect: " + Plain(ex));
        }
    }

    public async Task<string> UploadAsync(LabFtpSettings s, IEnumerable<string> folders, string fileName, Stream content, CancellationToken ct)
    {
        var dir = string.Join("/", new[] { Root(s) }.Concat(folders.Select(SafeName)).Where(p => !string.IsNullOrEmpty(p)));
        var path = (string.IsNullOrEmpty(dir) ? "" : dir + "/") + SafeName(fileName);
        await using var client = Create(s, null);
        await client.Connect(ct);
        if (!string.IsNullOrEmpty(dir) && !await client.DirectoryExists(dir, ct))
            await client.CreateDirectory(dir, true, ct);
        var status = await client.UploadStream(content, path, FtpRemoteExists.Overwrite, true, null, ct);
        await client.Disconnect(ct);
        if (status != FtpStatus.Success)
            throw new InvalidOperationException("The FTP server did not accept the file.");
        return path;
    }

    public string SafeName(string value)
    {
        var s = Regex.Replace(value.Trim(), @"[^A-Za-z0-9._\-]+", "_").Trim('_', '.');
        return string.IsNullOrEmpty(s) ? "_" : s;
    }

    private AsyncFtpClient Create(LabFtpSettings s, string? passwordOverride)
    {
        if (string.IsNullOrWhiteSpace(s.Host) || string.IsNullOrWhiteSpace(s.UserName))
            throw new InvalidOperationException("FTP host and user are not set (Hospital Settings > Lab).");
        var password = !string.IsNullOrEmpty(passwordOverride) ? passwordOverride
            : string.IsNullOrEmpty(s.PasswordEnc) ? throw new InvalidOperationException("The FTP password is not set (Hospital Settings > Lab).")
            : protector.Unprotect(s.PasswordEnc);
        var client = new AsyncFtpClient(s.Host.Trim(), s.UserName.Trim(), password, s.Port > 0 ? s.Port : 21);
        client.Config.ConnectTimeout = 20000;
        client.Config.ReadTimeout = 60000;
        client.Config.DataConnectionType = s.UsePassive ? FtpDataConnectionType.AutoPassive : FtpDataConnectionType.AutoActive;
        if (s.UseFtps)
        {
            client.Config.EncryptionMode = FtpEncryptionMode.Explicit;
            client.Config.ValidateAnyCertificate = true;
        }
        return client;
    }

    private static string Root(LabFtpSettings s) => (s.RootFolder ?? "").Trim().Trim('/').Replace('\\', '/');

    private static string Plain(Exception ex)
    {
        var e = ex;
        while (e.InnerException is not null && e is not FluentFTP.Exceptions.FtpCommandException) e = e.InnerException;
        return e.Message;
    }
}
