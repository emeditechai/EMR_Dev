using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

var cookieContainer = new CookieContainer();
var handler = new HttpClientHandler { CookieContainer = cookieContainer, AllowAutoRedirect = true };
using var webClient = new HttpClient(handler);
webClient.BaseAddress = new Uri("http://localhost:5124");

var getLogin = await webClient.GetAsync("/Account/Login");
var loginHtml = await getLogin.Content.ReadAsStringAsync();
var loginToken = Regex.Match(loginHtml, @"<input[^>]+name=""__RequestVerificationToken""[^>]+value=""([^""]+)""").Groups[1].Value;

var loginForm = new FormUrlEncodedContent(new Dictionary<string, string>
{
    { "Username", "admin" },
    { "Password", "Admin@123" },
    { "RememberMe", "false" },
    { "__RequestVerificationToken", loginToken }
});
var loginPostRes = await webClient.PostAsync("/Account/Login", loginForm);
var loginPostHtml = await loginPostRes.Content.ReadAsStringAsync();

if (loginPostHtml.Contains("SelectBranch") || loginPostRes.RequestMessage?.RequestUri?.ToString().Contains("SelectBranch") == true)
{
    var branchToken = Regex.Match(loginPostHtml, @"<input[^>]+name=""__RequestVerificationToken""[^>]+value=""([^""]+)""").Groups[1].Value;
    if (string.IsNullOrEmpty(branchToken)) branchToken = loginToken;
    var branchForm = new FormUrlEncodedContent(new Dictionary<string, string>
    {
        { "branchId", "1" },
        { "__RequestVerificationToken", branchToken }
    });
    await webClient.PostAsync("/Account/SelectBranch", branchForm);
}

// 1. Verify /Icus/Index has view icons and modals
var resIndex = await webClient.GetAsync("/Icus/Index");
var htmlIndex = await resIndex.Content.ReadAsStringAsync();
bool hasViewTariffBtn = htmlIndex.Contains("openViewTariffModal");
bool hasViewIcuBtn = htmlIndex.Contains("openViewIcuModal");
bool hasViewTariffModal = htmlIndex.Contains("id=\"viewTariffModal\"");
bool hasViewIcuModal = htmlIndex.Contains("id=\"viewIcuModal\"");

Console.WriteLine($"Index page contains openViewTariffModal: {hasViewTariffBtn}");
Console.WriteLine($"Index page contains openViewIcuModal: {hasViewIcuBtn}");
Console.WriteLine($"Index page contains #viewTariffModal: {hasViewTariffModal}");
Console.WriteLine($"Index page contains #viewIcuModal: {hasViewIcuModal}");

// 2. Verify GetTariffViewJson
var resTariffView = await webClient.GetAsync("/Icus/GetTariffViewJson/1");
Console.WriteLine($"GET /Icus/GetTariffViewJson/1: {resTariffView.StatusCode}");
var jsonTariffView = await resTariffView.Content.ReadAsStringAsync();
bool hasRateHeads = jsonTariffView.Contains("rateHeadName") && jsonTariffView.Contains("totalRate");
Console.WriteLine($"Tariff view JSON has rateHeadName and totalRate: {hasRateHeads}");

// 3. Verify GetIcuViewJson
var resIcuView = await webClient.GetAsync("/Icus/GetIcuViewJson/1");
Console.WriteLine($"GET /Icus/GetIcuViewJson/1: {resIcuView.StatusCode}");
var jsonIcuView = await resIcuView.Content.ReadAsStringAsync();
bool hasIcuDetails = jsonIcuView.Contains("icuName") && jsonIcuView.Contains("bedCapacity");
Console.WriteLine($"ICU view JSON has icuName and bedCapacity: {hasIcuDetails}");

if (hasViewTariffBtn && hasViewIcuBtn && hasViewTariffModal && hasViewIcuModal && hasRateHeads && hasIcuDetails)
{
    Console.WriteLine("\n=========================================================================");
    Console.WriteLine(">>> VIEW MODAL & ALL DETAILS VERIFICATION PASSED 100%! <<<");
    Console.WriteLine("=========================================================================");
}
else
{
    Console.WriteLine("\n>>> VIEW MODAL VERIFICATION FAILED! <<<");
}
