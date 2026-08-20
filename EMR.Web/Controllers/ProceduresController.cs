using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class ProceduresController(
    IIpdMasterApiClient apiClient,
    IProcedureService procedureService,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(int? departmentId, int? specialityId, string? procedureCategory)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        try
        {
            var list = await apiClient.GetProceduresAsync(branchId, departmentId, specialityId, procedureCategory, companyId);
            ViewBag.DepartmentOptions = await procedureService.GetDepartmentOptionsAsync(departmentId);
            ViewBag.SpecialityOptions = await procedureService.GetSpecialityOptionsAsync(specialityId);
            ViewBag.ProcedureCategoryOptions = procedureService.GetProcedureCategoryOptions(procedureCategory);
            ViewBag.SelectedDepartmentId = departmentId;
            ViewBag.SelectedSpecialityId = specialityId;
            ViewBag.SelectedCategory = procedureCategory;
            return View(list);
        }
        catch (HttpRequestException)
        {
            return View("ApiDown");
        }
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        var model = new ProcedureFormViewModel
        {
            CompanyId = companyId,
            BranchId = branchId,
            DepartmentOptions = await procedureService.GetDepartmentOptionsAsync(),
            SpecialityOptions = await procedureService.GetSpecialityOptionsAsync(),
            ProcedureCategoryOptions = procedureService.GetProcedureCategoryOptions()
        };
        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(ProcedureFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        model.CompanyId = companyId;
        model.BranchId = branchId;

        if (await procedureService.IsCodeExistsAsync(model.ProcedureCode, branchId))
            ModelState.AddModelError(nameof(model.ProcedureCode), "A procedure with this code already exists in your branch.");

        if (model.DurationHours == 0 && model.DurationMinutes == 0 && model.DurationSeconds == 0)
            ModelState.AddModelError(string.Empty, "Please specify an estimated duration (hours or minutes).");

        if (!ModelState.IsValid)
        {
            model.DepartmentOptions = await procedureService.GetDepartmentOptionsAsync(model.DepartmentId);
            model.SpecialityOptions = await procedureService.GetSpecialityOptionsAsync(model.SpecialityId);
            model.ProcedureCategoryOptions = procedureService.GetProcedureCategoryOptions(model.ProcedureCategory);
            return View(model);
        }

        var newId = await procedureService.CreateAsync(model, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Procedures.Create",
            $"Created procedure: {model.ProcedureName} ({model.ProcedureCode}) [ID: {newId}]",
            branchId: branchId);

        TempData["SuccessMessage"] = $"Procedure '{model.ProcedureName}' created successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var model = await procedureService.GetFormModelByIdAsync(id);
        if (model is null) return NotFound();

        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(ProcedureFormViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? model.BranchId;
        model.BranchId = branchId;

        if (await procedureService.IsCodeExistsAsync(model.ProcedureCode, branchId, model.ProcedureId))
            ModelState.AddModelError(nameof(model.ProcedureCode), "A procedure with this code already exists in your branch.");

        if (!ModelState.IsValid)
        {
            model.DepartmentOptions = await procedureService.GetDepartmentOptionsAsync(model.DepartmentId);
            model.SpecialityOptions = await procedureService.GetSpecialityOptionsAsync(model.SpecialityId);
            model.ProcedureCategoryOptions = procedureService.GetProcedureCategoryOptions(model.ProcedureCategory);
            return View(model);
        }

        var updated = await procedureService.UpdateAsync(model, User.GetUserId());
        if (!updated) return NotFound();

        await auditLogService.LogAsync("MasterData", "Procedures.Edit",
            $"Updated procedure: {model.ProcedureName} ({model.ProcedureCode}) [ID: {model.ProcedureId}]",
            branchId: branchId);

        TempData["SuccessMessage"] = $"Procedure '{model.ProcedureName}' updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var entity = await procedureService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        var tariffs = await procedureService.GetTariffsByProcedureIdAsync(id);

        var model = new ProcedureDetailsViewModel
        {
            Procedure = entity,
            Tariffs = tariffs
        };

        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id)
    {
        var entity = await procedureService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        await procedureService.ToggleActiveAsync(id, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Procedures.ToggleStatus",
            $"Toggled active status for procedure: {entity.ProcedureName} ({entity.ProcedureCode}) [ID: {id}]",
            branchId: entity.BranchId);

        TempData["SuccessMessage"] = $"Status updated for '{entity.ProcedureName}'.";
        return RedirectToAction(nameof(Index));
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var entity = await procedureService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        await procedureService.DeleteAsync(id, User.GetUserId());

        await auditLogService.LogAsync("MasterData", "Procedures.Delete",
            $"Deleted procedure: {entity.ProcedureName} ({entity.ProcedureCode}) [ID: {id}]",
            branchId: entity.BranchId);

        TempData["SuccessMessage"] = $"Procedure '{entity.ProcedureName}' removed.";
        return RedirectToAction(nameof(Index));
    }
}
