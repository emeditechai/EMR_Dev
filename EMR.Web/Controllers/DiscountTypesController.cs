using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class DiscountTypesController(
    IDiscountTypeApiClient apiClient,
    IDiscountTypeService dbService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(bool? status = null, string? search = null)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        try
        {
            var list = await apiClient.GetListAsync(branchId, status, search, companyId);
            
            var model = new DiscountTypeIndexViewModel
            {
                DiscountTypes = list.ToList(),
                SelectedStatus = status,
                SearchTerm = search
            };
            
            return View(model);
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to load discount types. " + ex.Message;
            return View(new DiscountTypeIndexViewModel());
        }
    }

    [HttpGet]
    public IActionResult Create()
    {
        return View(new DiscountTypeFormViewModel { IsActive = true });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(DiscountTypeFormViewModel model)
    {
        if (ModelState.IsValid)
        {
            try
            {
                var companyId = User.GetCompanyId();
                var branchId = User.GetCurrentBranchId();
                var userId = User.GetUserId();
                
                if (await dbService.NameExistsAsync(model.DiscountTypeName, companyId: companyId))
                {
                    ModelState.AddModelError("DiscountTypeName", "A discount type with this name already exists.");
                    return View(model);
                }

                await apiClient.CreateAsync(model, userId, companyId, branchId);
                await auditLogService.LogAsync("DiscountType Master", "Create", $"Created DiscountType: {model.DiscountTypeName}");
                
                TempData["Success"] = "Discount Type created successfully!";
                return RedirectToAction(nameof(Index));
            }
            catch (Exception ex)
            {
                ModelState.AddModelError("", "Failed to create discount type. " + ex.Message);
            }
        }
        return View(model);
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        try
        {
            var model = await apiClient.GetByIdAsync(id);
            if (model == null) return NotFound();
            
            return View(model);
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to load discount type for editing. " + ex.Message;
            return RedirectToAction(nameof(Index));
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, DiscountTypeFormViewModel model)
    {
        if (id != model.DiscountTypeId) return BadRequest();

        if (ModelState.IsValid)
        {
            try
            {
                var companyId = User.GetCompanyId();
                var branchId = User.GetCurrentBranchId();
                var userId = User.GetUserId();
                
                if (await dbService.NameExistsAsync(model.DiscountTypeName, model.DiscountTypeId, companyId))
                {
                    ModelState.AddModelError("DiscountTypeName", "A discount type with this name already exists.");
                    return View(model);
                }

                await apiClient.UpdateAsync(model, userId, companyId, branchId);
                await auditLogService.LogAsync("DiscountType Master", "Update", $"Updated DiscountType: {model.DiscountTypeName}");
                
                TempData["Success"] = "Discount Type updated successfully!";
                return RedirectToAction(nameof(Index));
            }
            catch (Exception ex)
            {
                ModelState.AddModelError("", "Failed to update discount type. " + ex.Message);
            }
        }
        return View(model);
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        try
        {
            var model = await apiClient.GetByIdAsync(id);
            if (model == null) return NotFound();
            
            return View(model);
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to load discount type details. " + ex.Message;
            return RedirectToAction(nameof(Index));
        }
    }

    [HttpPost, ActionName("Delete")]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> DeleteConfirmed(int id)
    {
        try
        {
            var item = await apiClient.GetByIdAsync(id);
            if (item != null)
            {
                await apiClient.DeleteAsync(id);
                await auditLogService.LogAsync("DiscountType Master", "Delete", $"Deleted DiscountType: {item.DiscountTypeName}");
                TempData["Success"] = "Discount Type deleted successfully!";
            }
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to delete discount type. " + ex.Message;
        }
        
        return RedirectToAction(nameof(Index));
    }

    [AcceptVerbs("GET", "POST")]
    public async Task<IActionResult> VerifyName(string discountTypeName, int discountTypeId)
    {
        var companyId = User.GetCompanyId();
        var exists = await dbService.NameExistsAsync(discountTypeName, discountTypeId == 0 ? null : discountTypeId, companyId);
        if (exists)
            return Json($"A discount type named '{discountTypeName}' already exists.");
        
        return Json(true);
    }
}
