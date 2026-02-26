using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services.Geography;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Controllers;

[Authorize]
public class CitiesController(
    ICityService cityService,
    IDistrictService districtService,
    IStateService stateService,
    ICountryService countryService) : Controller
{
    public async Task<IActionResult> Index()
    {
        var list = await cityService.GetAllAsync();
        return View(list);
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        return View(new CityFormViewModel
        {
            Countries = await GetCountryList()
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(CityFormViewModel model)
    {
        if (await cityService.CodeExistsAsync(model.CityCode))
            ModelState.AddModelError(nameof(model.CityCode), "City Code already exists.");

        if (!ModelState.IsValid)
        {
            await RepopulateDropdowns(model);
            return View(model);
        }

        await cityService.CreateAsync(new CityMaster
        {
            CityCode = model.CityCode.Trim().ToUpper(),
            CityName = model.CityName.Trim(),
            DistrictId = model.DistrictId,
            IsActive = model.IsActive
        }, User.GetUserId());

        TempData["Success"] = "City created successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var entity = await cityService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        // Resolve country/state from district
        var districtObj = await districtService.GetByIdAsync(entity.DistrictId);
        var stateObj = districtObj?.State;
        int countryId = stateObj != null
            ? (await stateService.GetByIdAsync(stateObj.StateId))?.CountryId ?? 0
            : 0;
        int stateId = districtObj?.StateId ?? 0;

        var model = new CityFormViewModel
        {
            CityId = entity.CityId,
            CityCode = entity.CityCode,
            CityName = entity.CityName,
            DistrictId = entity.DistrictId,
            StateId = stateId,
            CountryId = countryId,
            IsActive = entity.IsActive,
            Countries = await GetCountryList(countryId),
            States = await GetStateList(countryId, stateId),
            Districts = await GetDistrictList(stateId, entity.DistrictId)
        };
        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(CityFormViewModel model)
    {
        if (await cityService.CodeExistsAsync(model.CityCode, model.CityId))
            ModelState.AddModelError(nameof(model.CityCode), "City Code already exists.");

        if (!ModelState.IsValid)
        {
            await RepopulateDropdowns(model);
            return View(model);
        }

        await cityService.UpdateAsync(new CityMaster
        {
            CityId = model.CityId,
            CityCode = model.CityCode.Trim().ToUpper(),
            CityName = model.CityName.Trim(),
            DistrictId = model.DistrictId,
            IsActive = model.IsActive
        }, User.GetUserId());

        TempData["Success"] = "City updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var entity = await cityService.GetByIdAsync(id);
        if (entity is null) return NotFound();
        return View(entity);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var deleted = await cityService.DeleteAsync(id);
        TempData[deleted ? "Success" : "Error"] = deleted
            ? "City deleted successfully."
            : "Cannot delete: Areas are linked to this City.";
        return RedirectToAction(nameof(Index));
    }

    // AJAX
    [HttpGet]
    public async Task<IActionResult> GetByDistrict(int districtId)
    {
        var cities = await cityService.GetByDistrictAsync(districtId);
        return Json(cities.Select(c => new { c.CityId, c.CityName }));
    }

    private async Task RepopulateDropdowns(CityFormViewModel model)
    {
        model.Countries = await GetCountryList(model.CountryId);
        model.States = await GetStateList(model.CountryId, model.StateId);
        model.Districts = await GetDistrictList(model.StateId, model.DistrictId);
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

    private async Task<IEnumerable<SelectListItem>> GetDistrictList(int stateId, int? selected = null)
    {
        if (stateId == 0) return [];
        var districts = await districtService.GetByStateAsync(stateId);
        return districts.Select(d => new SelectListItem(d.DistrictName, d.DistrictId.ToString(),
            d.DistrictId == selected));
    }
}
