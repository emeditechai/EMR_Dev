using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class TariffCategoriesController(
    ITariffCategoryService tariffCategoryService,
    IIpdMasterApiClient ipdMasterApiClient,
    IAuditLogService auditLogService) : Controller
{
    public async Task<IActionResult> Index(string? patientCategory = null)
    {
        try
        {
            var companyId = User.GetCompanyId();
            var branchId = User.GetCurrentBranchId();
            var list = await ipdMasterApiClient.GetTariffCategoriesAsync(patientCategory, companyId, branchId);

            ViewBag.SelectedCategory = patientCategory;
            ViewBag.PatientCategoryOptions = tariffCategoryService.GetPatientCategoryOptions(patientCategory);

            return View(list);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Tariff Category Master List";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public IActionResult Create()
    {
        return View(new TariffCategoryFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            BranchId = User.GetCurrentBranchId(),
            PatientCategoryOptions = tariffCategoryService.GetPatientCategoryOptions()
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(TariffCategoryFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId();
        model.Code = model.Code.Trim().ToUpper();
        model.Name = model.Name.Trim();

        if (await tariffCategoryService.CodeExistsAsync(model.Code, companyId: companyId))
            ModelState.AddModelError(nameof(model.Code), "This Tariff Code already exists in the company.");

        if (await tariffCategoryService.NameExistsAsync(model.Name, companyId: companyId))
            ModelState.AddModelError(nameof(model.Name), "This Tariff Category Name already exists.");

        if (!ModelState.IsValid)
        {
            model.PatientCategoryOptions = tariffCategoryService.GetPatientCategoryOptions(model.PatientCategory);
            return View(model);
        }

        var newId = await tariffCategoryService.CreateAsync(new TariffCategoryMaster
        {
            CompanyId = companyId,
            BranchId = model.BranchId ?? branchId,
            Code = model.Code,
            Name = model.Name,
            PatientCategory = model.PatientCategory,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "TariffCategories.Create",
            $"Created tariff category: {model.Name} ({model.Code})",
            branchId: model.BranchId);

        TempData["Success"] = "Tariff Category created successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var entity = await tariffCategoryService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        return View(new TariffCategoryFormViewModel
        {
            TariffCategoryId = entity.TariffCategoryId,
            CompanyId = entity.CompanyId,
            BranchId = entity.BranchId,
            Code = entity.Code,
            Name = entity.Name,
            PatientCategory = entity.PatientCategory,
            Description = entity.Description,
            IsActive = entity.IsActive,
            PatientCategoryOptions = tariffCategoryService.GetPatientCategoryOptions(entity.PatientCategory)
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(TariffCategoryFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId();
        model.Code = model.Code.Trim().ToUpper();
        model.Name = model.Name.Trim();

        if (await tariffCategoryService.CodeExistsAsync(model.Code, excludeId: model.TariffCategoryId, companyId: companyId))
            ModelState.AddModelError(nameof(model.Code), "This Tariff Code already exists in the company.");

        if (await tariffCategoryService.NameExistsAsync(model.Name, excludeId: model.TariffCategoryId, companyId: companyId))
            ModelState.AddModelError(nameof(model.Name), "This Tariff Category Name already exists.");

        if (!ModelState.IsValid)
        {
            model.PatientCategoryOptions = tariffCategoryService.GetPatientCategoryOptions(model.PatientCategory);
            return View(model);
        }

        await tariffCategoryService.UpdateAsync(new TariffCategoryMaster
        {
            TariffCategoryId = model.TariffCategoryId,
            Code = model.Code,
            Name = model.Name,
            PatientCategory = model.PatientCategory,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "TariffCategories.Edit",
            $"Updated tariff category: {model.Name} ({model.Code})",
            branchId: model.BranchId);

        TempData["Success"] = "Tariff Category updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var details = await tariffCategoryService.GetDetailsByIdAsync(id);
        if (details is null) return NotFound();
        return View(details);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var deleted = await tariffCategoryService.DeleteAsync(id);
        TempData[deleted ? "Success" : "Error"] = deleted
            ? "Tariff Category deleted successfully."
            : "Cannot delete this Tariff Category.";
        return RedirectToAction(nameof(Index));
    }
}
