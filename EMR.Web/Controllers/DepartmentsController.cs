using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class DepartmentsController(IDepartmentService departmentService, IAuditLogService auditLogService) : Controller
{
    // ── Dept Type options (hardcoded) ──────────────────────────────────────
    private static readonly List<string> DeptTypes = ["OPD", "IPD", "Lab", "Med"];

    public async Task<IActionResult> Index()
    {
        var list = await departmentService.GetAllAsync();
        return View(list);
    }

    [HttpGet]
    public IActionResult Create()
    {
        ViewBag.DeptTypes = DeptTypes;
        return View(new DepartmentFormViewModel());
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(DepartmentFormViewModel model)
    {
        if (await departmentService.CodeExistsAsync(model.DeptCode.Trim().ToUpper()))
            ModelState.AddModelError(nameof(model.DeptCode), "This Department Code already exists.");

        if (!ModelState.IsValid)
        {
            ViewBag.DeptTypes = DeptTypes;
            return View(model);
        }

        await departmentService.CreateAsync(new DepartmentMaster
        {
            DeptCode = model.DeptCode.Trim().ToUpper(),
            DeptName = model.DeptName.Trim(),
            DeptType = model.DeptType,
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Departments.Create", $"Created department: {model.DeptCode.Trim().ToUpper()} - {model.DeptName.Trim()} ({model.DeptType})");
        TempData["Success"] = "Department created successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var entity = await departmentService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        ViewBag.DeptTypes = DeptTypes;
        return View(new DepartmentFormViewModel
        {
            DeptId   = entity.DeptId,
            DeptCode = entity.DeptCode,
            DeptName = entity.DeptName,
            DeptType = entity.DeptType,
            IsActive = entity.IsActive
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(DepartmentFormViewModel model)
    {
        if (await departmentService.CodeExistsAsync(model.DeptCode.Trim().ToUpper(), model.DeptId))
            ModelState.AddModelError(nameof(model.DeptCode), "This Department Code already exists.");

        if (!ModelState.IsValid)
        {
            ViewBag.DeptTypes = DeptTypes;
            return View(model);
        }

        await departmentService.UpdateAsync(new DepartmentMaster
        {
            DeptId   = model.DeptId,
            DeptCode = model.DeptCode.Trim().ToUpper(),
            DeptName = model.DeptName.Trim(),
            DeptType = model.DeptType,
            IsActive = model.IsActive
        }, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Departments.Edit", $"Updated department: {model.DeptCode.Trim().ToUpper()} - {model.DeptName.Trim()} ({model.DeptType})");
        TempData["Success"] = "Department updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var entity = await departmentService.GetByIdAsync(id);
        if (entity is null) return NotFound();
        return View(entity);
    }
}
