using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class ServicesController(IServiceService serviceService, IAuditLogService auditLogService) : Controller
{
    private static readonly List<string> ServiceTypes = ["Consulting", "Service"];

    public async Task<IActionResult> Index()
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return RedirectToAction("Login", "Account");

        var list = await serviceService.GetAllByBranchAsync(branchId.Value);
        return View(list);
    }

    [HttpGet]
    public IActionResult Create()
    {
        if (User.GetCurrentBranchId() is null) return RedirectToAction("Login", "Account");
        ViewBag.ServiceTypes = ServiceTypes;
        return View(new ServiceFormViewModel());
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(ServiceFormViewModel model)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return RedirectToAction("Login", "Account");

        if (!string.IsNullOrWhiteSpace(model.ServiceType) && !ServiceTypes.Contains(model.ServiceType))
            ModelState.AddModelError(nameof(model.ServiceType), "Invalid service type selected.");

        var itemCode = model.ItemCode?.Trim().ToUpperInvariant() ?? string.Empty;
        if (!string.IsNullOrWhiteSpace(itemCode) &&
            await serviceService.ItemCodeExistsAsync(itemCode, branchId.Value))
            ModelState.AddModelError(nameof(model.ItemCode), "This Item Code already exists in the current branch.");

        if (!ModelState.IsValid)
        {
            ViewBag.ServiceTypes = ServiceTypes;
            return View(model);
        }

        await serviceService.CreateAsync(new ServiceMaster
        {
            ItemCode    = itemCode,
            ItemName    = model.ItemName.Trim(),
            ServiceType = model.ServiceType,
            ItemCharges = model.ItemCharges,
            BranchId    = branchId.Value,
            IsActive    = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Services.Create", $"Created service: {itemCode} - {model.ItemName.Trim()} ({model.ServiceType}) ₹{model.ItemCharges}");
        TempData["Success"] = "Service created successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return RedirectToAction("Login", "Account");

        var entity = await serviceService.GetByIdAsync(id, branchId.Value);
        if (entity is null) return NotFound();

        ViewBag.ServiceTypes = ServiceTypes;
        return View(new ServiceFormViewModel
        {
            ServiceId   = entity.ServiceId,
            ItemCode    = entity.ItemCode,
            ItemName    = entity.ItemName,
            ServiceType = entity.ServiceType,
            ItemCharges = entity.ItemCharges,
            IsActive    = entity.IsActive
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(ServiceFormViewModel model)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return RedirectToAction("Login", "Account");

        if (!string.IsNullOrWhiteSpace(model.ServiceType) && !ServiceTypes.Contains(model.ServiceType))
            ModelState.AddModelError(nameof(model.ServiceType), "Invalid service type selected.");

        var itemCode = model.ItemCode?.Trim().ToUpperInvariant() ?? string.Empty;
        if (!string.IsNullOrWhiteSpace(itemCode) &&
            await serviceService.ItemCodeExistsAsync(itemCode, branchId.Value, model.ServiceId))
            ModelState.AddModelError(nameof(model.ItemCode), "This Item Code already exists in the current branch.");

        if (!ModelState.IsValid)
        {
            ViewBag.ServiceTypes = ServiceTypes;
            return View(model);
        }

        await serviceService.UpdateAsync(new ServiceMaster
        {
            ServiceId   = model.ServiceId,
            ItemCode    = itemCode,
            ItemName    = model.ItemName.Trim(),
            ServiceType = model.ServiceType,
            ItemCharges = model.ItemCharges,
            BranchId    = branchId.Value,
            IsActive    = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Services.Edit", $"Updated service: {itemCode} - {model.ItemName.Trim()} ({model.ServiceType}) ₹{model.ItemCharges}");
        TempData["Success"] = "Service updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null) return RedirectToAction("Login", "Account");

        var entity = await serviceService.GetByIdAsync(id, branchId.Value);
        if (entity is null) return NotFound();
        return View(entity);
    }
}
