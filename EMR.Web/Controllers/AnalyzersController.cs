using EMR.Web.ApiClients;
using EMR.Web.ApiClients.Models;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class AnalyzersController(
    IAnalyzerApiClient analyzerApiClient,
    ApplicationDbContext dbContext,
    IAuditLogService auditLogService) : Controller
{
    private static readonly List<string> InterfaceProtocols = new() { "HL7", "ASTM", "Manual Entry" };

    [HttpGet]
    public async Task<IActionResult> Index(int? departmentId,
        string? interfaceProtocol,
        bool? status,
        string? search)
    {        var items = await analyzerApiClient.GetListAsync(departmentId, interfaceProtocol, status, search);

        var viewModel = new AnalyzerListViewModel
        {
            Items = items,
            FilterDepartmentId = departmentId,
            FilterInterfaceProtocol = interfaceProtocol,
            FilterStatus = status,
            SearchTerm = search,
            DepartmentOptions = await GetLabDepartmentOptionsAsync(departmentId),
            InterfaceProtocolOptions = GetInterfaceProtocolOptions(interfaceProtocol),
            StatusOptions = new List<SelectListItem>
            {
                new() { Value = "", Text = "All Statuses", Selected = !status.HasValue },
                new() { Value = "true", Text = "Active", Selected = status == true },
                new() { Value = "false", Text = "Inactive", Selected = status == false }
            }
        };

        return View(viewModel);
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var item = await analyzerApiClient.GetByIdAsync(id);
        if (item is null)
        {
            TempData["Error"] = $"Analyzer #{id} not found.";
            return RedirectToAction(nameof(Index));
        }

        return View(new AnalyzerDetailViewModel { Item = item });
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        var model = new AnalyzerFormViewModel
        {
            Status = true,
            Interface_Protocol = "HL7",
            DepartmentOptions = await GetLabDepartmentOptionsAsync(),
            InterfaceProtocolOptions = GetInterfaceProtocolOptions("HL7")
        };

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(AnalyzerFormViewModel model)
    {
        if (!ModelState.IsValid)
        {
            model.DepartmentOptions = await GetLabDepartmentOptionsAsync(model.Department_ID);
            model.InterfaceProtocolOptions = GetInterfaceProtocolOptions(model.Interface_Protocol);
            return View(model);
        }

        var request = new AnalyzerSaveRequest
        {
            CompanyId = User.GetCompanyId() > 0 ? User.GetCompanyId() : 1,
            Department_ID = model.Department_ID,
            Analyzer_Name = model.Analyzer_Name.Trim(),
            Interface_Protocol = model.Interface_Protocol.Trim(),
            Status = model.Status,
            UserId = User.GetUserId()
        };

        var createdId = await analyzerApiClient.CreateAsync(request);
        if (createdId > 0)
        {
            await auditLogService.LogAsync("MasterData", "Analyzers.Create", $"Created Analyzer: {model.Analyzer_Name} (ID: {createdId})", createdId);
            TempData["Success"] = $"Analyzer '{model.Analyzer_Name}' created successfully.";
            return RedirectToAction(nameof(Index));
        }

        ModelState.AddModelError(string.Empty, "Failed to create analyzer. Please ensure branch and lab department are valid.");
        model.DepartmentOptions = await GetLabDepartmentOptionsAsync(model.Department_ID);
        model.InterfaceProtocolOptions = GetInterfaceProtocolOptions(model.Interface_Protocol);
        return View(model);
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var item = await analyzerApiClient.GetByIdAsync(id);
        if (item is null)
        {
            TempData["Error"] = $"Analyzer #{id} not found.";
            return RedirectToAction(nameof(Index));
        }

        var model = new AnalyzerFormViewModel
        {
            Analyzer_ID = item.Analyzer_ID,
            Department_ID = item.Department_ID,
            Analyzer_Name = item.Analyzer_Name,
            Interface_Protocol = item.Interface_Protocol,
            Status = item.Status,
            DepartmentOptions = await GetLabDepartmentOptionsAsync(item.Department_ID),
            InterfaceProtocolOptions = GetInterfaceProtocolOptions(item.Interface_Protocol)
        };

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(int id, AnalyzerFormViewModel model)
    {
        if (id != model.Analyzer_ID)
        {
            return BadRequest();
        }

        if (!ModelState.IsValid)
        {
            model.DepartmentOptions = await GetLabDepartmentOptionsAsync(model.Department_ID);
            model.InterfaceProtocolOptions = GetInterfaceProtocolOptions(model.Interface_Protocol);
            return View(model);
        }

        var request = new AnalyzerSaveRequest
        {
            Analyzer_ID = id,
            CompanyId = User.GetCompanyId() > 0 ? User.GetCompanyId() : 1,
            Department_ID = model.Department_ID,
            Analyzer_Name = model.Analyzer_Name.Trim(),
            Interface_Protocol = model.Interface_Protocol.Trim(),
            Status = model.Status,
            UserId = User.GetUserId()
        };

        var success = await analyzerApiClient.UpdateAsync(request);
        if (success)
        {
            await auditLogService.LogAsync("MasterData", "Analyzers.Edit", $"Updated Analyzer: {model.Analyzer_Name} (ID: {id})", id);
            TempData["Success"] = $"Analyzer '{model.Analyzer_Name}' updated successfully.";
            return RedirectToAction(nameof(Index));
        }

        ModelState.AddModelError(string.Empty, "Failed to update analyzer.");
        model.DepartmentOptions = await GetLabDepartmentOptionsAsync(model.Department_ID);
        model.InterfaceProtocolOptions = GetInterfaceProtocolOptions(model.Interface_Protocol);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id)
    {
        var success = await analyzerApiClient.ToggleStatusAsync(id, User.GetUserId());
        if (success)
        {
            await auditLogService.LogAsync("MasterData", "Analyzers.ToggleStatus", $"Toggled Status for Analyzer #{id}", id);
            TempData["Success"] = "Analyzer status updated successfully.";
        }
        else
        {
            TempData["Error"] = "Failed to toggle analyzer status.";
        }

        return RedirectToAction(nameof(Index));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var success = await analyzerApiClient.DeleteAsync(id);
        if (success)
        {
            await auditLogService.LogAsync("MasterData", "Analyzers.Delete", $"Deleted Analyzer #{id}", id);
            TempData["Success"] = "Analyzer deleted successfully.";
        }
        else
        {
            TempData["Error"] = "Failed to delete analyzer.";
        }

        return RedirectToAction(nameof(Index));
    }

    private async Task<List<SelectListItem>> GetBranchOptionsAsync(int? selectedId = null)
    {
        var branches = await dbContext.BranchMasters
            .Where(b => b.IsActive)
            .OrderBy(b => b.BranchName)
            .Select(b => new SelectListItem
            {
                Value = b.BranchId.ToString(),
                Text = $"{b.BranchName} ({b.BranchCode})",
                Selected = selectedId.HasValue && b.BranchId == selectedId.Value
            })
            .ToListAsync();

        return branches;
    }

    private async Task<List<SelectListItem>> GetLabDepartmentOptionsAsync(int? selectedId = null)
    {
        // Department dropdown filtering Department Master where DeptType is 'LAB' or 'Lab'
        var depts = await dbContext.DepartmentMasters
            .Where(d => d.IsActive && (d.DeptType == "Lab" || d.DeptType == "LAB" || d.DeptName.Contains("Pathology") || d.DeptName.Contains("Lab")))
            .OrderBy(d => d.DeptName)
            .Select(d => new SelectListItem
            {
                Value = d.DeptId.ToString(),
                Text = $"{d.DeptName} ({d.DeptCode}) - {d.DeptType}",
                Selected = selectedId.HasValue && d.DeptId == selectedId.Value
            })
            .ToListAsync();

        return depts;
    }

    private static List<SelectListItem> GetInterfaceProtocolOptions(string? selected)
    {
        return InterfaceProtocols.Select(p => new SelectListItem
        {
            Value = p,
            Text = p,
            Selected = string.Equals(p, selected, StringComparison.OrdinalIgnoreCase)
        }).ToList();
    }
}
