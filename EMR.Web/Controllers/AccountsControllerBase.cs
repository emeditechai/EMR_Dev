using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Shared by the Utility > Accounts screens (SQLScripts/2244 - 2246). Branch scope: a user of the head-office branch
/// (or a Super Admin) works across branches and may pick one; everyone else sees and enters only for their own branch.
/// </summary>
[Authorize]
public abstract class AccountsControllerBase : Controller
{
    protected int CompanyId => User.GetCompanyId();
    protected int UserId => User.GetUserId();
    protected int? OwnBranchId => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId");
    protected bool SeesAllBranches => User.IsHOBranch() || User.IsSuperAdmin();

    /// <summary>The branch filter to query with: the requested one (or all) for head office, the user's own otherwise.</summary>
    protected int? ScopeBranch(int? requested = null) => SeesAllBranches ? (requested is > 0 ? requested : null) : OwnBranchId ?? -1;

    protected bool CanUseBranch(int branchId) => SeesAllBranches || branchId == OwnBranchId;

    protected static string Msg(Exception ex) => AccountsService.UserMessage(ex);

    /// <summary>Period of a list / report from the query string: the current month by default, never reversed.</summary>
    protected static (DateTime From, DateTime To) Period(DateTime? from, DateTime? to, bool monthByDefault = true)
    {
        var today = DateTime.Today;
        var t = (to ?? today).Date;
        var f = (from ?? (monthByDefault ? new DateTime(t.Year, t.Month, 1) : t)).Date;
        return f > t ? (t, f) : (f, t);
    }

    // ── Attachments (bill photos / scans) ─────────────────────────────────────
    // Kept in App_Data/accounts, outside wwwroot: a file is reached only through an action that checks the branch.
    protected const int MaxAttachments = 5;
    protected const long MaxAttachmentBytes = 5 * 1024 * 1024;

    private string AttachmentRoot =>
        Path.Combine(HttpContext.RequestServices.GetRequiredService<IWebHostEnvironment>().ContentRootPath, "App_Data", "accounts");

    /// <summary>Saves the uploaded bills of a petty expense ("PETTY_EXP") or voucher ("VOUCHER"). JPG, PNG, WEBP or PDF,
    /// recognised by content (not by the name the browser sent), 5 MB each, 5 per document.</summary>
    protected async Task<(int Saved, string? Error)> SaveAttachmentsAsync(IAccountsService accounts, string refType, int refId, IEnumerable<IFormFile>? files)
    {
        var list = files?.Where(f => f is { Length: > 0 }).ToList() ?? [];
        if (list.Count == 0) return (0, null);
        var have = (await accounts.GetAttachmentsAsync(CompanyId, refType, refId)).Count;
        var saved = 0;
        string? error = null;

        foreach (var file in list)
        {
            if (have + saved >= MaxAttachments) { error = $"At most {MaxAttachments} attachments per document."; break; }
            if (file.Length > MaxAttachmentBytes) { error = $"{Path.GetFileName(file.FileName)} is larger than 5 MB."; continue; }

            var head = new byte[12];
            await using (var probe = file.OpenReadStream()) _ = await probe.ReadAsync(head.AsMemory(0, 12));
            (string Ext, string Type) kind = head switch
            {
                [0xFF, 0xD8, 0xFF, ..] => (".jpg", "image/jpeg"),
                [0x89, 0x50, 0x4E, 0x47, ..] => (".png", "image/png"),
                [0x25, 0x50, 0x44, 0x46, ..] => (".pdf", "application/pdf"),
                [0x52, 0x49, 0x46, 0x46, _, _, _, _, 0x57, 0x45, 0x42, 0x50] => (".webp", "image/webp"),
                _ => ("", "")
            };
            if (kind.Ext.Length == 0) { error = $"{Path.GetFileName(file.FileName)} is not a JPG, PNG, WEBP or PDF file."; continue; }

            Directory.CreateDirectory(AttachmentRoot);
            var stored = $"{Guid.NewGuid():N}{kind.Ext}";
            await using (var target = System.IO.File.Create(Path.Combine(AttachmentRoot, stored))) await file.CopyToAsync(target);

            var name = Path.GetFileName(file.FileName);
            await accounts.AddAttachmentAsync(CompanyId, new AccAttachmentDto
            {
                RefType = refType, RefId = refId, FileName = name.Length > 200 ? name[^200..] : name, StoredName = stored, ContentType = kind.Type, SizeBytes = (int)file.Length
            }, UserId);
            saved++;
        }
        return (saved, error);
    }

    /// <summary>Sends an attachment to the browser (shown inline). The caller has already checked the user may see its document.</summary>
    protected IActionResult ServeAttachment(AccAttachmentDto a)
    {
        var path = Path.Combine(AttachmentRoot, Path.GetFileName(a.StoredName));
        if (!System.IO.File.Exists(path)) return NotFound();
        Response.Headers.XContentTypeOptions = "nosniff";
        Response.Headers.ContentDisposition = $"inline; filename=\"{a.FileName.Replace("\"", "")}\"";
        return PhysicalFile(path, a.ContentType);
    }

    protected IActionResult BackToList(string message, bool error = false, string action = "Index", object? route = null)
    {
        TempData[error ? "ErrorMessage" : "SuccessMessage"] = message;
        return RedirectToAction(action, route);
    }
}
