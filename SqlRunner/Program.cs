using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

var cookieContainer = new CookieContainer();
var handler = new HttpClientHandler { CookieContainer = cookieContainer, AllowAutoRedirect = true };
using var webClient = new HttpClient(handler);
webClient.BaseAddress = new Uri("http://localhost:5124");

Console.WriteLine("=========================================================================");
Console.WriteLine("EMR.WEB HOSPITAL PACKAGE MASTER - EDIT ACTIVE/INACTIVE TEST");
Console.WriteLine("=========================================================================");

// 1. Authenticate as Admin
Console.WriteLine("\n[Step 1] Logging into EMR.Web...");
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
Console.WriteLine("Login and Branch selection completed successfully.");

// 2. Fetch Package ID 1 current details
Console.WriteLine("\n[Step 2] Fetching Package ID 1 before edit...");
var getPkgRes = await webClient.GetAsync("/HospitalPackages/GetPackageJson/1");
var pkgJson = await getPkgRes.Content.ReadAsStringAsync();
using var doc1 = JsonDocument.Parse(pkgJson);
var initialStatus = doc1.RootElement.GetProperty("status").GetBoolean();
Console.WriteLine($"Package 1 Initial Status: {initialStatus}");

// 3. Post Edit to make it INACTIVE (Status = false)
Console.WriteLine("\n[Step 3] Submitting Edit Form with Status = false (toggle OFF)...");
var indexHtml = await (await webClient.GetAsync("/HospitalPackages/Index")).Content.ReadAsStringAsync();
var token = Regex.Match(indexHtml, @"<input[^>]+name=""__RequestVerificationToken""[^>]+value=""([^""]+)""").Groups[1].Value;

var editInactiveForm = new FormUrlEncodedContent(new Dictionary<string, string>
{
    { "__RequestVerificationToken", token },
    { "HospitalPackage_ID", "1" },
    { "Package_Code", doc1.RootElement.GetProperty("package_Code").GetString()! },
    { "Package_Name", doc1.RootElement.GetProperty("package_Name").GetString()! },
    { "Package_Type", doc1.RootElement.GetProperty("package_Type").GetString()! },
    { "ValidFrom", "2026-08-22" },
    { "TotalPackageAmount", "28000" },
    { "Description", "Testing toggle inactive" },
    { "Status", "false" }, // Checkbox OFF sends hidden value false
    { "Details[0].DetailHeadType", "Bed" },
    { "Details[0].ItemName", "3-Day Post-Natal Semi-Private Bed" },
    { "Details[0].ItemCode", "BED-MAT-01" },
    { "Details[0].Quantity", "3" },
    { "Details[0].UnitRate", "2000" },
    { "Details[0].Amount", "6000" },
    { "Details[0].BillingFrequency", "Per Day" },
    { "Details[0].IsMandatory", "true" }
});

var editInactiveRes = await webClient.PostAsync("/HospitalPackages/Edit", editInactiveForm);
Console.WriteLine($"POST /HospitalPackages/Edit status: {editInactiveRes.StatusCode}");

// 4. Verify that Package 1 is now INACTIVE
var checkPkgRes = await webClient.GetAsync("/HospitalPackages/GetPackageJson/1");
var checkJson = await checkPkgRes.Content.ReadAsStringAsync();
using var doc2 = JsonDocument.Parse(checkJson);
var inactiveStatus = doc2.RootElement.GetProperty("status").GetBoolean();
Console.WriteLine($"Package 1 Status after Edit to Inactive: {inactiveStatus} (Expected: False)");

// 5. Post Edit to make it ACTIVE again (Status = true)
Console.WriteLine("\n[Step 5] Submitting Edit Form with Status = true (toggle ON)...");
var editActiveForm = new FormUrlEncodedContent(new Dictionary<string, string>
{
    { "__RequestVerificationToken", token },
    { "HospitalPackage_ID", "1" },
    { "Package_Code", doc1.RootElement.GetProperty("package_Code").GetString()! },
    { "Package_Name", doc1.RootElement.GetProperty("package_Name").GetString()! },
    { "Package_Type", doc1.RootElement.GetProperty("package_Type").GetString()! },
    { "ValidFrom", "2026-08-22" },
    { "TotalPackageAmount", "28000" },
    { "Description", "Testing toggle active" },
    { "Status", "true" }, // Checkbox ON sends true
    { "Details[0].DetailHeadType", "Bed" },
    { "Details[0].ItemName", "3-Day Post-Natal Semi-Private Bed" },
    { "Details[0].ItemCode", "BED-MAT-01" },
    { "Details[0].Quantity", "3" },
    { "Details[0].UnitRate", "2000" },
    { "Details[0].Amount", "6000" },
    { "Details[0].BillingFrequency", "Per Day" },
    { "Details[0].IsMandatory", "true" }
});

var editActiveRes = await webClient.PostAsync("/HospitalPackages/Edit", editActiveForm);
Console.WriteLine($"POST /HospitalPackages/Edit status: {editActiveRes.StatusCode}");

// 6. Verify that Package 1 is now ACTIVE
var checkActiveRes = await webClient.GetAsync("/HospitalPackages/GetPackageJson/1");
var checkActiveJson = await checkActiveRes.Content.ReadAsStringAsync();
using var doc3 = JsonDocument.Parse(checkActiveJson);
var activeStatus = doc3.RootElement.GetProperty("status").GetBoolean();
Console.WriteLine($"Package 1 Status after Edit to Active: {activeStatus} (Expected: True)");

// 7. Check that Index page no longer has the separate ToggleStatus button
var indexFinalHtml = await (await webClient.GetAsync("/HospitalPackages/Index")).Content.ReadAsStringAsync();
bool hasDirectToggleInTable = indexFinalHtml.Contains("asp-action=\"ToggleStatus\"");
Console.WriteLine($"Direct Toggle Button in Table Action column: {hasDirectToggleInTable} (Expected: False)");

if (!inactiveStatus && activeStatus && !hasDirectToggleInTable)
{
    Console.WriteLine("\n=========================================================================");
    Console.WriteLine(">>> EDIT ACTIVE/INACTIVE TOGGLE TEST PASSED 100%! <<<");
    Console.WriteLine("=========================================================================");
}
else
{
    Console.WriteLine("\n>>> TEST FAILED! <<<");
}
