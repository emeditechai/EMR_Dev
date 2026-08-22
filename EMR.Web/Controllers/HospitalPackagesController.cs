using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Controllers;

[Authorize]
public class HospitalPackagesController(
    IHospitalPackageApiClient packageApiClient,
    IAuditLogService auditLogService) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(string? packageType = null, bool? status = null, string? search = null)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;

        try
        {
            var packages = (await packageApiClient.GetListAsync(branchId, packageType, status, search, companyId)).ToList();
            var lookups = (await packageApiClient.GetMasterLookupsAsync(branchId, companyId)).ToList();

            var distinctTypes = new List<string>
            {
                "Maternity",
                "Cataract",
                "Surgery",
                "Cardiac",
                "ICU",
                "Wellness Hospitalization",
                "Orthopedic",
                "Laparoscopy",
                "Day Care",
                "General Inpatient"
            };

            // Merge any dynamic package types from existing packages
            foreach (var p in packages)
            {
                if (!string.IsNullOrWhiteSpace(p.Package_Type) && !distinctTypes.Contains(p.Package_Type, StringComparer.OrdinalIgnoreCase))
                {
                    distinctTypes.Add(p.Package_Type);
                }
            }

            var model = new HospitalPackageIndexViewModel
            {
                Packages = packages,
                SelectedBranchId = branchId,
                SelectedPackageType = packageType,
                SelectedStatus = status,
                SearchTerm = search,
                MasterLookups = lookups,
                PackageTypeOptions = distinctTypes.OrderBy(t => t).Select(t => new SelectListItem
                {
                    Value = t,
                    Text = t,
                    Selected = string.Equals(t, packageType, StringComparison.OrdinalIgnoreCase)
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
            ViewData["PageName"] = "Hospital Package Master";
            return View("ApiDown");
        }
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(HospitalPackageSaveViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? 1;
        model.CompanyId = companyId;
        model.Branch_ID = branchId;

        if (model.ValidTo.HasValue && model.ValidTo.Value < model.ValidFrom)
        {
            TempData["Error"] = "Validity 'To Date' cannot be earlier than 'From Date'.";
            return RedirectToAction(nameof(Index));
        }

        var validDetails = model.Details?.Where(d => !string.IsNullOrWhiteSpace(d.ItemName)).ToList() ?? [];
        if (validDetails.Count == 0)
        {
            TempData["Error"] = "Please add at least one dynamic detail line item to the package.";
            return RedirectToAction(nameof(Index));
        }
        model.Details = validDetails;

        try
        {
            var newId = await packageApiClient.CreateAsync(model, User.GetUserId());

            await auditLogService.LogAsync("MasterData", "HospitalPackage.Create",
                $"Created Hospital Package: {model.Package_Name} ({model.Package_Code}) [{model.Package_Type}] - Total: {model.TotalPackageAmount:C} [ID: {newId}]",
                branchId: branchId);

            TempData["Success"] = $"Hospital Package '{model.Package_Name}' created successfully.";
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to create package: " + ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(HospitalPackageSaveViewModel model)
    {
        var companyId = User.GetCompanyId();
        var branchId = User.GetCurrentBranchId() ?? model.Branch_ID;
        model.CompanyId = companyId;
        model.Branch_ID = branchId;

        if (model.ValidTo.HasValue && model.ValidTo.Value < model.ValidFrom)
        {
            TempData["Error"] = "Validity 'To Date' cannot be earlier than 'From Date'.";
            return RedirectToAction(nameof(Index));
        }

        var validDetails = model.Details?.Where(d => !string.IsNullOrWhiteSpace(d.ItemName)).ToList() ?? [];
        if (validDetails.Count == 0)
        {
            TempData["Error"] = "Please add at least one dynamic detail line item to the package.";
            return RedirectToAction(nameof(Index));
        }
        model.Details = validDetails;

        try
        {
            var updated = await packageApiClient.UpdateAsync(model.HospitalPackage_ID, model, User.GetUserId());

            await auditLogService.LogAsync("MasterData", "HospitalPackage.Edit",
                $"Updated Hospital Package: {model.Package_Name} ({model.Package_Code}) [{model.Package_Type}] - Total: {model.TotalPackageAmount:C} [ID: {model.HospitalPackage_ID}]",
                branchId: branchId);

            TempData["Success"] = $"Hospital Package '{model.Package_Name}' updated successfully.";
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to update package: " + ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(int id)
    {
        var branchId = User.GetCurrentBranchId() ?? 1;
        try
        {
            await packageApiClient.ToggleStatusAsync(id, User.GetUserId());

            await auditLogService.LogAsync("MasterData", "HospitalPackage.ToggleStatus",
                $"Toggled active status for Hospital Package [ID: {id}]",
                branchId: branchId);

            TempData["Success"] = "Hospital Package status updated successfully.";
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
            await packageApiClient.DeleteAsync(id, User.GetUserId());

            await auditLogService.LogAsync("MasterData", "HospitalPackage.Delete",
                $"Deleted Hospital Package [ID: {id}]",
                branchId: branchId);

            TempData["Success"] = "Hospital Package deleted successfully.";
        }
        catch (Exception ex)
        {
            TempData["Error"] = "Failed to delete package: " + ex.Message;
        }

        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> GetPackageJson(int id)
    {
        var package = await packageApiClient.GetByIdAsync(id);
        if (package is null) return NotFound();
        return Json(package);
    }

    [HttpGet]
    public async Task<IActionResult> GetPackageViewJson(int id)
    {
        var package = await packageApiClient.GetByIdAsync(id);
        if (package is null) return NotFound();

        return Json(new
        {
            hospitalPackage_ID = package.HospitalPackage_ID,
            package_Code = package.Package_Code,
            package_Name = package.Package_Name,
            package_Type = package.Package_Type,
            branchName = package.BranchName,
            branchCode = package.BranchCode,
            validFrom = package.ValidFrom.ToString("dd MMM yyyy"),
            validTo = package.ValidTo.HasValue ? package.ValidTo.Value.ToString("dd MMM yyyy") : "Ongoing / Open",
            totalPackageAmount = package.TotalPackageAmount,
            description = package.Description,
            status = package.Status,
            detailsCount = package.Details.Count,
            heads = package.Details.Select(d => d.DetailHeadType).Distinct().ToList(),
            details = package.Details.OrderBy(d => d.DisplayOrder).Select(d => new
            {
                detailHeadType = d.DetailHeadType,
                itemCode = d.ItemCode,
                itemName = d.ItemName,
                quantity = d.Quantity,
                unitRate = d.UnitRate,
                amount = d.Amount,
                billingFrequency = d.BillingFrequency,
                isMandatory = d.IsMandatory,
                remarks = d.Remarks,
                displayOrder = d.DisplayOrder
            }).ToList()
        });
    }

    [HttpGet]
    public async Task<IActionResult> GetLookups(string? headType = null)
    {
        var branchId = User.GetCurrentBranchId();
        var companyId = User.GetCompanyId();
        var lookups = await packageApiClient.GetMasterLookupsAsync(branchId, companyId);

        if (!string.IsNullOrWhiteSpace(headType))
        {
            lookups = lookups.Where(l => string.Equals(l.DetailHeadType, headType, StringComparison.OrdinalIgnoreCase));
        }

        return Json(lookups);
    }
}
