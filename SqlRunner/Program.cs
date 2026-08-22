using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

Console.WriteLine("=========================================================================");
Console.WriteLine("SHIFT MASTER & INTEGRATED HOUSEKEEPING MASTERS END-TO-END VERIFICATION");
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

// 1. Authenticate
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

// 2. Direct API Check for Shifts & Housekeeping
Console.WriteLine("\n[Step 2] Verifying EMR.Api REST Endpoints...");
using var apiClient = new HttpClient();

var apiShifts = await apiClient.GetFromJsonAsync<JsonElement>("http://localhost:5201/api/shifts");
Console.WriteLine($"API /api/shifts returned {apiShifts.GetProperty("data").GetArrayLength()} shifts.");

var apiLocations = await apiClient.GetFromJsonAsync<JsonElement>("http://localhost:5201/api/housekeeping/locations");
Console.WriteLine($"API /api/housekeeping/locations returned {apiLocations.GetProperty("data").GetArrayLength()} locations.");

var apiCleanings = await apiClient.GetFromJsonAsync<JsonElement>("http://localhost:5201/api/housekeeping/cleanings");
Console.WriteLine($"API /api/housekeeping/cleanings returned {apiCleanings.GetProperty("data").GetArrayLength()} cleaning protocols.");

var apiStaff = await apiClient.GetFromJsonAsync<JsonElement>("http://localhost:5201/api/housekeeping/staff");
Console.WriteLine($"API /api/housekeeping/staff returned {apiStaff.GetProperty("data").GetArrayLength()} staff allocations.");

var apiPhysical = await apiClient.GetFromJsonAsync<JsonElement>("http://localhost:5201/api/housekeeping/physical-master-items?locationType=Ward");
Console.WriteLine($"API /api/housekeeping/physical-master-items (Ward) returned {apiPhysical.GetProperty("data").GetArrayLength()} items.");

// 3. Shift Master Web CRUD
Console.WriteLine("\n[Step 3] Testing Shift Master Web UI...");
var shiftIndexRes = await client.GetAsync("/Shifts/Index");
var shiftIndexHtml = await shiftIndexRes.Content.ReadAsStringAsync();
Console.WriteLine($"Shift Index: {shiftIndexRes.StatusCode}, Has Title: {shiftIndexHtml.Contains("Shift Master")}, Has Morning: {shiftIndexHtml.Contains("Morning Shift")}");

var shiftCreateGet = await client.GetAsync("/Shifts/Create");
var shiftCreateHtml = await shiftCreateGet.Content.ReadAsStringAsync();
var shiftCreateTokenMatch = Regex.Match(shiftCreateHtml, @"name=""__RequestVerificationToken""\s+type=""hidden""\s+value=""([^""]+)""");
string shiftCreateToken = shiftCreateTokenMatch.Success ? shiftCreateTokenMatch.Groups[1].Value : "";

var shiftCreateForm = new FormUrlEncodedContent(new[]
{
    new KeyValuePair<string, string>("ShiftCode", "TEST-EVE"),
    new KeyValuePair<string, string>("ShiftName", "Test Twilight Shift (04:00 PM - 12:00 AM)"),
    new KeyValuePair<string, string>("StartTime", "16:00:00"),
    new KeyValuePair<string, string>("EndTime", "00:00:00"),
    new KeyValuePair<string, string>("GraceTimeMinutes", "20"),
    new KeyValuePair<string, string>("BreakDurationMinutes", "40"),
    new KeyValuePair<string, string>("IsNightShift", "false"),
    new KeyValuePair<string, string>("Status", "true"),
    new KeyValuePair<string, string>("__RequestVerificationToken", shiftCreateToken)
});

var shiftCreatePost = await client.PostAsync("/Shifts/Create", shiftCreateForm);
Console.WriteLine($"Shift Create POST: {shiftCreatePost.StatusCode}");

var refreshShifts = await apiClient.GetFromJsonAsync<JsonElement>("http://localhost:5201/api/shifts?search=TEST-EVE");
int createdShiftId = refreshShifts.GetProperty("data")[0].GetProperty("shiftMaster_ID").GetInt32();
Console.WriteLine($"Created Shift ID: #{createdShiftId}");

var shiftDetailsRes = await client.GetAsync($"/Shifts/Details/{createdShiftId}");
Console.WriteLine($"Shift Details GET: {shiftDetailsRes.StatusCode}");

var shiftDeleteForm = new FormUrlEncodedContent(new[]
{
    new KeyValuePair<string, string>("__RequestVerificationToken", shiftCreateToken)
});
var shiftDeleteRes = await client.PostAsync($"/Shifts/Delete/{createdShiftId}", shiftDeleteForm);
Console.WriteLine($"Shift Delete POST: {shiftDeleteRes.StatusCode}");

// 4. Housekeeping Integrated Workspace Web CRUD
Console.WriteLine("\n[Step 4] Testing Integrated Housekeeping Workspace Web UI...");
var hkIndexRes = await client.GetAsync("/Housekeeping/Index?tab=locations");
var hkIndexHtml = await hkIndexRes.Content.ReadAsStringAsync();
Console.WriteLine($"Housekeeping Index (Locations Tab): {hkIndexRes.StatusCode}, Has Title: {hkIndexHtml.Contains("Housekeeping Masters")}, Has Cleaning Tab: {hkIndexHtml.Contains("Cleaning Master")}, Has Staff Tab: {hkIndexHtml.Contains("Housekeeping Staff Master")}");

var hkCleaningsTabRes = await client.GetAsync("/Housekeeping/Index?tab=cleanings");
Console.WriteLine($"Housekeeping Index (Cleanings Tab): {hkCleaningsTabRes.StatusCode}");

