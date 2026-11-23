using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Extensions;
using EMR.Web.Services;

namespace EMR.Web.Controllers;

/// <summary>What the Email Templates designer posts and shows.</summary>
public sealed class EmailTemplateEditViewModel
{
    public int Id { get; set; }
    /// <summary>The email type (how the sending code finds the template).</summary>
    public string TemplateName { get; set; } = "";
    public string Subject { get; set; } = "";
    public bool IsActive { get; set; } = true;
    /// <summary>"design" (the designer) or "html" (hand-written HTML, advanced).</summary>
    public string Mode { get; set; } = "design";
    public string? DesignJson { get; set; }
    public string? HtmlBody { get; set; }

    // shown only
    public List<string> AvailableTypes { get; set; } = [];
    public string HospitalName { get; set; } = "";
    public DateTime? ModifiedDate { get; set; }
}

/// <summary>
/// Utility > Email Templates: the emails the application sends to patients, designed on screen (SQLScripts/2298) -
/// heading, message, details table, note and closing, merge fields picked from a list, a live preview in the common
/// email layout and a test email. HtmlBody (what the sending code uses) is built from the design on save.
/// </summary>
[Authorize(Roles = "Administrator,HO_Admin")]
public class EmailTemplateController(ApplicationDbContext dbContext, IEmailService emailService) : Controller
{
    private int BranchId => User.GetCurrentBranchId() ?? 0;

    public async Task<IActionResult> Index()
    {
        var templates = await dbContext.EmailTemplates
            .Where(t => t.BranchId == BranchId)
            .OrderBy(t => t.TemplateName)
            .ToListAsync();
        ViewBag.MissingTypes = EmailTemplateDesigner.Types.Select(t => t.Name)
            .Where(n => templates.All(x => !string.Equals(x.TemplateName, n, StringComparison.OrdinalIgnoreCase))).ToList();
        return View(templates);
    }

