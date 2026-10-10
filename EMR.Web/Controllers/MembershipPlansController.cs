using System.Text.Json;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Master > General > Membership Plan Master: the plans a membership card can be issued on (company-wide).</summary>
[Authorize]
public class MembershipPlansController(
    IMembershipApiClient apiClient,
    IAuditLogService auditLogService) : Controller
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    [HttpGet]
    public async Task<IActionResult> Index(bool? status = null, string? search = null)
    {
        var model = new MembershipPlanIndexViewModel { SelectedStatus = status, SearchTerm = search };
        try
        {
            model.Plans = await apiClient.GetPlansAsync(User.GetCompanyId(), status, search);
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to load membership plans. " + ex.Message;
        }
        return View(model);
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var model = new MembershipPlanFormViewModel { IsActive = true };
        await LoadScopesAsync(model);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> Create(MembershipPlanFormViewModel model) => SaveAsync(model, isNew: true);

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        try
        {
            var model = await apiClient.GetPlanAsync(id, User.GetCompanyId());
            if (model == null) return NotFound();
            await LoadScopesAsync(model);
            return View(model);
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to load the membership plan. " + ex.Message;
            return RedirectToAction(nameof(Index));
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> Edit(int id, MembershipPlanFormViewModel model)
    {
        if (id != model.PlanId) return Task.FromResult<IActionResult>(BadRequest());
        return SaveAsync(model, isNew: false);
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        try
        {
            var model = await apiClient.GetPlanAsync(id, User.GetCompanyId());
            if (model == null) return NotFound();
            return View(model);
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to load the membership plan. " + ex.Message;
            return RedirectToAction(nameof(Index));
        }
    }

    [HttpPost, ActionName("Delete")]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> DeleteConfirmed(int id)
    {
        try
        {
            var companyId = User.GetCompanyId();
            var plan = await apiClient.GetPlanAsync(id, companyId);
            if (plan != null)
            {
                bool removed = await apiClient.DeletePlanAsync(id, companyId, User.GetUserId());
                await auditLogService.LogAsync("Membership Plan Master", removed ? "Delete" : "Deactivate",
                    $"{(removed ? "Deleted" : "Deactivated")} membership plan: {plan.PlanCode} {plan.PlanName}");
                TempData["Success"] = removed
                    ? "Membership plan deleted."
                    : "This plan has issued cards, so it was deactivated instead of deleted.";
            }
        }
        catch (MembershipApiException ex)
        {
            TempData["Error"] = ex.Message;
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to delete the membership plan. " + ex.Message;
        }
        return RedirectToAction(nameof(Index));
    }

    private async Task<IActionResult> SaveAsync(MembershipPlanFormViewModel model, bool isNew)
    {
        string view = isNew ? nameof(Create) : nameof(Edit);
        model.Benefits = ParseBenefits(model.BenefitsJson);
        if (model.PlanType is "Individual" or "Senior") model.MaxMembers = 1;
        if (model.PlanType is "Family" or "Corporate" && model.MaxMembers < 2)
            ModelState.AddModelError(nameof(model.MaxMembers), "A family or corporate plan needs at least 2 members.");

        if (ModelState.IsValid)
        {
            try
            {
                int id = await apiClient.SavePlanAsync(model, User.GetCompanyId(), User.GetUserId());
                await auditLogService.LogAsync("Membership Plan Master", isNew ? "Create" : "Update",
                    $"{(isNew ? "Created" : "Updated")} membership plan: {model.PlanName} (#{id})");
                TempData["Success"] = isNew ? "Membership plan created successfully!" : "Membership plan updated successfully!";
                return RedirectToAction(nameof(Index));
            }
            catch (MembershipApiException ex)
            {
                ModelState.AddModelError(string.Empty, ex.Message);
            }
            catch (Exception ex)
            {
                ModelState.AddModelError(string.Empty, "Failed to save the membership plan. " + ex.Message);
            }
        }

        await LoadScopesAsync(model);
        return View(view, model);
    }

    private async Task LoadScopesAsync(MembershipPlanFormViewModel model)
    {
        try
        {
            model.Scopes = await apiClient.GetBenefitScopesAsync(User.GetCompanyId());
        }
        catch (Exception)
        {
            model.Scopes = new MembershipBenefitScopesViewModel();
        }
    }

    private static List<MembershipBenefitViewModel> ParseBenefits(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return [];
        try
        {
            return JsonSerializer.Deserialize<List<MembershipBenefitViewModel>>(json, JsonOptions) ?? [];
        }
        catch (JsonException)
        {
            return [];
        }
    }
}
