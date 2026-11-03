using System.Data;
using Dapper;
using EMR.Web.Data;

namespace EMR.Web.Services;

/// <summary>A release of an Android app (a row of dbo.usp_AppApk_List, SQLScripts/2393).</summary>
public sealed class AppApkRelease
{
    public int ApkId { get; set; }
    public int BranchId { get; set; }
    public string? BranchName { get; set; }
    public string AppName { get; set; } = "";
    public string VersionName { get; set; } = "";
    public int? VersionCode { get; set; }
    public string OriginalFileName { get; set; } = "";
    public string FileName { get; set; } = "";
    public string FilePath { get; set; } = "";
    public long FileSizeBytes { get; set; }
    public string? Sha256 { get; set; }
    public string? ReleaseNotes { get; set; }
    public bool IsLatest { get; set; }
    public DateTime UploadedDate { get; set; }
    public string? UploadedByName { get; set; }
}

/// <summary>
/// Hospital Settings > "FTP server for App (APK) Upload" (SQLScripts/2393): its own FTP credentials (kept like the
/// external-document FTP - the password encrypted, never sent back) and the APK version history. The FTP work itself
/// (connect, test, upload) is the external-document FTP service's, given these settings.
/// </summary>
public interface IAppApkService
{
    Task<LabFtpSettings?> GetFtpAsync(int companyId, int branchId, bool ownOnly);
    Task SaveFtpAsync(LabFtpSettings settings, string? newPassword, int userId);
    Task<List<AppApkRelease>> ListAsync(int companyId);
    /// <summary>One active release of the company (Utility > App Downloads, SQLScripts/2394).</summary>
    Task<AppApkRelease?> GetAsync(int companyId, int apkId);
    Task<int> SaveReleaseAsync(AppApkRelease r, int companyId, int userId);
    Task SetLatestAsync(int companyId, int apkId, int userId);
    Task RemoveAsync(int companyId, int apkId, int userId);
}

public class AppApkService(IDbConnectionFactory db, ILabFtpService ftp) : IAppApkService
{
    public async Task<LabFtpSettings?> GetFtpAsync(int companyId, int branchId, bool ownOnly)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<LabFtpSettings>("dbo.usp_AppFtp_Get",
            new { CompanyId = companyId, BranchId = branchId, OwnOnly = ownOnly }, commandType: CommandType.StoredProcedure);
    }

    public async Task SaveFtpAsync(LabFtpSettings s, string? newPassword, int userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("dbo.usp_AppFtp_Save", new
        {
            s.CompanyId, s.BranchId, s.Host, s.Port, s.UserName,
            PasswordEnc = string.IsNullOrEmpty(newPassword) ? null : ftp.ProtectPassword(newPassword),
            s.RootFolder, s.UsePassive, s.UseFtps, UserId = userId
        }, commandType: CommandType.StoredProcedure);
    }

    public async Task<List<AppApkRelease>> ListAsync(int companyId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<AppApkRelease>("dbo.usp_AppApk_List", new { CompanyId = companyId }, commandType: CommandType.StoredProcedure)).ToList();
    }

    public async Task<AppApkRelease?> GetAsync(int companyId, int apkId)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<AppApkRelease>("dbo.usp_AppApk_Get", new { CompanyId = companyId, ApkId = apkId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<int> SaveReleaseAsync(AppApkRelease r, int companyId, int userId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int>("dbo.usp_AppApk_Save", new
        {
            CompanyId = companyId, r.BranchId, r.AppName, r.VersionName, r.VersionCode, r.OriginalFileName, r.FileName, r.FilePath,
            r.FileSizeBytes, r.Sha256, r.ReleaseNotes, UserId = userId
        }, commandType: CommandType.StoredProcedure);
    }

    public async Task SetLatestAsync(int companyId, int apkId, int userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("dbo.usp_AppApk_SetLatest", new { CompanyId = companyId, ApkId = apkId, UserId = userId }, commandType: CommandType.StoredProcedure);
    }

    public async Task RemoveAsync(int companyId, int apkId, int userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("dbo.usp_AppApk_Remove", new { CompanyId = companyId, ApkId = apkId, UserId = userId }, commandType: CommandType.StoredProcedure);
    }
}
