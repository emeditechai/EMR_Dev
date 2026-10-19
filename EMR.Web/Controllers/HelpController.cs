using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Utility > Help Center (SQLScripts/2300): the user guide of the whole application for every signed-in user -
/// modules with their setup order, step-by-step guides, FAQs, troubleshooting, help for every page (also from the ?
/// button in the top bar) and the Help Assistant. Data comes from EMR.Api api/help (usp_Help_* procedures).
/// </summary>
[Authorize]
[EMR.Shared.Security.PublicEndpoint]   // help is for everyone who is signed in, whatever their role
public class HelpController(IHelpApiClient api, EMR.Web.Services.IAskAiFeatures askAi) : Controller
{
    private int CompanyId => User.GetCompanyId();
    /// <summary>Hospital Settings > LAB > Enable Ask AI Features (SQLScripts/2302): the assistant on the help pages.</summary>
    private async Task SetAskAiAsync() => ViewBag.AskAi = await askAi.IsEnabledAsync(HttpContext);

    private bool IsAdmin => User.HasClaim("IsSuperAdmin", "true") || User.IsInRole("SuperAdmin") || User.IsInRole("Administrator");

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        ViewBag.IsAdmin = IsAdmin;
        await SetAskAiAsync();
        return View(await api.HomeAsync(CompanyId));
    }

    [HttpGet]
    public async Task<IActionResult> Module(string id)
    {
        var m = await api.ModuleAsync(CompanyId, id ?? "");
        if (m is null) return RedirectToAction(nameof(Index));
        ViewBag.Modules = (await api.HomeAsync(CompanyId)).Modules;
        await SetAskAiAsync();
        return View(m);
    }

    [HttpGet]
    public async Task<IActionResult> Article(string id)
    {
        var a = await api.ArticleAsync(CompanyId, id ?? "");
        if (a is null) return RedirectToAction(nameof(Index));
        ViewBag.Modules = (await api.HomeAsync(CompanyId)).Modules;
        await SetAskAiAsync();
        return View(a);
    }

    /// <summary>Help for one page (by page code).</summary>
    [HttpGet]
    public async Task<IActionResult> Page(string id)
    {
        var p = await api.PageAsync(CompanyId, id, null, null);
        if (p is null) return RedirectToAction(nameof(Index));
        ViewBag.Modules = (await api.HomeAsync(CompanyId)).Modules;
        await SetAskAiAsync();
        return View(p);
    }

    /// <summary>Help for the screen the user is on (the Ask AI drawer), by its controller / action.</summary>
    [HttpGet]
    public async Task<IActionResult> ForScreen(string? screen, string? view) =>   // not "controller"/"action": those are route values
        await api.PageAsync(CompanyId, null, screen, view) is { } p ? Json(new { found = true, page = p }) : Json(new { found = false });

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Ask(string question, string? pageCode)
    {
        if (!await askAi.IsEnabledAsync(HttpContext))
            return Json(new { found = false, text = "Ask AI is switched off for this branch (Hospital Settings > LAB > Enable Ask AI Features)." });
        if (string.IsNullOrWhiteSpace(question)) return Json(new { found = false, text = "Type a question." });
        return Json(await api.AskAsync(new HelpAskRequest { CompanyId = CompanyId, UserId = User.GetUserId(), Question = question.Trim(), PageCode = pageCode }));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Feedback(string? articleCode, string? pageCode, string? question, bool? helpful, string? comment,
                                              string? kind, string? intent, string? signal)
    {
        // a vote ("Did this answer your question?") or a related topic opened from an answer (signal CLICK): the assistant learns from both
        await api.FeedbackAsync(new HelpFeedbackRequest
        {
            CompanyId = CompanyId, UserId = User.GetUserId(), ArticleCode = articleCode, PageCode = string.IsNullOrWhiteSpace(pageCode) ? null : pageCode,
            Question = question, Helpful = signal == "CLICK" ? null : helpful ?? false, Comment = comment, Kind = kind, Intent = intent,
            Signal = signal == "CLICK" ? "CLICK" : null
        });
        return Json(new { saved = true });
    }

    /// <summary>For administrators: questions the assistant could not answer and topics marked not helpful.</summary>
    [HttpGet]
    public async Task<IActionResult> Insights()
    {
        if (!IsAdmin) return RedirectToAction(nameof(Index));
        ViewBag.Stats = await api.LearningStatsAsync(CompanyId);
        return View(await api.FeedbackListAsync(CompanyId));
    }

    /// <summary>For administrators: teach the assistant the right topic for a question it answered wrongly or not at all.</summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Teach(string question, string targetCode, string? intent)
    {
        if (!IsAdmin) return Forbid();
        if (string.IsNullOrWhiteSpace(question) || string.IsNullOrWhiteSpace(targetCode)) return Json(new { saved = false, message = "Choose the right topic." });
        await api.TeachAsync(new HelpTeachRequest { CompanyId = CompanyId, UserId = User.GetUserId(), Question = question.Trim(), TargetCode = targetCode, Intent = intent });
        return Json(new { saved = true });
    }

    /// <summary>For administrators: make the assistant forget a learned answer.</summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Forget(int id)
    {
        if (!IsAdmin) return Forbid();
        await api.ForgetAsync(CompanyId, id, User.GetUserId());
        return Json(new { saved = true });
    }
}
