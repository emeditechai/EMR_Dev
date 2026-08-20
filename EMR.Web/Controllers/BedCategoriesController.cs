using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class BedCategoriesController(
    IBedCategoryService bedCategoryService,
    IIpdMasterApiClient ipdMasterApiClient,
    IAuditLogService auditLogService) : Controller
{
    public async Task<IActionResult> Index()
    {
        try
        {
            var companyId = User.GetCompanyId();
            var branchId = User.GetCurrentBranchId();
            var list = await ipdMasterApiClient.GetBedCategoriesAsync(companyId, branchId);
            return View(list);
        }
        catch (HttpRequestException)
        {
            ViewData["PageName"] = "Bed Category Master List";
            return View("ApiDown");
        }
    }

    [HttpGet]
    public IActionResult Create()
    {
        return View(new BedCategoryFormViewModel
        {
            CompanyId = User.GetCompanyId(),
            BranchId = User.GetCurrentBranchId()
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(BedCategoryFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId();
        model.CategoryName = model.CategoryName.Trim();
        model.CategoryCode = model.CategoryCode?.Trim().ToUpper();

        if (await bedCategoryService.NameExistsAsync(model.CategoryName, companyId: companyId))
            ModelState.AddModelError(nameof(model.CategoryName), "This Bed Category Name already exists.");

        if (!ModelState.IsValid)
            return View(model);

        var newId = await bedCategoryService.CreateAsync(new BedCategoryMaster
        {
            CompanyId = companyId,
            BranchId = model.BranchId ?? branchId,
            CategoryCode = model.CategoryCode,
            CategoryName = model.CategoryName,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "BedCategories.Create",
            $"Created bed category: {model.CategoryName}",
            branchId: model.BranchId);

        TempData["Success"] = "Bed Category created successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var entity = await bedCategoryService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        return View(new BedCategoryFormViewModel
        {
            BedCategoryId = entity.BedCategoryId,
            CompanyId = entity.CompanyId,
            BranchId = entity.BranchId,
            CategoryCode = entity.CategoryCode,
            CategoryName = entity.CategoryName,
            Description = entity.Description,
            IsActive = entity.IsActive
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(BedCategoryFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId();
        model.CategoryName = model.CategoryName.Trim();
        model.CategoryCode = model.CategoryCode?.Trim().ToUpper();

        if (await bedCategoryService.NameExistsAsync(model.CategoryName, excludeId: model.BedCategoryId, companyId: companyId))
            ModelState.AddModelError(nameof(model.CategoryName), "This Bed Category Name already exists.");

        if (!ModelState.IsValid)
            return View(model);

        await bedCategoryService.UpdateAsync(new BedCategoryMaster
        {
            BedCategoryId = model.BedCategoryId,
            CategoryCode = model.CategoryCode,
            CategoryName = model.CategoryName,
            Description = model.Description?.Trim(),
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "BedCategories.Edit",
            $"Updated bed category: {model.CategoryName}",
            branchId: model.BranchId);

        TempData["Success"] = "Bed Category updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var details = await bedCategoryService.GetDetailsByIdAsync(id);
        if (details is null) return NotFound();
        return View(details);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var deleted = await bedCategoryService.DeleteAsync(id);
        TempData[deleted ? "Success" : "Error"] = deleted
            ? "Bed Category deleted successfully."
            : "Cannot delete this Bed Category.";
        return RedirectToAction(nameof(Index));
    }
}