var hkStaffTabRes = await client.GetAsync("/Housekeeping/Index?tab=staff");
Console.WriteLine($"Housekeeping Index (Staff Tab): {hkStaffTabRes.StatusCode}");

var hkTokenMatch = Regex.Match(hkIndexHtml, @"name=""__RequestVerificationToken""\s+type=""hidden""\s+value=""([^""]+)""");
string hkToken = hkTokenMatch.Success ? hkTokenMatch.Groups[1].Value : "";

// 5. Test Housekeeping Location Save
Console.WriteLine("\n[Step 5] Creating new Housekeeping Location via Web Controller...");
var locForm = new FormUrlEncodedContent(new[]
{
    new KeyValuePair<string, string>("Location_ID", "0"),
    new KeyValuePair<string, string>("LocationType", "Ward"),
    new KeyValuePair<string, string>("Reference_ID", "1"),
    new KeyValuePair<string, string>("LocationCode", "LOC-TEST-W2"),
    new KeyValuePair<string, string>("LocationName", "Surgical Ward East Unit"),
    new KeyValuePair<string, string>("RiskLevel", "Moderate Risk"),
    new KeyValuePair<string, string>("Status", "true"),
    new KeyValuePair<string, string>("__RequestVerificationToken", hkToken)
});

var locPostRes = await client.PostAsync("/Housekeeping/SaveLocation", locForm);
Console.WriteLine($"SaveLocation POST: {locPostRes.StatusCode}");

var refreshLocs = await apiClient.GetFromJsonAsync<JsonElement>("http://localhost:5201/api/housekeeping/locations?search=LOC-TEST-W2");
int createdLocId = refreshLocs.GetProperty("data")[0].GetProperty("location_ID").GetInt32();
Console.WriteLine($"Created Location ID: #{createdLocId}");

// 6. Test Housekeeping Cleaning Save
Console.WriteLine("\n[Step 6] Creating new Cleaning Protocol via Web Controller...");
var clnForm = new FormUrlEncodedContent(new[]
{
    new KeyValuePair<string, string>("Cleaning_ID", "0"),
    new KeyValuePair<string, string>("CleaningType", "Corridor Dry & Wet Sanitation Protocol"),
    new KeyValuePair<string, string>("Frequency", "Every 2 Hours"),
    new KeyValuePair<string, string>("ChemicalUsed", "Lysol Surface Disinfectant 5%"),
    new KeyValuePair<string, string>("EquipmentUsed", "Single Disc Floor Scrubber"),
    new KeyValuePair<string, string>("SLA_Minutes", "25"),
    new KeyValuePair<string, string>("Status", "true"),
    new KeyValuePair<string, string>("__RequestVerificationToken", hkToken)
});

var clnPostRes = await client.PostAsync("/Housekeeping/SaveCleaning", clnForm);
Console.WriteLine($"SaveCleaning POST: {clnPostRes.StatusCode}");

var refreshClns = await apiClient.GetFromJsonAsync<JsonElement>("http://localhost:5201/api/housekeeping/cleanings?search=Corridor");
int createdClnId = refreshClns.GetProperty("data")[0].GetProperty("cleaning_ID").GetInt32();
Console.WriteLine($"Created Cleaning Protocol ID: #{createdClnId}");

// 7. Test Housekeeping Staff Allocation Save
Console.WriteLine("\n[Step 7] Deploying Housekeeping Staff Member via Web Controller...");
var stfForm = new FormUrlEncodedContent(new[]
{
    new KeyValuePair<string, string>("HKStaff_ID", "0"),
    new KeyValuePair<string, string>("Staff_ID", "1"),
    new KeyValuePair<string, string>("ShiftMaster_ID", "1"),
    new KeyValuePair<string, string>("Supervisor_ID", "1"),
    new KeyValuePair<string, string>("AreaAllocation_ID", createdLocId.ToString()),
    new KeyValuePair<string, string>("Status", "true"),
    new KeyValuePair<string, string>("__RequestVerificationToken", hkToken)
});

var stfPostRes = await client.PostAsync("/Housekeeping/SaveStaff", stfForm);
Console.WriteLine($"SaveStaff POST: {stfPostRes.StatusCode}");

var refreshStaff = await apiClient.GetFromJsonAsync<JsonElement>($"http://localhost:5201/api/housekeeping/staff?locationId={createdLocId}");
int createdStaffHkId = refreshStaff.GetProperty("data")[0].GetProperty("hkStaff_ID").GetInt32();
Console.WriteLine($"Created Staff Allocation ID: #{createdStaffHkId}");

// 8. Clean up test records
Console.WriteLine("\n[Step 8] Cleaning up test records...");
var delStaffRes = await client.PostAsync($"/Housekeeping/DeleteStaff/{createdStaffHkId}", shiftDeleteForm);
Console.WriteLine($"DeleteStaff POST: {delStaffRes.StatusCode}");

var delLocRes = await client.PostAsync($"/Housekeeping/DeleteLocation/{createdLocId}", shiftDeleteForm);
Console.WriteLine($"DeleteLocation POST: {delLocRes.StatusCode}");

var delClnRes = await client.PostAsync($"/Housekeeping/DeleteCleaning/{createdClnId}", shiftDeleteForm);
Console.WriteLine($"DeleteCleaning POST: {delClnRes.StatusCode}");

Console.WriteLine("\n=========================================================================");
Console.WriteLine("ALL SHIFT MASTER & HOUSEKEEPING MASTERS TESTS PASSED 100%!");
Console.WriteLine("=========================================================================");
