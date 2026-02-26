using EMR.Web.Extensions;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services.Geography;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Controllers;

[Authorize]
public class AreasController(
    IAreaService areaService,
    ICityService cityService,
    IDistrictService districtService,
    IStateService stateService,
    ICountryService countryService) : Controller
{
    public async Task<IActionResult> Index(int? countryId, int? stateId, int? districtId, int? cityId)
    {
        var all = await areaService.GetAllAsync();
        IEnumerable<AreaMaster> list = all;
        if (cityId.HasValue)
        {
            list = all.Where(a => a.CityId == cityId.Value);
        }
        else if (districtId.HasValue)
        {
            var cities = await cityService.GetByDistrictAsync(districtId.Value);
            var cityIds = cities.Select(c => c.CityId).ToHashSet();
            list = all.Where(a => cityIds.Contains(a.CityId));
        }
        else if (stateId.HasValue)
        {
            var districts = await districtService.GetByStateAsync(stateId.Value);
            var districtIds = districts.Select(d => d.DistrictId).ToHashSet();
            var cityIds = new HashSet<int>();
            foreach (var did in districtIds)
                foreach (var c in await cityService.GetByDistrictAsync(did))
                    cityIds.Add(c.CityId);
            list = all.Where(a => cityIds.Contains(a.CityId));
        }

        ViewBag.Countries = (await countryService.GetActiveAsync())
            .Select(c => new SelectListItem(c.CountryName, c.CountryId.ToString(), c.CountryId == countryId))
            .ToList();
        ViewBag.States = countryId.HasValue
            ? (await stateService.GetByCountryAsync(countryId.Value))
                .Select(s => new SelectListItem(s.StateName, s.StateId.ToString(), s.StateId == stateId))
                .ToList()
            : new List<SelectListItem>();
        ViewBag.Districts = stateId.HasValue
            ? (await districtService.GetByStateAsync(stateId.Value))
                .Select(d => new SelectListItem(d.DistrictName, d.DistrictId.ToString(), d.DistrictId == districtId))
                .ToList()
            : new List<SelectListItem>();
        ViewBag.Cities = districtId.HasValue
            ? (await cityService.GetByDistrictAsync(districtId.Value))
                .Select(c => new SelectListItem(c.CityName, c.CityId.ToString(), c.CityId == cityId))
                .ToList()
            : new List<SelectListItem>();
        ViewBag.SelectedCountryId = countryId;
        ViewBag.SelectedStateId = stateId;
        ViewBag.SelectedDistrictId = districtId;
        ViewBag.SelectedCityId = cityId;
        return View(list);
    }

    [HttpGet]
    public async Task<IActionResult> Create()
    {
        return View(new AreaFormViewModel
        {
            Countries = await GetCountryList()
        });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(AreaFormViewModel model)
    {
        if (await areaService.CodeExistsAsync(model.AreaCode))
            ModelState.AddModelError(nameof(model.AreaCode), "Area Code already exists.");

        if (!ModelState.IsValid)
        {
            await RepopulateDropdowns(model);
            return View(model);
        }

        await areaService.CreateAsync(new AreaMaster
        {
            AreaCode = model.AreaCode.Trim().ToUpper(),
            AreaName = model.AreaName.Trim(),
            CityId = model.CityId,
            IsActive = model.IsActive
        }, User.GetUserId());

        TempData["Success"] = "Area created successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var entity = await areaService.GetByIdAsync(id);
        if (entity is null) return NotFound();

        // Resolve district → state → country chain
        var districtObj = await districtService.GetByIdAsync(entity.City?.CityId ?? 0);
        int stateId = districtObj?.StateId ?? 0;
        int countryId = stateId > 0
            ? (await stateService.GetByIdAsync(stateId))?.CountryId ?? 0
            : 0;
        int districtId = entity.City != null
            ? (await cityService.GetByIdAsync(entity.CityId))?.DistrictId ?? 0
            : 0;

        var model = new AreaFormViewModel
        {
            AreaId = entity.AreaId,
            AreaCode = entity.AreaCode,
            AreaName = entity.AreaName,
            CityId = entity.CityId,
            DistrictId = districtId,
            StateId = stateId,
            CountryId = countryId,
            IsActive = entity.IsActive,
            Countries = await GetCountryList(countryId),
            States = await GetStateList(countryId, stateId),
            Districts = await GetDistrictList(stateId, districtId),
            Cities = await GetCityList(districtId, entity.CityId)
        };
        return View(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(AreaFormViewModel model)
    {
        if (await areaService.CodeExistsAsync(model.AreaCode, model.AreaId))
            ModelState.AddModelError(nameof(model.AreaCode), "Area Code already exists.");

        if (!ModelState.IsValid)
        {
            await RepopulateDropdowns(model);
            return View(model);
        }

        await areaService.UpdateAsync(new AreaMaster
        {
            AreaId = model.AreaId,
            AreaCode = model.AreaCode.Trim().ToUpper(),
            AreaName = model.AreaName.Trim(),
            CityId = model.CityId,
            IsActive = model.IsActive
        }, User.GetUserId());

        TempData["Success"] = "Area updated successfully.";
        return RedirectToAction(nameof(Index));
    }

    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var entity = await areaService.GetByIdAsync(id);
        if (entity is null) return NotFound();
        return View(entity);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        await areaService.DeleteAsync(id);
        TempData["Success"] = "Area deleted successfully.";
        return RedirectToAction(nameof(Index));
    }

    private async Task RepopulateDropdowns(AreaFormViewModel model)
    {
        model.Countries = await GetCountryList(model.CountryId);
        model.States = await GetStateList(model.CountryId, model.StateId);
        model.Districts = await GetDistrictList(model.StateId, model.DistrictId);
        model.Cities = await GetCityList(model.DistrictId, model.CityId);
    }

    private async Task<IEnumerable<SelectListItem>> GetCountryList(int? selected = null)
    {
        var items = await countryService.GetActiveAsync();
        return items.Select(c => new SelectListItem(c.CountryName, c.CountryId.ToString(), c.CountryId == selected));
    }

    private async Task<IEnumerable<SelectListItem>> GetStateList(int countryId, int? selected = null)
    {
        if (countryId == 0) return [];
        var items = await stateService.GetByCountryAsync(countryId);
        return items.Select(s => new SelectListItem(s.StateName, s.StateId.ToString(), s.StateId == selected));
    }

    private async Task<IEnumerable<SelectListItem>> GetDistrictList(int stateId, int? selected = null)
    {
        if (stateId == 0) return [];
        var items = await districtService.GetByStateAsync(stateId);
        return items.Select(d => new SelectListItem(d.DistrictName, d.DistrictId.ToString(), d.DistrictId == selected));
    }

    private async Task<IEnumerable<SelectListItem>> GetCityList(int districtId, int? selected = null)
    {
        if (districtId == 0) return [];
        var items = await cityService.GetByDistrictAsync(districtId);
        return items.Select(c => new SelectListItem(c.CityName, c.CityId.ToString(), c.CityId == selected));
    }
}
