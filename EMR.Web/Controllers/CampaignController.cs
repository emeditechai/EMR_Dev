using System.Text.Json;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Services;
using EMR.Web.Services.Campaigns;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Utility > Campaigns (SQLScripts/2299): emails to Patients, Users or Doctors - everyone, a filtered group or people
/// picked by hand - written in the email designer or from a saved campaign template, sent now or at a set time by
/// <see cref="CampaignSenderService"/> with the mail settings of the chosen "send from" branch. Data goes through
/// EMR.Api (api/campaigns, stored procedures usp_Campaign_*). Email only for now (Channel is kept for WhatsApp).
/// </summary>
[Authorize]
public class CampaignController(ICampaignApiClient api, CampaignSenderService sender, IEmailService emailService,
                                IDataProtectionProvider dataProtection, IAuditLogService audit) : Controller
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private int CompanyId => User.GetCompanyId();
    private int BranchId => User.GetCurrentBranchId() ?? 0;
    private bool IsHo => string.Equals(User.FindFirst("IsHOBranch")?.Value, "true", StringComparison.OrdinalIgnoreCase);

    /// <summary>Head Office may send from any branch; everyone else from the branch they are signed in to.</summary>
    private int SendBranch(int? requested) => IsHo && requested is > 0 ? requested.Value : BranchId;

    private static char Audience(string? t) => t is "U" or "D" ? t[0] : 'P';

    private static string AudiencesJson() => JsonSerializer.Serialize(CampaignAudiences.Names.Keys.Select(k => new
    {
        type = k.ToString(), name = CampaignAudiences.Name(k), single = CampaignAudiences.Single(k),
        fields = CampaignAudiences.Fields(k).Select(f => new { code = f.Code, label = f.Label, sample = f.Sample }),
        starter = CampaignAudiences.StarterDesign(k)
    }), Json);

    private static EmailType FieldsOnly(char type) => new("", "", "", CampaignAudiences.Fields(type), new EmailTemplateDesign(), "");

    // ── list ──────────────────────────────────────────────────────────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        var list = await api.ListAsync(CompanyId, BranchId, IsHo);
        ViewBag.Campaigns = list.Campaigns;
        ViewBag.Templates = list.Templates;
        return View();
    }

    // ── new campaign (wizard) ─────────────────────────────────────────────────────────────────────────────────

    public sealed class CampaignForm
    {
        public int CampaignId { get; set; }
        public string Name { get; set; } = "";
        public string AudienceType { get; set; } = "P";
        public int? TemplateId { get; set; }
        public int? SendBranchId { get; set; }
        public string Subject { get; set; } = "";
        public string? DesignJson { get; set; }
        public string? FilterJson { get; set; }
        /// <summary>draft, send or schedule.</summary>
        public string? Action { get; set; }
        public DateTime? ScheduledAt { get; set; }
    }

    [HttpGet]
    public async Task<IActionResult> Create(int? id, int? copy, string? type)
    {
        var form = new CampaignForm { AudienceType = Audience(type).ToString(), SendBranchId = BranchId };
        var source = id ?? copy;
        if (source is > 0)
        {
            var c = await api.GetAsync(source.Value, CompanyId, BranchId, IsHo);
            if (c is null) return NotFound();
            if (id is > 0 && c.Status != "DRAFT") return RedirectToAction(nameof(Details), new { id });
            form = new CampaignForm
            {
                CampaignId = id is > 0 ? c.CampaignId : 0,
                Name = copy is > 0 ? "Copy of " + c.Name : c.Name,
                AudienceType = c.AudienceType, TemplateId = c.TemplateId, SendBranchId = c.BranchId,
                Subject = c.Subject, DesignJson = c.DesignJson, FilterJson = c.FilterJson,
                ScheduledAt = id is > 0 ? c.ScheduledAt : null
            };
        }
        ViewBag.Form = JsonSerializer.Serialize(form, Json);
        ViewBag.Audiences = AudiencesJson();
        ViewBag.IsHo = IsHo;
        ViewBag.IsEditing = id is > 0;
        return View();
    }

    /// <summary>Branches (with the mail account each sends from), roles and specialities for the wizard.</summary>
    [HttpGet]
    public async Task<IActionResult> AudienceOptions()
    {
        var o = await api.OptionsAsync(CompanyId);
        return Json(new
        {
            branches = o.Branches.Select(b => new { id = b.Id, name = b.Name, isHo = b.IsHo, senderEmail = b.SenderEmail, hospitalName = b.HospitalName }),
            roles = o.Roles.Select(r => new { id = r.Id, name = r.Name }),
            specialities = o.Specialities.Select(s => new { id = s.Id, name = s.Name }),
            canChooseBranch = IsHo,
            currentBranchId = BranchId
        });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> AudienceCount(string audienceType, string? filterJson)
    {
        var s = await api.AudienceAsync(CompanyId, Audience(audienceType).ToString(), ParseFilter(filterJson));
        return Json(new
        {
            total = s.Total, reachable = s.Reachable, noEmail = s.NoEmail, unsubscribed = s.Unsubscribed, sharedEmail = s.SharedEmail,
            sample = s.Sample.Select(p => new { name = p.Name, email = p.Email, code = p.Code })
        });
    }

    [HttpGet]
    public async Task<IActionResult> AudienceSearch(string audienceType, string? term)
    {
        var rows = await api.SearchAsync(CompanyId, Audience(audienceType).ToString(), term);
        return Json(new
        {
            results = rows.Select(p =>
            {
                var ok = !string.IsNullOrWhiteSpace(p.Email) && System.Net.Mail.MailAddress.TryCreate(p.Email.Trim(), out _) && !p.OptedOut;
                var why = string.IsNullOrWhiteSpace(p.Email) ? " · no email" : p.OptedOut ? " · unsubscribed" : " · " + p.Email;
                return new { id = p.RefId, text = $"{p.Name}{(string.IsNullOrWhiteSpace(p.Code) ? "" : " · " + p.Code)}{why}", disabled = !ok };
            })
        });
    }

    private async Task<string> HospitalNameAsync(int branchId) =>
        (await api.OptionsAsync(CompanyId)).Branches.FirstOrDefault(b => b.Id == branchId)?.HospitalName?.Trim() ?? "";

    /// <summary>The email with sample values (or the field names) in the common layout, as the "send from" branch sends it.</summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Preview(string audienceType, string? subject, string? designJson, int? sendBranchId, bool asNames = false)
    {
        var type = Audience(audienceType);
        var body = EmailTemplateDesigner.FromJson(designJson) is { } d ? EmailTemplateDesigner.Build(d) : "";
        var hospital = await HospitalNameAsync(SendBranch(sendBranchId));
        var values = CampaignAudiences.Fields(type).ToDictionary(f => f.Code, f => (string?)(asNames ? "[" + f.Label + "]" : f.Sample));
        if (!asNames && hospital.Length > 0) values["HospitalName"] = hospital;
        var (s, html) = CampaignMail.Render(subject ?? "", body, values, hospital, type == 'P' ? "#" : null);
        var unknown = EmailTemplateDesigner.UnknownFields((subject ?? "") + " " + body, FieldsOnly(type));
        return Json(new
        {
            subject = s, html,
            warning = unknown.Count == 0 ? null : $"Not filled for {CampaignAudiences.Name(type)}: {string.Join(", ", unknown.Select(u => "{{" + u + "}}"))}."
        });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SendTest(string audienceType, string? subject, string? designJson, int? sendBranchId, string? testEmail)
    {
        if (string.IsNullOrWhiteSpace(testEmail) || !System.Net.Mail.MailAddress.TryCreate(testEmail.Trim(), out _))
            return Json(new { success = false, message = "Enter a valid email address." });
        var type = Audience(audienceType);
        var branch = SendBranch(sendBranchId);
        var body = EmailTemplateDesigner.FromJson(designJson) is { } d ? EmailTemplateDesigner.Build(d) : "";
        var hospital = await HospitalNameAsync(branch);
        var values = CampaignAudiences.Fields(type).ToDictionary(f => f.Code, f => (string?)f.Sample);
        if (hospital.Length > 0) values["HospitalName"] = hospital;
        var (s, html) = CampaignMail.Render(subject ?? "", body, values, hospital, type == 'P' ? "#" : null);
        var (ok, message) = await emailService.SendEmailAsync(branch, testEmail.Trim(), "[Test] " + s, html);
        return Json(new { success = ok, message = ok ? $"Test email sent to {testEmail.Trim()}." : message });
    }

    /// <summary>Saves the campaign as a draft, or sends it now / at the scheduled time (the recipients are fixed then).</summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Save([FromForm] CampaignForm m)
    {
        var type = Audience(m.AudienceType);
        var action = m.Action is "send" or "schedule" ? m.Action : "draft";
        var design = EmailTemplateDesigner.FromJson(m.DesignJson);
        if (design is null) return Json(new { success = false, message = "Write the message." });
        var html = EmailTemplateDesigner.Build(design);
        var unknown = EmailTemplateDesigner.UnknownFields(m.Subject + " " + html, FieldsOnly(type));
        if (unknown.Count > 0)
            return Json(new { success = false, message = $"These fields are not filled for {CampaignAudiences.Name(type)}: {string.Join(", ", unknown.Select(u => "{{" + u + "}}"))}." });
        var filter = ParseFilter(m.FilterJson);
        if (filter.Mode == "PICK" && filter.Ids.Count == 0 && action != "draft") return Json(new { success = false, message = "Pick at least one recipient." });

        var branch = SendBranch(m.SendBranchId);
        if (action != "draft" && string.IsNullOrWhiteSpace((await api.OptionsAsync(CompanyId)).Branches.FirstOrDefault(b => b.Id == branch)?.SenderEmail))
            return Json(new { success = false, message = "The chosen branch has no active mail settings. Set them up in Settings > SMTP, or send from another branch." });

        var (result, error) = await api.SaveAsync(new CampaignSaveRequest
        {
            CampaignId = m.CampaignId, CompanyId = CompanyId, BranchId = branch, UserId = User.GetUserId(),
            Name = m.Name ?? "", AudienceType = type.ToString(), TemplateId = m.TemplateId, Subject = m.Subject ?? "",
            DesignJson = EmailTemplateDesigner.ToJson(design), HtmlBody = html, Filter = filter,
            BaseUrl = await emailService.GetApplicationBaseUrlAsync(branch) ?? $"{Request.Scheme}://{Request.Host}{Request.PathBase}",
            Action = action, ScheduledAt = m.ScheduledAt
        });
        if (result is null) return Json(new { success = false, message = error });

        await audit.LogAsync("Utility", "Campaign", action switch
        {
            "send" => $"Campaign #{result.CampaignId} \"{m.Name?.Trim()}\" sent to {result.Queued} {CampaignAudiences.Name(type).ToLowerInvariant()} ({result.Skipped} skipped).",
            "schedule" => $"Campaign #{result.CampaignId} \"{m.Name?.Trim()}\" scheduled for {m.ScheduledAt:dd MMM yyyy hh:mm tt} to {result.Queued} {CampaignAudiences.Name(type).ToLowerInvariant()}.",
            _ => $"Campaign #{result.CampaignId} \"{m.Name?.Trim()}\" saved as a draft."
        });
        if (action == "send") _ = Task.Run(() => sender.RunOnceAsync(CancellationToken.None));   // start at once, not at the next tick
        return Json(new { success = true, id = result.CampaignId, url = action == "draft" ? Url.Action(nameof(Index)) : Url.Action(nameof(Details), new { id = result.CampaignId }) });
    }

    // ── a campaign's progress ─────────────────────────────────────────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var c = await api.GetAsync(id, CompanyId, BranchId, IsHo);
        if (c is null) return NotFound();
        ViewBag.Campaign = c;
        return View();
    }

    [HttpGet]
    public async Task<IActionResult> Progress(int id)
    {
        var r = await api.GetAsync(id, CompanyId, BranchId, IsHo);
        if (r is null) return Json(new { success = false });
        return Json(new
        {
            success = true, status = r.Status, total = r.Total, sent = r.Sent, failed = r.Failed, skipped = r.Skipped, pending = r.Pending,
            startedAt = r.StartedAt?.ToString("dd MMM yyyy, hh:mm tt"), completedAt = r.CompletedAt?.ToString("dd MMM yyyy, hh:mm tt")
        });
    }

    [HttpGet]
    public async Task<IActionResult> Recipients(int id, string? status, string? search)
    {
        if (await api.GetAsync(id, CompanyId, BranchId, IsHo) is null) return Json(new { success = false });
        var rows = await api.RecipientsAsync(id, CompanyId, status, search);
        return Json(new
        {
            success = true,
            rows = rows.Select(r => new { name = r.Name, email = r.Email, status = r.Status, message = r.Message, sentAt = r.SentAt?.ToString("dd MMM, hh:mm tt"), attempts = r.Attempts })
        });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Cancel(int id)
    {
        var n = await api.ActionAsync(id, CompanyId, User.GetUserId(), "CANCEL");
        if (n > 0) await audit.LogAsync("Utility", "Campaign", $"Campaign #{id} cancelled; emails not yet sent will not go out.");
        return Json(new { success = n > 0, message = n > 0 ? null : "Only a scheduled or sending campaign can be cancelled." });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> RetryFailed(int id)
    {
        var n = await api.ActionAsync(id, CompanyId, User.GetUserId(), "RETRY");
        if (n > 0) _ = Task.Run(() => sender.RunOnceAsync(CancellationToken.None));
        return Json(new { success = n > 0, message = n > 0 ? $"{n} email(s) will be sent again." : "There are no failed emails to send again." });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var n = await api.ActionAsync(id, CompanyId, User.GetUserId(), "DELETE");
        TempData[n > 0 ? "SuccessMessage" : "ErrorMessage"] = n > 0 ? "Draft deleted." : "Only a draft can be deleted.";
        return RedirectToAction(nameof(Index));
    }

    // ── campaign templates ────────────────────────────────────────────────────────────────────────────────────

    public sealed class TemplateForm
    {
        public int TemplateId { get; set; }
        public string Name { get; set; } = "";
        public string AudienceType { get; set; } = "P";
        public string Subject { get; set; } = "";
        public string? DesignJson { get; set; }
        public bool IsActive { get; set; } = true;
    }

    [HttpGet]
    public async Task<IActionResult> TemplateEdit(int? id, string? type)
    {
        var form = new TemplateForm { AudienceType = Audience(type).ToString() };
        if (id is > 0)
        {
            var t = await api.TemplateGetAsync(id.Value, CompanyId);
            if (t is null) return NotFound();
            form = new TemplateForm { TemplateId = t.TemplateId, Name = t.Name, AudienceType = t.AudienceType, Subject = t.Subject, DesignJson = t.DesignJson, IsActive = t.IsActive };
        }
        else form.DesignJson = EmailTemplateDesigner.ToJson(CampaignAudiences.StarterDesign(form.AudienceType[0]));
        ViewBag.Form = JsonSerializer.Serialize(form, Json);
        ViewBag.Audiences = AudiencesJson();
        return View();
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> TemplateEdit([FromForm] TemplateForm m)
    {
        var type = Audience(m.AudienceType);
        var design = EmailTemplateDesigner.FromJson(m.DesignJson);
        if (design is null || string.IsNullOrWhiteSpace(EmailTemplateDesigner.Build(design))) return Json(new { success = false, message = "Write the message." });
        var unknown = EmailTemplateDesigner.UnknownFields(m.Subject + " " + EmailTemplateDesigner.Build(design), FieldsOnly(type));
        if (unknown.Count > 0)
            return Json(new { success = false, message = $"These fields are not filled for {CampaignAudiences.Name(type)}: {string.Join(", ", unknown.Select(u => "{{" + u + "}}"))}." });
        var (_, error) = await api.TemplateSaveAsync(new CampaignTemplate
        {
            TemplateId = m.TemplateId, CompanyId = CompanyId, UserId = User.GetUserId(), Name = m.Name ?? "", AudienceType = type.ToString(),
            Subject = m.Subject ?? "", DesignJson = EmailTemplateDesigner.ToJson(design), IsActive = m.IsActive
        });
        if (error is not null) return Json(new { success = false, message = error });
        TempData["SuccessMessage"] = $"Template \"{m.Name?.Trim()}\" saved.";
        return Json(new { success = true, url = Url.Action(nameof(Index)) + "#templates" });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> TemplateDelete(int id)
    {
        await api.TemplateDeleteAsync(id, CompanyId);
        TempData["SuccessMessage"] = "Template deleted. Campaigns already sent with it keep their own copy of the message.";
        return Redirect(Url.Action(nameof(Index))! + "#templates");
    }

    [HttpGet]
    public async Task<IActionResult> TemplateGet(int id)
    {
        var t = await api.TemplateGetAsync(id, CompanyId);
        return t is null ? Json(new { success = false }) : Json(new { success = true, t.TemplateId, t.Name, t.AudienceType, t.Subject, t.DesignJson });
    }

    [HttpGet]
    public async Task<IActionResult> TemplateList(string audienceType) =>
        Json((await api.TemplateListAsync(CompanyId, Audience(audienceType).ToString())).Select(t => new { id = t.TemplateId, name = t.Name, subject = t.Subject }));

    // ── unsubscribe (patients; no sign-in) ────────────────────────────────────────────────────────────────────

    [HttpGet]
    [AllowAnonymous]
    [EMR.Shared.Security.PublicEndpoint]
    public IActionResult Unsubscribe(string id)
    {
        ViewBag.Token = id;
        ViewBag.Email = ReadOptOut(id) is { } t ? Mask(t.Email) : null;
        ViewBag.Done = false;
        return View();
    }

    [HttpPost]
    [AllowAnonymous]
    [EMR.Shared.Security.PublicEndpoint]
    [ValidateAntiForgeryToken]
    [ActionName("Unsubscribe")]
    public async Task<IActionResult> UnsubscribeConfirm(string id)
    {
        var t = ReadOptOut(id);
        ViewBag.Token = id;
        ViewBag.Email = t is null ? null : Mask(t.Value.Email);
        if (t is not null) await api.OptOutAsync(t.Value.CompanyId, t.Value.CampaignId, t.Value.Email);
        ViewBag.Done = t is not null;
        return View("Unsubscribe");
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────────────────────

    private static CampaignAudienceFilter ParseFilter(string? json)
    {
        CampaignAudienceFilter f;
        try { f = string.IsNullOrWhiteSpace(json) ? new() : JsonSerializer.Deserialize<CampaignAudienceFilter>(json, Json) ?? new(); }
        catch (JsonException) { f = new(); }
        if (f.Mode is not ("ALL" or "FILTER" or "PICK")) f.Mode = "ALL";
        return f;
    }

    private (int CompanyId, int CampaignId, string Email)? ReadOptOut(string? token)
    {
        if (string.IsNullOrWhiteSpace(token)) return null;
        try
        {
            var parts = dataProtection.CreateProtector(CampaignMail.OptOutPurpose).Unprotect(token).Split('|');
            return parts.Length == 3 && int.TryParse(parts[0], out var co) && int.TryParse(parts[1], out var c) ? (co, c, parts[2]) : null;
        }
        catch (System.Security.Cryptography.CryptographicException) { return null; }
    }

    private static string Mask(string email)
    {
        var at = email.IndexOf('@');
        return at <= 1 ? email : email[0] + new string('*', Math.Min(6, at - 1)) + email[at..];
    }
}
