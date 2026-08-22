using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Controllers;

[Authorize]
public class CorporatesController(
    ICorporateApiClient corporateApiClient,
    ICorporateService corporateService,
    IAuditLogService auditLogService) : Controller
{
    private static readonly List<string> CorporateTypes = ["IPD", "OPD", "LAB", "MED", "GENERAL", "ALL"];
    private static readonly List<string> BillingCycles = ["Monthly", "Daily", "Yearly", "Bi-Monthly", "Half-Yearly"];

    [HttpGet]
    public async Task<IActionResult> Index(string? type = null, bool? status = null, string? search = null)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        try
        {
            var list = (await corporateApiClient.GetListAsync(branchId, type, status, search, companyId)).ToList();

            var model = new CorporateIndexViewModel
            {
                Corporates = list,
                SelectedBranchId = branchId,
                SelectedType = type,
                SelectedStatus = status,
                SearchTerm = search,
                TypeOptions = CorporateTypes.Select(t => new SelectListItem
                {
                    Value = t,
                    Text = t,
                    Selected = string.Equals(t, type, StringComparison.OrdinalIgnoreCase)
                }).ToList(),
                StatusOptions = new List<SelectListItem>
                {
                    new() { Value = "true", Text = "Active Only", Selected = status == true },
                    new() { Value = "false", Text = "Inactive Only", Selected = status == false }
                }
            };

            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Corporate Master";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public IActionResult Create()
    {
        var model = new CorporateFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            Branch_ID = User.GetCurrentBranchId() ?? 1,
            Effective_From = DateTime.Today,
            Effective_To = DateTime.Today.AddYears(1),
            Corporate_Type = "ALL",
            BillingCycle = "Monthly",
            Status = true,
            CorporateTypeOptions = GetTypeSelectList(),
            BillingCycleOptions = GetBillingCycleSelectList()
        };

        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(CorporateFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        model.CompanyId = companyId;
        model.Branch_ID = branchId;

        if (model.Effective_To < model.Effective_From)
        {
            ModelState.AddModelError(nameof(model.Effective_To), "Effective To date cannot be earlier than Effective From date.");
        }

        if (await corporateService.NameExistsAsync(model.Corporate_Name, branchId: branchId))
        {
            ModelState.AddModelError(nameof(model.Corporate_Name), "A Corporate with this name already exists in this branch.");
        }

        if (!ModelState.IsValid)
        {
            model.CorporateTypeOptions = GetTypeSelectList(model.Corporate_Type);
            model.BillingCycleOptions = GetBillingCycleSelectList(model.BillingCycle);
            return View(model);
        }

        try
        {
            var newId = await corporateApiClient.CreateAsync(model, User.GetUserId());

            await auditLogService.LogAsync("MasterData", "Corporate.Create",
                $"Created Corporate: {model.Corporate_Name} ({model.Corporate_Code}) [{model.Corporate_Type}] - Contact: {model.Contact_No} [ID: {newId}]",
                branchId: branchId);

            TempData["Success"] = $"Corporate '{model.Corporate_Name}' created successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (Exception ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.CorporateTypeOptions = GetTypeSelectList(model.Corporate_Type);
            model.BillingCycleOptions = GetBillingCycleSelectList(model.BillingCycle);
            return View(model);
        }
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        try
        {
            var entity = await corporateApiClient.GetByIdAsync(id);
            if (entity is null) return NotFound();

            var model = new CorporateFormViewModel
            {
                Corporate_ID = entity.Corporate_ID,
                CompanyId = entity.CompanyId,
                Branch_ID = entity.Branch_ID,
                Corporate_Code = entity.Corporate_Code,
                Corporate_Name = entity.Corporate_Name,
                Corporate_Type = entity.Corporate_Type,
                Effective_From = entity.Effective_From,
                Effective_To = entity.Effective_To,
                Credit_Limit = entity.Credit_Limit,
                Credit_Days = entity.Credit_Days,
                BillingCycle = entity.BillingCycle,
                Contact_No = entity.Contact_No,
                Email = entity.Email,
                Address = entity.Address,
                Pincode = entity.Pincode,
                Status = entity.Status,
                CorporateTypeOptions = GetTypeSelectList(entity.Corporate_Type),
                BillingCycleOptions = GetBillingCycleSelectList(entity.BillingCycle)
            };

            return View(model);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Corporate Master";
            return View("ApiDown");
        }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, CorporateFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? model.Branch_ID ?? 1;
        model.Corporate_ID = id;
        model.CompanyId = companyId;
        model.Branch_ID = branchId;

        if (model.Effective_To < model.Effective_From)
        {
            ModelState.AddModelError(nameof(model.Effective_To), "Effective To date cannot be earlier than Effective From date.");
        }

        if (await corporateService.NameExistsAsync(model.Corporate_Name, excludeId: id, branchId: branchId))
        {
            ModelState.AddModelError(nameof(model.Corporate_Name), "A Corporate with this name already exists in this branch.");
        }

        if (!ModelState.IsValid)
        {
            model.CorporateTypeOptions = GetTypeSelectList(model.Corporate_Type);
            model.BillingCycleOptions = GetBillingCycleSelectList(model.BillingCycle);
            return View(model);
        }

        try
        {
            await corporateApiClient.UpdateAsync(id, model, User.GetUserId());

            await auditLogService.LogAsync("MasterData", "Corporate.Edit",
                $"Updated Corporate: {model.Corporate_Name} ({model.Corporate_Code}) [{model.Corporate_Type}] - Contact: {model.Contact_No} [ID: {id}]",
                branchId: branchId);

            TempData["Success"] = $"Corporate '{model.Corporate_Name}' updated successfully.";
            return RedirectToAction(nameof(Index));
        }
        catch (Exception ex)
        {
            ModelState.AddModelError(string.Empty, ex.Message);
            model.CorporateTypeOptions = GetTypeSelectList(model.Corporate_Type);
            model.BillingCycleOptions = GetBillingCycleSelectList(model.BillingCycle);
            return View(model);
        }
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        try
        {
            var entity = await corporateApiClient.GetByIdAsync(id);
            if (entity is null) return NotFound();

            return View(entity);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Corporate Master";
            return View("ApiDown");
        }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        try
        {
            await corporateApiClient.ToggleStatusAsync(id, User.GetUserId());

            await auditLogService.LogAsync("MasterData", "Corporate.ToggleStatus",
                $"Toggled active status for Corporate [ID: {id}]",
                branchId: branchId);

            TempData["Success"] = "Corporate status updated successfully.";
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to update status: " + ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        try
        {
            await corporateApiClient.DeleteAsync(id, User.GetUserId());

            await auditLogService.LogAsync("MasterData", "Corporate.Delete",
                $"Deleted Corporate record [ID: {id}]",
                branchId: branchId);

            TempData["Success"] = "Corporate record deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to delete corporate record: " + ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> GetCorporateJson(int id)
    {
        var item = await corporateApiClient.GetByIdAsync(id);
        if (item is null) return NotFound();
        return Json(item);
    }

    private static List<SelectListItem> GetTypeSelectList(string? selected = null) =>
        CorporateTypes.Select(t => new SelectListItem
        {
            Value = t,
            Text = t,
            Selected = string.Equals(t, selected, StringComparison.OrdinalIgnoreCase)
        }).ToList();

    private static List<SelectListItem> GetBillingCycleSelectList(string? selected = null) =>
        BillingCycles.Select(b => new SelectListItem
        {
            Value = b,
            Text = b,
            Selected = string.Equals(b, selected, StringComparison.OrdinalIgnoreCase)
        }).ToList();
}
