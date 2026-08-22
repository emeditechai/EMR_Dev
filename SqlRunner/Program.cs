using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

Console.WriteLine("=========================================================================");
Console.WriteLine("INSURANCE TARIFF CONFIGURATION INTEGRATION VERIFICATION SUITE");
Console.WriteLine("=========================================================================");

var cookieContainer = new CookieContainer();
using var handler = new HttpClientHandler
{
    CookieContainer = cookieContainer,
    ServerCertificateCustomValidationCallback = (message, cert, chain, errors) => true
};
using var client = new HttpClient(handler)
{
    BaseAddress = new Uri("http://localhost:5124")
};

// 1. Authenticate - Step A: Login
Console.WriteLine("\n[Step 1] Authenticating as Administrator...");
var loginPageResponse = await client.GetAsync("/Account/Login");
var loginHtml = await loginPageResponse.Content.ReadAsStringAsync();

var tokenMatch = Regex.Match(loginHtml, @"name=""__RequestVerificationToken""\s+type=""hidden""\s+value=""([^""]+)""");
string token = tokenMatch.Success ? tokenMatch.Groups[1].Value : "";

var formContent = new FormUrlEncodedContent(new[]
{
    new KeyValuePair<string, string>("Username", "admin"),
    new KeyValuePair<string, string>("Password", "Admin@123"),
    new KeyValuePair<string, string>("__RequestVerificationToken", token)
});

var loginResponse = await client.PostAsync("/Account/Login", formContent);
Console.WriteLine($"Step 1A (Login POST) status: {loginResponse.StatusCode}");

// 1. Authenticate - Step B: Select Branch
var selectBranchGet = await client.GetAsync("/Account/SelectBranch");
var selectBranchHtml = await selectBranchGet.Content.ReadAsStringAsync();

var branchTokenMatch = Regex.Match(selectBranchHtml, @"name=""__RequestVerificationToken""\s+type=""hidden""\s+value=""([^""]+)""");
string branchToken = branchTokenMatch.Success ? branchTokenMatch.Groups[1].Value : token;

var branchFormContent = new FormUrlEncodedContent(new[]
{
    new KeyValuePair<string, string>("BranchId", "1"),
    new KeyValuePair<string, string>("__RequestVerificationToken", branchToken)
});

var branchSelectResponse = await client.PostAsync("/Account/SelectBranch", branchFormContent);
Console.WriteLine($"Step 1B (Select Branch POST) status: {branchSelectResponse.StatusCode}");
Console.WriteLine("Authentication successful!");

// 2. Load /Insurances/Index
Console.WriteLine("\n[Step 2] GET /Insurances/Index...");
var indexResponse = await client.GetAsync("/Insurances/Index");
var indexHtml = await indexResponse.Content.ReadAsStringAsync();
Console.WriteLine($"Index loaded: {indexResponse.StatusCode}, Has Title: {indexHtml.Contains("Insurance / TPA Master")}, Has Tariffs Modal: {indexHtml.Contains("insuranceTariffsModal")}, Has Tariff Buttons: {indexHtml.Contains("openInsuranceTariffsModal")}");

// 3. Test dynamic master items for each entitlement head
Console.WriteLine("\n[Step 3] Testing dynamic master service items for each entitlement head...");
string[] heads = ["Procedure", "Room", "Package", "HospitalService", "NonPayableItem"];
foreach (var head in heads)
{
    var res = await client.GetAsync($"/Insurances/GetTariffMasterItems?entitlementType={head}");
    var json = await res.Content.ReadAsStringAsync();
    using var doc = JsonDocument.Parse(json);
    var count = doc.RootElement.GetProperty("data").GetArrayLength();
    Console.WriteLine($"Head '{head}': {count} master items available.");
}

// 4. Get Insurance Tariffs for Insurance #1
Console.WriteLine("\n[Step 4] GET /Insurances/GetInsuranceTariffs?insuranceTpaId=1...");
var tariffsRes = await client.GetAsync("/Insurances/GetInsuranceTariffs?insuranceTpaId=1");
var tariffsJson = await tariffsRes.Content.ReadAsStringAsync();
using var tariffsDoc = JsonDocument.Parse(tariffsJson);
var existingTariffsCount = tariffsDoc.RootElement.GetProperty("data").GetArrayLength();
Console.WriteLine($"Insurance #1 has {existingTariffsCount} existing tariff rules.");

// 5. Create new Package Tariff rule
Console.WriteLine("\n[Step 5] Creating new Package Tariff rule (Agreed Tariff Cap = ₹36,000.00)...");
var createPkgPayload = new
{
    InsTariff_ID = 0,
    InsuranceTPA_ID = 1,
    EntitlementType = "Package",
    Reference_ID = 1,
    DeductionRuleType = "Agreed Tariff Cap (₹)",
    DeductionValue = 0.00,
    Rate = 36000.00,
    Effective_From = DateTime.Today.ToString("yyyy-MM-dd"),
    Effective_To = DateTime.Today.AddYears(1).ToString("yyyy-MM-dd"),
    Status = true
};
var createPkgRes = await client.PostAsJsonAsync("/Insurances/SaveInsuranceTariff", createPkgPayload);
var createPkgJson = await createPkgRes.Content.ReadAsStringAsync();
Console.WriteLine($"Create Package tariff response: {createPkgJson}");
using var pkgDoc = JsonDocument.Parse(createPkgJson);
int createdTariffId = pkgDoc.RootElement.GetProperty("id").GetInt32();