    [HttpGet]
    public async Task<IActionResult> Create(string? type)
    {
        var missing = await MissingTypesAsync();
        if (missing.Count == 0)
        {
            TempData["ErrorMessage"] = "Every email type already has a template for this branch. Edit the existing one.";
            return RedirectToAction(nameof(Index));
        }
        var t = EmailTemplateDesigner.Find(type) is { } found && missing.Contains(found.Name) ? found : EmailTemplateDesigner.Find(missing[0])!;
        return View(new EmailTemplateEditViewModel
        {
            TemplateName = t.Name,
            Subject = t.DefaultSubject,
            DesignJson = EmailTemplateDesigner.ToJson(t.Default),
            AvailableTypes = missing,
            HospitalName = await HospitalNameAsync()
        });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(EmailTemplateEditViewModel model)
    {
        var missing = await MissingTypesAsync();
        var type = EmailTemplateDesigner.Find(model.TemplateName);
        if (type is null || !missing.Contains(type.Name))
            ModelState.AddModelError(nameof(model.TemplateName), "Choose an email type that has no template yet.");
        var html = type is null ? null : BuildBody(model, type);
        if (!ModelState.IsValid || html is null)
        {
            model.AvailableTypes = missing;
            model.HospitalName = await HospitalNameAsync();
            return View(model);
        }

        dbContext.EmailTemplates.Add(new EmailTemplate
        {
            BranchId = BranchId,
            TemplateName = type!.Name,
            Subject = model.Subject.Trim(),
            HtmlBody = html,
            DesignJson = model.Mode == "html" ? null : model.DesignJson,
            IsActive = model.IsActive,
            CreatedBy = User.GetUserId(),
            CreatedDate = DateTime.UtcNow
        });
        await dbContext.SaveChangesAsync();
        TempData["SuccessMessage"] = $"The {type.Name} email template was created.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var t = await dbContext.EmailTemplates.FirstOrDefaultAsync(x => x.Id == id && x.BranchId == BranchId);
        if (t == null) return NotFound();
        var hasDesign = EmailTemplateDesigner.FromJson(t.DesignJson) is not null;
        return View(new EmailTemplateEditViewModel
        {
            Id = t.Id,
            TemplateName = t.TemplateName,
            Subject = t.Subject,
            IsActive = t.IsActive,
            Mode = hasDesign ? "design" : "html",
            DesignJson = hasDesign ? t.DesignJson
                       : EmailTemplateDesigner.Find(t.TemplateName) is { } type ? EmailTemplateDesigner.ToJson(type.Default) : null,
            HtmlBody = t.HtmlBody,
            HospitalName = await HospitalNameAsync(),
            ModifiedDate = t.ModifiedDate ?? t.CreatedDate
        });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, EmailTemplateEditViewModel model)
    {
        if (id != model.Id) return BadRequest();
        var existing = await dbContext.EmailTemplates.FirstOrDefaultAsync(t => t.Id == id && t.BranchId == BranchId);
        if (existing == null) return NotFound();

        // the email type is fixed: the sending code finds the template by it
        model.TemplateName = existing.TemplateName;
        var type = EmailTemplateDesigner.Find(existing.TemplateName);
        var html = type is null
            ? (model.Mode == "html" && !string.IsNullOrWhiteSpace(model.HtmlBody) ? model.HtmlBody : null)
            : BuildBody(model, type);
        if (type is null && html is null) ModelState.AddModelError(nameof(model.HtmlBody), "Enter the email body.");
        if (string.IsNullOrWhiteSpace(model.Subject)) ModelState.AddModelError(nameof(model.Subject), "Enter the email subject.");
        if (!ModelState.IsValid || html is null)
        {
            model.HospitalName = await HospitalNameAsync();
            model.ModifiedDate = existing.ModifiedDate ?? existing.CreatedDate;
            return View(model);
        }

        existing.Subject = model.Subject.Trim();
        existing.HtmlBody = html;
        existing.DesignJson = model.Mode == "html" ? null : model.DesignJson;
        existing.IsActive = model.IsActive;
        existing.ModifiedBy = User.GetUserId();
        existing.ModifiedDate = DateTime.UtcNow;
        await dbContext.SaveChangesAsync();

        TempData["SuccessMessage"] = $"The {existing.TemplateName} email template was saved.";
        return RedirectToAction(nameof(Index));
    }

    /// <summary>The email as the patient will see it, with sample values (or the field names), in the common layout.</summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Preview(EmailTemplateEditViewModel model, bool asNames = false)
    {
        var type = EmailTemplateDesigner.Find(model.TemplateName);
        if (type is null) return Json(new { success = false, message = "Unknown email type." });
        var body = model.Mode == "html" ? model.HtmlBody ?? "" : EmailTemplateDesigner.FromJson(model.DesignJson) is { } d ? EmailTemplateDesigner.Build(d) : "";
        var hospital = await HospitalNameAsync();
        var html = EmailTemplateDesigner.Fill(body, WithHospital(EmailTemplateDesigner.Samples(type, asNames, html: true), hospital, asNames, true));
        var subject = EmailTemplateDesigner.Fill(model.Subject, WithHospital(EmailTemplateDesigner.Samples(type, asNames, html: false), hospital, asNames, false));
        var unknown = EmailTemplateDesigner.UnknownFields(model.Subject + " " + body, type);
        return Json(new
        {
            success = true,
            subject,
            html = model.Mode == "html" ? EmailLayout.EnsureBranded(html) : EmailLayout.Wrap(html, organisation: hospital),
            warning = unknown.Count == 0 ? null : $"Not filled for this email: {string.Join(", ", unknown.Select(u => "{{" + u + "}}"))} - these would be sent as typed."
        });
    }

    /// <summary>Sends the email being designed, with sample values, to the given address (the branch's mail settings).</summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SendTest(EmailTemplateEditViewModel model, string? testEmail)
    {
        var type = EmailTemplateDesigner.Find(model.TemplateName);
        if (type is null) return Json(new { success = false, message = "Unknown email type." });
        if (string.IsNullOrWhiteSpace(testEmail) || !System.Net.Mail.MailAddress.TryCreate(testEmail.Trim(), out _))
            return Json(new { success = false, message = "Enter a valid email address." });
        var body = model.Mode == "html" ? model.HtmlBody ?? "" : EmailTemplateDesigner.FromJson(model.DesignJson) is { } d ? EmailTemplateDesigner.Build(d) : "";
        var hospital = await HospitalNameAsync();
        var html = EmailTemplateDesigner.Fill(body, WithHospital(EmailTemplateDesigner.Samples(type, false, html: true), hospital, false, true));
        var subject = "[Test] " + EmailTemplateDesigner.Fill(model.Subject, WithHospital(EmailTemplateDesigner.Samples(type, false, html: false), hospital, false, false));
        var (ok, message) = await emailService.SendEmailAsync(BranchId, testEmail.Trim(), subject, html);
        return Json(new { success = ok, message = ok ? $"Test email sent to {testEmail.Trim()}." : message });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var template = await dbContext.EmailTemplates.FirstOrDefaultAsync(t => t.Id == id && t.BranchId == BranchId);
        if (template != null)
        {
            dbContext.EmailTemplates.Remove(template);
            await dbContext.SaveChangesAsync();
            TempData["SuccessMessage"] = "Template deleted. That email is not sent until a template for it is added again.";
        }
        else
        {
            TempData["ErrorMessage"] = "Template not found.";
        }
        return RedirectToAction(nameof(Index));
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────────────────────

    /// <summary>The stored body from the posted design (or HTML); null with a model error when it cannot be used.</summary>
    private string? BuildBody(EmailTemplateEditViewModel model, EmailType type)
    {
        if (string.IsNullOrWhiteSpace(model.Subject)) ModelState.AddModelError(nameof(model.Subject), "Enter the email subject.");
        string html;
        if (model.Mode == "html")
        {
            if (string.IsNullOrWhiteSpace(model.HtmlBody)) { ModelState.AddModelError(nameof(model.HtmlBody), "Enter the email body."); return null; }
            html = model.HtmlBody;
        }
        else
        {
            var d = EmailTemplateDesigner.FromJson(model.DesignJson);
            if (d is null) { ModelState.AddModelError("", "The design could not be read. Reload the page and try again."); return null; }
            html = EmailTemplateDesigner.Build(d);
            model.DesignJson = EmailTemplateDesigner.ToJson(d);
            if (string.IsNullOrWhiteSpace(html)) { ModelState.AddModelError("", "The email is empty. Add a heading or a message."); return null; }
        }
        var unknown = EmailTemplateDesigner.UnknownFields(model.Subject + " " + html, type);
        if (unknown.Count > 0)
            ModelState.AddModelError("", $"These fields are not filled for the {type.Name} email: {string.Join(", ", unknown.Select(u => "{{" + u + "}}"))}. Use \"Insert field\" to pick one.");
        return ModelState.IsValid ? html : null;
    }

    private static Dictionary<string, string?> WithHospital(Dictionary<string, string?> values, string hospital, bool asNames, bool html)
    {
        if (!asNames && !string.IsNullOrWhiteSpace(hospital)) values["HospitalName"] = html ? System.Net.WebUtility.HtmlEncode(hospital) : hospital;
        return values;
    }

    private async Task<string> HospitalNameAsync() =>
        (await dbContext.HospitalSettings.Where(h => h.BranchId == BranchId).Select(h => h.HospitalName).FirstOrDefaultAsync())?.Trim() ?? "";

    private async Task<List<string>> MissingTypesAsync()
    {
        var have = await dbContext.EmailTemplates.Where(t => t.BranchId == BranchId).Select(t => t.TemplateName).ToListAsync();
        return EmailTemplateDesigner.Types.Select(t => t.Name)
            .Where(n => have.All(x => !string.Equals(x, n, StringComparison.OrdinalIgnoreCase))).ToList();
    }
}
