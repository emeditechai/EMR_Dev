using System.Data;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Extensions;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Utility > Franchise Dashboard (SQLScripts/2251). A franchise login sees its own franchise only - the id comes
/// from the sign-in, never from the request. Other users (lab staff granted the page) may pick any franchise of
/// their company.
/// </summary>
[Authorize]
public class FranchiseDashboardController(IDbConnectionFactory db) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index()
    {
        var own = User.GetFranchiseId();
        using var con = db.CreateConnection();
        var franchises = (await con.QueryAsync<FranchiseOption>(
            @"SELECT Franchise_ID AS Id, Franchise_Name + ' (' + Franchise_Code + ')' AS Name
                FROM dbo.LabFranchiseMaster
               WHERE IsDeleted = 0 AND CompanyId = @CompanyId AND (@Own IS NULL OR Franchise_ID = @Own)
               ORDER BY Franchise_Name",
            new { CompanyId = User.GetCompanyId(), Own = own })).ToList();

        ViewBag.Franchises = franchises;
        ViewBag.Locked = own.HasValue;
        ViewBag.FranchiseId = own ?? 0;
        return View();
    }

    [HttpGet]
    public async Task<IActionResult> Data(int? franchiseId, DateTime? fromDate, DateTime? toDate)
    {
        var id = User.GetFranchiseId() ?? franchiseId ?? 0;
        if (id <= 0) return Json(new { success = false, message = "Choose a franchise." });

        var to = (toDate ?? DateTime.Today).Date;
        var from = (fromDate ?? new DateTime(to.Year, to.Month, 1)).Date;

        using var con = db.CreateConnection();
        // lab staff may only open a franchise of their own company
        var inCompany = await con.ExecuteScalarAsync<int>(
            "SELECT COUNT(1) FROM dbo.LabFranchiseMaster WHERE Franchise_ID = @Id AND IsDeleted = 0 AND CompanyId = @CompanyId",
            new { Id = id, CompanyId = User.GetCompanyId() });
        if (inCompany == 0) return Json(new { success = false, message = "Franchise not found." });

        using var multi = await con.QueryMultipleAsync("dbo.usp_Web_FranchiseDashboard",
            new { FranchiseId = id, FromDate = from, ToDate = to }, commandType: CommandType.StoredProcedure);

        var profile = Rows(await multi.ReadAsync()).FirstOrDefault();
        var summary = Rows(await multi.ReadAsync()).FirstOrDefault();
        var sales = Rows(await multi.ReadAsync());
        var realization = Rows(await multi.ReadAsync());
        var pending = Rows(await multi.ReadAsync());
        var trend = Rows(await multi.ReadAsync());

        return Json(new { success = true, data = new { profile, summary, sales, realization, pending, trend } });
    }

    // column names exactly as the procedure returns them
    private static List<Dictionary<string, object?>> Rows(IEnumerable<dynamic> rows) =>
        rows.Select(r => ((IDictionary<string, object>)r).ToDictionary(k => k.Key, k => (object?)k.Value)).ToList();

    public sealed class FranchiseOption
    {
        public int Id { get; set; }
        public string Name { get; set; } = string.Empty;
    }
}
