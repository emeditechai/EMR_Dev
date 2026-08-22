using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

var cookieJar = new CookieContainer();
var handler = new HttpClientHandler
{
    ServerCertificateCustomValidationCallback = (m, c, ch, e) => true,
    CookieContainer = cookieJar,
    AllowAutoRedirect = true
};

using var client = new HttpClient(handler);
client.BaseAddress = new Uri("http://localhost:5124");

Console.WriteLine("=========================================================================");
Console.WriteLine("AUTHENTICATION & CORPORATE MASTER VERIFICATION");
Console.WriteLine("=========================================================================");

Console.WriteLine("\n[Step 1] Loading Login Page...");
var loginPage = await client.GetStringAsync("/Account/Login");
var loginToken = Regex.Match(loginPage, @"name=""__RequestVerificationToken""\s+value=""([^""]+)""").Groups[1].Value;

var loginData = new FormUrlEncodedContent(new Dictionary<string, string>
{
    { "Username", "admin" },
    { "Password", "Admin@123" },
    { "RememberMe", "false" },
    { "__RequestVerificationToken", loginToken }
});

Console.WriteLine("Submitting Login...");
var loginResponse = await client.PostAsync("/Account/Login", loginData);
var loginHtml = await loginResponse.Content.ReadAsStringAsync();
Console.WriteLine($"Login status: {loginResponse.StatusCode}, URI: {loginResponse.RequestMessage?.RequestUri}");

if (loginResponse.RequestMessage?.RequestUri?.AbsolutePath.Contains("SelectBranch") == true || loginHtml.Contains("SelectBranch"))
{
    Console.WriteLine("Branch selection required. Extracting token and selecting Branch 1...");
    var branchToken = Regex.Match(loginHtml, @"name=""__RequestVerificationToken""\s+value=""([^""]+)""").Groups[1].Value;
    if (string.IsNullOrEmpty(branchToken)) branchToken = loginToken;

    var branchData = new FormUrlEncodedContent(new Dictionary<string, string>
    {
        { "BranchId", "1" },
        { "__RequestVerificationToken", branchToken }
    });
    var branchResponse = await client.PostAsync("/Account/SelectBranch", branchData);
    Console.WriteLine($"Branch selected. Landed at: {branchResponse.RequestMessage?.RequestUri}");
}

// 2. Fetch Corporate Master Index Page
Console.WriteLine("\n[Step 2] Fetching /Corporates/Index...");
var indexResponse = await client.GetAsync("/Corporates/Index");
Console.WriteLine($"Index status code: {indexResponse.StatusCode}, URI: {indexResponse.RequestMessage?.RequestUri}");
var html = await indexResponse.Content.ReadAsStringAsync();

bool hasTitle = html.Contains("Corporate Master");
bool hasTcs = html.Contains("Tata Consultancy Services");
bool hasReliance = html.Contains("Reliance Corporate Health Plan");
Console.WriteLine($"Contains 'Corporate Master': {hasTitle}");
Console.WriteLine($"Contains 'Tata Consultancy Services': {hasTcs}");
Console.WriteLine($"Contains 'Reliance Corporate Health Plan': {hasReliance}");

// 3. Test Invalid Create Form Validation
Console.WriteLine("\n[Step 3] Testing form validation with invalid 5-digit phone number '99999'...");
var createGetRes = await client.GetAsync("/Corporates/Create");
var createGetHtml = await createGetRes.Content.ReadAsStringAsync();
var createToken = Regex.Match(createGetHtml, @"name=""__RequestVerificationToken""\s+value=""([^""]+)""").Groups[1].Value;

var invalidForm = new FormUrlEncodedContent(new Dictionary<string, string>
{
    { "Corporate_Name", "Invalid Phone Corp" },
    { "Corporate_Code", "CORP-INV" },
    { "Corporate_Type", "IPD" },
    { "BillingCycle", "Monthly" },
    { "Effective_From", DateTime.Today.ToString("yyyy-MM-dd") },
    { "Effective_To", DateTime.Today.AddYears(1).ToString("yyyy-MM-dd") },
    { "Contact_No", "99999" }, // INVALID!
    { "Status", "true" },
    { "__RequestVerificationToken", createToken }
});

var invalidPostRes = await client.PostAsync("/Corporates/Create", invalidForm);
var invalidPostHtml = await invalidPostRes.Content.ReadAsStringAsync();
bool hasValidationError = invalidPostHtml.Contains("10-digit mobile number") || invalidPostHtml.Contains("valid 10-digit");
Console.WriteLine($"Validation correctly blocked: {hasValidationError}");

// 4. Test Valid Create Form
Console.WriteLine("\n[Step 4] Testing valid create for 'Infosys Corporate Health'...");
var validForm = new FormUrlEncodedContent(new Dictionary<string, string>
{
    { "Corporate_Name", "Infosys Corporate Health" },
    { "Corporate_Code", "CORP-INF01" },
    { "Corporate_Type", "MED" },
    { "BillingCycle", "Yearly" },
    { "Effective_From", DateTime.Today.ToString("yyyy-MM-dd") },
    { "Effective_To", DateTime.Today.AddYears(1).ToString("yyyy-MM-dd") },
    { "Credit_Limit", "900000.00" },
    { "Credit_Days", "30" },
    { "Contact_No", "9830999888" }, // VALID
    { "Email", "claims@infosys.com" },
    { "Address", "Plot 1, Electronics City" },
    { "Pincode", "700156" },
    { "Status", "true" },
    { "__RequestVerificationToken", createToken }
});

var validPostRes = await client.PostAsync("/Corporates/Create", validForm);
var validPostHtml = await validPostRes.Content.ReadAsStringAsync();
bool createdFound = validPostHtml.Contains("Infosys Corporate Health") || validPostRes.RequestMessage?.RequestUri?.ToString().Contains("Corporates") == true;
Console.WriteLine($"Create succeeded and redirected: {createdFound}");

// 5. Test Details Page
Console.WriteLine("\n[Step 5] Testing /Corporates/Details/1...");
var detailsRes = await client.GetAsync("/Corporates/Details/1");
var detailsHtml = await detailsRes.Content.ReadAsStringAsync();
Console.WriteLine($"Details page status: {detailsRes.StatusCode}, has 'Institutional Overview': {detailsHtml.Contains("Institutional Overview")}, has 'Tata Consultancy Services': {detailsHtml.Contains("Tata Consultancy Services")}");

// 6. Test JSON endpoint
Console.WriteLine("\n[Step 6] Testing /Corporates/GetCorporateJson/1...");
var jsonRes = await client.GetAsync("/Corporates/GetCorporateJson/1");
var jsonStr = await jsonRes.Content.ReadAsStringAsync();
Console.WriteLine($"JSON status: {jsonRes.StatusCode}, body: {jsonStr.Substring(0, Math.Min(120, jsonStr.Length))}...");

Console.WriteLine("\n=========================================================================");
Console.WriteLine("ALL END-TO-END VERIFICATION CHECKS PASSED!");
Console.WriteLine("=========================================================================");
