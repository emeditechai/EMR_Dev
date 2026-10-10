using System.Text.Json;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Master > General > Membership Cards: issue a card (fee + ledger posted by the API in one transaction),
/// print it, and send the soft copy by WhatsApp / email as switched on in Hospital Settings.
/// </summary>
[Authorize]
public class MembershipCardsController(
    IMembershipApiClient apiClient,
    IMembershipCardDeliveryService deliveryService,
    IPaymentService paymentService,
    IAuditLogService auditLogService) : Controller
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    [HttpGet]
    public async Task<IActionResult> Index(int? planId = null, string? status = null, string? search = null, DateTime? fromDate = null, DateTime? toDate = null)
    {
        var model = new MembershipCardIndexViewModel { PlanId = planId, Status = status, Search = search, FromDate = fromDate, ToDate = toDate };
        try
        {
            var companyId = User.GetCompanyId();
            model.Plans = await apiClient.GetPlansAsync(companyId);
            model.Cards = await apiClient.GetCardsAsync(companyId, null, planId, status, search, fromDate, toDate);
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to load membership cards. " + ex.Message;
        }
        return View(model);
    }

    [HttpGet]
    public async Task<IActionResult> Issue()
    {
        var model = new MembershipCardIssueViewModel();
        await LoadIssuePageAsync(model);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Issue(MembershipCardIssueViewModel model)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null or <= 0)
            ModelState.AddModelError(string.Empty, "Select a working branch before issuing a card.");

        var members = ParseMembers(model.MembersJson);
        if (ModelState.IsValid)
        {
            try
            {
                var companyId = User.GetCompanyId();
                var result = await apiClient.IssueCardAsync(model, members, companyId, branchId!.Value, User.GetUserId());
                await auditLogService.LogAsync("Membership Cards", "Issue",
                    $"Issued membership card {result.CardNo} (fee ₹{result.FeeAmount:N2}, receipt {result.ReceiptNo ?? "-"})");

                var notes = new List<string> { $"Card {result.CardNo} issued." };
                if (!string.IsNullOrWhiteSpace(result.ReceiptNo)) notes.Add($"Receipt {result.ReceiptNo} for ₹{result.FeeAmount:N2}.");

                // Soft copy on issue, when Hospital Settings says so
                try
                {
                    var channels = await deliveryService.GetChannelsAsync(branchId.Value);
                    if (channels.AutoSendOnIssue && (channels.WhatsApp || channels.Email))
                    {
                        var card = await apiClient.GetCardAsync(result.CardId, companyId);
                        if (card != null)
                            notes.AddRange((await deliveryService.SendAsync(card, branchId.Value)).Select(Describe));
                    }
                }
                catch (Exception ex)
                {
                    notes.Add("The card could not be sent automatically: " + ex.Message);
                }

                TempData["Success"] = string.Join(" ", notes);
                return RedirectToAction(nameof(Details), new { id = result.CardId });
            }
            catch (MembershipApiException ex)
            {
                ModelState.AddModelError(string.Empty, ex.Message);
            }
            catch (Exception ex)
            {
                ModelState.AddModelError(string.Empty, "Failed to issue the card. " + ex.Message);
            }
        }

        await LoadIssuePageAsync(model);
        return View(model);
    }

    /// <summary>Patient lookup for the issue form and the Add member dialog (code, name or mobile).</summary>
    [HttpGet]
    public async Task<IActionResult> PatientSearch(string? term)
    {
        if (string.IsNullOrWhiteSpace(term) || term.Trim().Length < 2) return Json(Array.Empty<object>());
        try
        {
            return Json(await apiClient.SearchPatientsAsync(User.GetCompanyId(), term.Trim()));
        }
        catch (Exception)
        {
            return Json(Array.Empty<object>());
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        try
        {
            var card = await apiClient.GetCardAsync(id, User.GetCompanyId());
            if (card == null) return NotFound();

            var channels = await deliveryService.GetChannelsAsync(User.GetCurrentBranchId() ?? card.IssueBranchId);
            card.WhatsAppEnabled = channels.WhatsApp;
            card.EmailEnabled = channels.Email;
            return View(card);
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to load the membership card. " + ex.Message;
            return RedirectToAction(nameof(Index));
        }
    }

    /// <summary>The card PDF, shown inline for printing (each open counts as a print) or downloaded with download=true.</summary>
    [HttpGet]
    public async Task<IActionResult> Card(int id, bool download = false)
    {
        var companyId = User.GetCompanyId();
        var card = await apiClient.GetCardAsync(id, companyId);
        if (card == null) return NotFound();

        var pdf = await deliveryService.BuildPdfAsync(card, User.GetCurrentBranchId() ?? card.IssueBranchId);
        if (!download)
        {
            await apiClient.MarkPrintedAsync(id, companyId, User.GetUserId());
            await auditLogService.LogAsync("Membership Cards", "Print", $"Printed membership card {card.CardNo}");
        }

        var fileName = $"Membership_Card_{card.CardNo}.pdf";
        if (download) return File(pdf, "application/pdf", fileName);
        Response.Headers.ContentDisposition = $"inline; filename=\"{fileName}\"";
        return File(pdf, "application/pdf");
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Send(int id)
    {
        try
        {
            var card = await apiClient.GetCardAsync(id, User.GetCompanyId());
            if (card == null) return NotFound();

            var outcomes = await deliveryService.SendAsync(card, User.GetCurrentBranchId() ?? card.IssueBranchId);
            await auditLogService.LogAsync("Membership Cards", "Send",
                $"Sent membership card {card.CardNo}: {string.Join("; ", outcomes.Select(o => $"{o.Channel} {o.Status}"))}");

            var text = string.Join(" ", outcomes.Select(Describe));
            if (outcomes.Any(o => o.Status == "Sent")) TempData["Success"] = text;
            else TempData["Error"] = text;
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to send the card. " + ex.Message;
        }
        return RedirectToAction(nameof(Details), new { id });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> AddMember(int id, int patientId, string? relation)
    {
        try
        {
            if (patientId <= 0) throw new MembershipApiException("Select the patient to add.");
            var branchId = User.GetCurrentBranchId() ?? 0;
            await apiClient.AddMemberAsync(id, User.GetCompanyId(), branchId, patientId, relation, User.GetUserId());
            await auditLogService.LogAsync("Membership Cards", "Add Member", $"Added patient #{patientId} ({relation}) to membership card #{id}");
            TempData["Success"] = "Member added. Print or send the card again so the new member is on it.";
        }
        catch (MembershipApiException ex)
        {
            TempData["Error"] = ex.Message;
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to add the member. " + ex.Message;
        }
        return RedirectToAction(nameof(Details), new { id });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SetStatus(int id, string status, string? reason)
    {
        try
        {
            var branchId = User.GetCurrentBranchId() ?? 0;
            await apiClient.SetCardStatusAsync(id, User.GetCompanyId(), branchId, status, reason, User.GetUserId());
            await auditLogService.LogAsync("Membership Cards", "Status", $"Membership card #{id} set to {status}. {reason}");
            TempData["Success"] = $"Card is now {status}.";
        }
        catch (MembershipApiException ex)
        {
            TempData["Error"] = ex.Message;
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to change the card status. " + ex.Message;
        }
        return RedirectToAction(nameof(Details), new { id });
    }

    private async Task LoadIssuePageAsync(MembershipCardIssueViewModel model)
    {
        try
        {
            model.Plans = await apiClient.GetPlansAsync(User.GetCompanyId(), status: true);
            model.PaymentMethods = (await paymentService.GetActiveMethodsAsync()).ToList();
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to load plans or payment methods. " + ex.Message;
        }
    }

    private static List<MembershipCardMemberInput> ParseMembers(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return [];
        try
        {
            return (JsonSerializer.Deserialize<List<MembershipCardMemberInput>>(json, JsonOptions) ?? [])
                .Where(m => m.PatientId > 0).ToList();
        }
        catch (JsonException)
        {
            return [];
        }
    }

    private static string Describe(MembershipCardSendOutcome o) => $"{o.Channel}: {o.Status.ToLowerInvariant()} - {o.Message}";
}