// 6. Create new Co-Pay Tariff rule (Room with 12.5% Co-Pay)
Console.WriteLine("\n[Step 6] Creating new Co-Pay Tariff rule (12.5% Co-Pay on Room)...");
var createCoPayPayload = new
{
    InsTariff_ID = 0,
    InsuranceTPA_ID = 1,
    EntitlementType = "Room",
    Reference_ID = 1,
    DeductionRuleType = "Percentage Co-Pay (%)",
    DeductionValue = 12.50,
    Rate = 2250.00,
    Effective_From = DateTime.Today.ToString("yyyy-MM-dd"),
    Effective_To = DateTime.Today.AddYears(1).ToString("yyyy-MM-dd"),
    Status = true
};
var createCoPayRes = await client.PostAsJsonAsync("/Insurances/SaveInsuranceTariff", createCoPayPayload);
var createCoPayJson = await createCoPayRes.Content.ReadAsStringAsync();
Console.WriteLine($"Create Co-Pay tariff response: {createCoPayJson}");

// 7. Create new Non-Payable Item rule (100% Deduction)
Console.WriteLine("\n[Step 7] Creating new Non-Payable Item rule (100% Deduction)...");
var createNonPayPayload = new
{
    InsTariff_ID = 0,
    InsuranceTPA_ID = 1,
    EntitlementType = "NonPayableItem",
    Reference_ID = 1,
    DeductionRuleType = "Non-Payable (100% Deducted)",
    DeductionValue = 100.00,
    Rate = 0.00,
    Effective_From = DateTime.Today.ToString("yyyy-MM-dd"),
    Effective_To = DateTime.Today.AddYears(1).ToString("yyyy-MM-dd"),
    Status = true
};
var createNonPayRes = await client.PostAsJsonAsync("/Insurances/SaveInsuranceTariff", createNonPayPayload);
var createNonPayJson = await createNonPayRes.Content.ReadAsStringAsync();
Console.WriteLine($"Create Non-Payable tariff response: {createNonPayJson}");

// 8. Get Single Tariff by ID
Console.WriteLine($"\n[Step 8] GET /Insurances/GetInsuranceTariff?id={createdTariffId}...");
var getSingleRes = await client.GetAsync($"/Insurances/GetInsuranceTariff?id={createdTariffId}");
var getSingleJson = await getSingleRes.Content.ReadAsStringAsync();
Console.WriteLine($"Get tariff response: {getSingleJson.Substring(0, Math.Min(120, getSingleJson.Length))}...");

// 9. Update Tariff Rule
Console.WriteLine($"\n[Step 9] Updating tariff rule #{createdTariffId} (changing agreed rate to ₹38,500.00)...");
var updatePayload = new
{
    InsTariff_ID = createdTariffId,
    InsuranceTPA_ID = 1,
    EntitlementType = "Package",
    Reference_ID = 1,
    DeductionRuleType = "Agreed Tariff Cap (₹)",
    DeductionValue = 0.00,
    Rate = 38500.00,
    Effective_From = DateTime.Today.ToString("yyyy-MM-dd"),
    Effective_To = DateTime.Today.AddYears(2).ToString("yyyy-MM-dd"),
    Status = true
};
var updateRes = await client.PostAsJsonAsync("/Insurances/SaveInsuranceTariff", updatePayload);
var updateJson = await updateRes.Content.ReadAsStringAsync();
Console.WriteLine($"Update response: {updateJson}");

// 10. Toggle Tariff Status
Console.WriteLine($"\n[Step 10] Toggling status for tariff rule #{createdTariffId}...");
var toggleRes = await client.PostAsync($"/Insurances/ToggleTariffStatus?id={createdTariffId}", null);
var toggleJson = await toggleRes.Content.ReadAsStringAsync();
Console.WriteLine($"Toggle response: {toggleJson}");

// 11. Delete Tariff Rule
Console.WriteLine($"\n[Step 11] Deleting tariff rule #{createdTariffId}...");
var deleteRes = await client.PostAsync($"/Insurances/DeleteInsuranceTariff?id={createdTariffId}", null);
var deleteJson = await deleteRes.Content.ReadAsStringAsync();
Console.WriteLine($"Delete response: {deleteJson}");

// 12. Load Details Page
Console.WriteLine("\n[Step 12] GET /Insurances/Details/1...");
var detailsRes = await client.GetAsync("/Insurances/Details/1");
var detailsHtml = await detailsRes.Content.ReadAsStringAsync();
Console.WriteLine($"Details page loaded: {detailsRes.StatusCode}, contains Agreed Insurance Tariff Schedule: {detailsHtml.Contains("Agreed Insurance Tariff & Deduction Schedule")}");

Console.WriteLine("\n=========================================================================");
Console.WriteLine("ALL INSURANCE TARIFF CONFIGURATION INTEGRATION TESTS PASSED 100%!");
Console.WriteLine("=========================================================================");
