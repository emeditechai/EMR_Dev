using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services.Geography;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Controllers;

[Authorize]
public class DistrictsController(
    IDistrictService districtService,
    IStateService stateService,
    ICountryService countryService) : Controller
{
    public async Task<IActionResult> Index()
    {
        var list = await districtService.GetAllAsync();
        return View(list);
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        return View(new DistrictFormViewModel
        {
            Countries = await GetCountryList()
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(DistrictFormViewModel model)
    {
        if (await districtService.CodeExistsAsync(model.DistrictCode))
            ModelState.AddModelError(nameof(model.DistrictCode), "District Code already exists.");

        if (!ModelState.IsValid)
        {
            model.Countries = await GetCountryList(model.CountryId);
            model.States = await GetStateList(model.CountryId, model.StateId);
            return View(model);
        }

        await districtService.CreateAsync(new DistrictMaster
        {
            DistrictCode = model.DistrictCode.Trim().ToUpper(),
            DistrictName = model.DistrictName.Trim(),
            StateId = model.StateId,
            IsActive = model.IsActive
        }, User.GetUserId());

        TempData["Success"] = "District created successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var entity = await districtService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        var countryId = entity.State?.CountryId ?? 0;
        return View(new DistrictFormViewModel
        {
            DistrictId = entity.DistrictId,
            DistrictCode = entity.DistrictCode,
            DistrictName = entity.DistrictName,
            StateId = entity.StateId,
            CountryId = countryId,
            IsActive = entity.IsActive,
            Countries = await GetCountryList(countryId),
            States = await GetStateList(countryId, entity.StateId)
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(DistrictFormViewModel model)
    {
        if (await districtService.CodeExistsAsync(model.DistrictCode, model.DistrictId))
            ModelState.AddModelError(nameof(model.DistrictCode), "District Code already exists.");

        if (!ModelState.IsValid)
        {
            model.Countries = await GetCountryList(model.CountryId);
            model.States = await GetStateList(model.CountryId, model.StateId);
            return View(model);
        }

        await districtService.UpdateAsync(new DistrictMaster
        {
            DistrictId = model.DistrictId,
            DistrictCode = model.DistrictCode.Trim().ToUpper(),
            DistrictName = model.DistrictName.Trim(),
            StateId = model.StateId,
            IsActive = model.IsActive
        }, User.GetUserId());

        TempData["Success"] = "District updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var entity = await districtService.GetByIdAsync(id);
        if (entity is null) return NotFound();
        return View(entity);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var deleted = await districtService.DeleteAsync(id);
        TempData[deleted ? "Success" : "Error"] = deleted
            ? "District deleted successfully."
            : "Cannot delete: Cities are linked to this District.";
        return RedirectToAction(nameof(Index));
    }

    // AJAX
    [HttpGet]
    public async Task<IActionResult> GetByState(int stateId)
    {
        var districts = await districtService.GetByStateAsync(stateId);
        return Json(districts.Select(d => new { d.DistrictId, d.DistrictName }));
    }

    private async Task<IEnumerable<SelectListItem>> GetCountryList(int? selected = null)
    {
        var countries = await countryService.GetActiveAsync();
        return countries.Select(c => new SelectListItem(c.CountryName, c.CountryId.ToString(),
            c.CountryId == selected));
    }

    private async Task<IEnumerable<SelectListItem>> GetStateList(int countryId, int? selected = null)
    {
        if (countryId == 0) return [];
        var states = await stateService.GetByCountryAsync(countryId);
        return states.Select(s => new SelectListItem(s.StateName, s.StateId.ToString(),
            s.StateId == selected));
    }
}
