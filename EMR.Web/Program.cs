using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Services;
using EMR.Web.Services.Geography;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.EntityFrameworkCore;
using System.Security.Claims;
using Microsoft.AspNetCore.DataProtection;

var builder = WebApplication.CreateBuilder(args);

// Add services to the container.
builder.Services.AddControllersWithViews(options =>
{
    options.Filters.Add<EMR.Web.Filters.GlobalAuditLogFilter>();
    // Server-side authorization: one decision point for every action (mode set in "Authorization").
    options.Filters.AddService<PermissionFilter>();
});
builder.Services.AddEmrAuthorization(builder.Configuration, "DefaultConnection",
    new EmrAuthorizationApp { Name = "WEB" });
builder.Services.AddScoped<IPermissionAdminService, PermissionAdminService>();
builder.Services.AddDbContext<ApplicationDbContext>(options =>
    options.UseSqlServer(builder.Configuration.GetConnectionString("DefaultConnection")));

builder.Services.AddScoped<IPasswordHasherService, PasswordHasherService>();
builder.Services.AddScoped<IAuditLogService, AuditLogService>();
builder.Services.AddScoped<IMasterApprovalService, MasterApprovalService>();
builder.Services.AddScoped<ILoginCredentialsMailer, LoginCredentialsMailer>();

// Geography Masters (Dapper)
builder.Services.AddScoped<IDbConnectionFactory, DbConnectionFactory>();
builder.Services.AddScoped<ICountryService, CountryService>();
builder.Services.AddScoped<IStateService, StateService>();
builder.Services.AddScoped<IDistrictService, DistrictService>();
builder.Services.AddScoped<ICityService, CityService>();
builder.Services.AddScoped<IAreaService, AreaService>();

// Clinical Masters (Dapper)
builder.Services.AddScoped<IDoctorSpecialityService, DoctorSpecialityService>();
builder.Services.AddScoped<IDoctorSubSpecialityService, DoctorSubSpecialityService>();
builder.Services.AddScoped<IDepartmentService, DepartmentService>();
builder.Services.AddScoped<IClinicalUnitService, ClinicalUnitService>();
builder.Services.AddScoped<IDoctorService, DoctorService>();
// LAB billing AI assist: Tesseract OCR on this server + ML.NET test matching (PrescriptionAssist section)
builder.Services.Configure<EMR.Web.Services.PrescriptionAssist.PrescriptionAssistOptions>(builder.Configuration.GetSection(EMR.Web.Services.PrescriptionAssist.PrescriptionAssistOptions.SectionName));
builder.Services.AddMemoryCache();
builder.Services.AddSingleton<EMR.Web.Services.PrescriptionAssist.IHandwritingRecognizer, EMR.Web.Services.PrescriptionAssist.HandwritingRecognizer>();
builder.Services.AddSingleton<EMR.Web.Services.PrescriptionAssist.IPrescriptionOcrEngine, EMR.Web.Services.PrescriptionAssist.TesseractOcrEngine>();
builder.Services.AddSingleton<EMR.Web.Services.PrescriptionAssist.IPrescriptionTestMatcher, EMR.Web.Services.PrescriptionAssist.PrescriptionTestMatcher>();
// ID document assist: OCR (same engine) + ML.NET document-type classifier + number validation (SQLScripts/2284)
builder.Services.AddSingleton<EMR.Web.Services.IdDocumentAssist.IIdDocumentReader, EMR.Web.Services.IdDocumentAssist.IdDocumentReader>();
// Hospital Settings > LAB > Enable AI Features at Billing (per branch, SQLScripts/2286)
builder.Services.AddScoped<EMR.Web.Services.IAiBillingFeatures, EMR.Web.Services.AiBillingFeatures>();
// AI test suggestions at B2C billing: learned from past bills, kept in memory per branch (SQLScripts/2287)
// reflex test suggestions at LAB Reporting (SQLScripts/2289)
builder.Services.AddScoped<EMR.Web.Services.Reflex.ILabReflexService, EMR.Web.Services.Reflex.LabReflexService>();
builder.Services.AddScoped<EMR.Web.Services.TestSuggestions.ILabTestSuggestionService, EMR.Web.Services.TestSuggestions.LabTestSuggestionService>();

builder.Services.AddScoped<IBuildingService, BuildingService>();

builder.Services.AddScoped<IFloorService, FloorService>();
builder.Services.AddScoped<IWardService, WardService>();
builder.Services.AddScoped<INursingStationService, NursingStationService>();
builder.Services.AddScoped<IRoomService, RoomService>();
builder.Services.AddScoped<IBedCategoryService, BedCategoryService>();
builder.Services.AddScoped<IBedService, BedService>();
builder.Services.AddScoped<ITariffCategoryService, TariffCategoryService>();
builder.Services.AddScoped<IBedRoomTariffService, BedRoomTariffService>();
builder.Services.AddScoped<IHospitalServiceService, HospitalServiceService>();
builder.Services.AddScoped<IHospitalServiceRateService, HospitalServiceRateService>();
builder.Services.AddScoped<IProcedureService, ProcedureService>();
builder.Services.AddScoped<IProcedureTariffService, ProcedureTariffService>();
builder.Services.AddScoped<IOtService, OtService>();
builder.Services.AddScoped<IOtEquipmentService, OtEquipmentService>();
builder.Services.AddScoped<IOtTariffService, OtTariffService>();
builder.Services.AddScoped<IAnaesthesiaService, AnaesthesiaService>();
builder.Services.AddScoped<IIcuService, IcuService>();
builder.Services.AddScoped<ICorporateService, CorporateService>();
builder.Services.AddScoped<ICorporateHospitalRateService, CorporateHospitalRateService>();
builder.Services.AddScoped<IInsuranceTPAService, InsuranceTPAService>();
builder.Services.AddScoped<IInsuranceTariffService, InsuranceTariffService>();
builder.Services.AddScoped<IGovernmentSchemeService, GovernmentSchemeService>();
builder.Services.AddScoped<IDoctorRoomService, DoctorRoomService>();
builder.Services.AddScoped<ILabMasterDashboardService, LabMasterDashboardService>();








builder.Services.AddScoped<IRoomDoctorAssignmentService, RoomDoctorAssignmentService>();
builder.Services.AddScoped<IServiceService, ServiceService>();
builder.Services.AddScoped<IDoctorConsultingFeeService, DoctorConsultingFeeService>();
builder.Services.AddScoped<IDiscountTypeService, DiscountTypeService>();

// Patient Registration (Dapper)
builder.Services.AddScoped<IPatientService, PatientService>();

// EMR Template Service (EF Core)
builder.Services.AddScoped<IEmrTemplateService, EmrTemplateService>();

// Patient Vitals (Dapper)
builder.Services.AddScoped<IPatientVitalService, PatientVitalService>();

// Payment (Dapper)
builder.Services.AddScoped<IPaymentService, PaymentService>();

// Ledger (Dapper)
builder.Services.AddScoped<ILedgerService, LedgerService>();

// Utility > Accounts: petty cash, vouchers, ledger reports (Dapper)
builder.Services.AddScoped<IAccountsService, AccountsService>();
builder.Services.AddScoped<IDayClosingService, DayClosingService>();   // OPD / LAB Day Closing (SQLScripts/2275)

// Cancellation & Refund (Dapper)
builder.Services.AddScoped<ICancellationService, CancellationService>();


// Email (SMTP)
builder.Services.AddScoped<IEmailService, EmailService>();

// WhatsApp Notification Service
builder.Services.AddScoped<IWhatsAppService, WhatsAppService>();
// OPD follow-up reminders (e-mail + WhatsApp, 7 days and 1 day before; Hospital Settings > OPD; SQLScripts/2229)
builder.Services.AddHostedService<FollowUpReminderService>();
// membership points: expire points not used by their expiry date (SQLScripts/2236)
builder.Services.AddHostedService<MembershipPointsExpiryService>();

// Video Consultation (Whereby)
builder.Services.AddHttpClient("Whereby", client =>
{
    client.BaseAddress = new Uri("https://api.whereby.dev/");
    client.DefaultRequestHeaders.Add("Accept", "application/json");
});
builder.Services.AddScoped<IWherebyService, WherebyService>();
builder.Services.AddScoped<IVideoConsultationService, VideoConsultationService>();

// eCare360 licensing (Services/Licensing). A Release build enforces it on every machine (any environment) with no switch;
// a developer's Debug build skips it unless Licensing:EnforceInDebug is true;
// the rules, approvers, mailbox and licence server are compiled in (LicensingPolicy), not read from appsettings.json.
// A missing password blocks every page with "Licensing not configured" instead of stopping the application.
var licensingOptions = new EMR.Web.Services.Licensing.LicensingOptions();
builder.Configuration.GetSection(EMR.Web.Services.Licensing.LicensingOptions.Section).Bind(licensingOptions);
EMR.Web.Services.Licensing.LicensingOptions.LoadSecretsAndValidate(licensingOptions, builder.Configuration, builder.Environment.ContentRootPath);
builder.Services.AddSingleton(Microsoft.Extensions.Options.Options.Create(licensingOptions));
// the licensing mailbox (OTP and welcome e-mails only), separate from the hospital's own mail settings
builder.Services.AddSingleton<EMR.Web.Services.Licensing.ILicenseMailSender, EMR.Web.Services.Licensing.LicenseMailSender>();
builder.Services.AddSingleton<EMR.Web.Services.Licensing.IMachineFingerprintProvider, EMR.Web.Services.Licensing.MachineFingerprintProvider>();
builder.Services.AddSingleton<EMR.Web.Services.Licensing.ILicenseCrypto, EMR.Web.Services.Licensing.LicenseCrypto>();
builder.Services.AddSingleton<EMR.Web.Services.Licensing.ICentralLicenseRepository, EMR.Web.Services.Licensing.CentralLicenseRepository>();
builder.Services.AddSingleton<EMR.Web.Services.Licensing.ILocalLicenseRepository, EMR.Web.Services.Licensing.LocalLicenseRepository>();
builder.Services.AddSingleton<EMR.Web.Services.Licensing.ILicenseMailer, EMR.Web.Services.Licensing.LicenseMailer>();
builder.Services.AddSingleton<EMR.Web.Services.Licensing.ILicensingService, EMR.Web.Services.Licensing.LicensingService>();

// Sign-in throttling per client address (staff and patient portal sign-in; accounts also lock after repeated wrong passwords)
builder.Services.AddRateLimiter(o =>
{
    o.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    o.AddPolicy(EMR.Web.Controllers.AccountController.SignInRateLimit, http =>
        System.Threading.RateLimiting.RateLimitPartition.GetFixedWindowLimiter(http.Connection.RemoteIpAddress?.ToString() ?? "unknown",
            _ => new System.Threading.RateLimiting.FixedWindowRateLimiterOptions { PermitLimit = 60, Window = TimeSpan.FromMinutes(1), QueueLimit = 0 }));
    // licence OTP sends per client address (registration and hardware renewal)
    o.AddPolicy(EMR.Web.Controllers.LicenseController.OtpRateLimit, http =>
        System.Threading.RateLimiting.RateLimitPartition.GetFixedWindowLimiter("otp:" + (http.Connection.RemoteIpAddress?.ToString() ?? "unknown"),
            _ => new System.Threading.RateLimiting.FixedWindowRateLimiterOptions { PermitLimit = Math.Max(1, licensingOptions.OtpSendsPerIpPer15Min), Window = TimeSpan.FromMinutes(15), QueueLimit = 0 }));
    o.OnRejected = async (ctx, ct) =>
    {
        var isLicense = ctx.HttpContext.Request.Path.StartsWithSegments("/License", StringComparison.OrdinalIgnoreCase);
        ctx.HttpContext.Response.Headers.RetryAfter = isLicense ? "900" : "60";
        ctx.HttpContext.Response.ContentType = "text/plain; charset=utf-8";
        await ctx.HttpContext.Response.WriteAsync(isLicense
            ? "Too many OTP requests from this network. Wait 15 minutes and try again."
            : "Too many sign-in attempts from this network. Wait a minute and try again.", ct);
    };
});

// EMR.Api HTTP clients
builder.Services.AddTransient<EMR.Web.ApiClients.EmrApiTokenHandler>();
builder.Services.AddScoped<IAdministratorCheck, AdministratorCheck>();
builder.Services.AddScoped<ILabReportingEligibility, LabReportingEligibility>();
builder.Services.AddScoped<IHomeDashboardService, HomeDashboardService>();
builder.Services.AddHttpClient("EmrApi", client =>
{
    var baseUrl = builder.Configuration["ApiSettings:BaseUrl"] ?? "https://localhost:5125";
    client.BaseAddress = new Uri(baseUrl.TrimEnd('/') + "/");
    client.DefaultRequestHeaders.Add("Accept", "application/json");
})
.AddHttpMessageHandler<EMR.Web.ApiClients.EmrApiTokenHandler>()   // every call to EMR.Api carries a signed token
.ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler
{
    // Allow self-signed dev certs when calling local EMR.Api
    ServerCertificateCustomValidationCallback =
        HttpClientHandler.DangerousAcceptAnyServerCertificateValidator
});
builder.Services.AddScoped<IDoctorApiClient,            DoctorApiClient>();
builder.Services.AddScoped<IEmrConsultationApiClient,   EmrConsultationApiClient>();
builder.Services.AddScoped<IPatientApiClient,           PatientApiClient>();
builder.Services.AddScoped<IServiceBookingApiClient,    ServiceBookingApiClient>();
builder.Services.AddScoped<IPaymentSummaryApiClient,    PaymentSummaryApiClient>();
builder.Services.AddScoped<ILabOrderApiClient,          LabOrderApiClient>();
builder.Services.AddScoped<IB2BBillingApiClient,         B2BBillingApiClient>();
builder.Services.AddScoped<ISampleCollectionApiClient,   SampleCollectionApiClient>();
builder.Services.AddScoped<ISampleTransferApiClient,      SampleTransferApiClient>();
builder.Services.AddScoped<ILabReportingApiClient,       LabReportingApiClient>();
builder.Services.AddScoped<ILabDashboardApiClient,       LabDashboardApiClient>();
builder.Services.AddScoped<IReportApiClient, ReportApiClient>();
builder.Services.AddScoped<IVitalApiClient,             VitalApiClient>();
builder.Services.AddScoped<IDoctorScheduleApiClient,    DoctorScheduleApiClient>();
builder.Services.AddScoped<IPatientPortalApiClient,     PatientPortalApiClient>();
builder.Services.AddScoped<EMR.Web.Services.IPatientPortalLoginService, EMR.Web.Services.PatientPortalLoginService>();
builder.Services.AddScoped<IIpdMasterApiClient,         IpdMasterApiClient>();
builder.Services.AddScoped<IHospitalPackageApiClient,   HospitalPackageApiClient>();
builder.Services.AddScoped<ICorporateApiClient,         CorporateApiClient>();
builder.Services.AddScoped<ICorporateHospitalRateApiClient, CorporateHospitalRateApiClient>();
builder.Services.AddScoped<IInsuranceTPAApiClient,      InsuranceTPAApiClient>();
builder.Services.AddScoped<IInsuranceTariffApiClient,   InsuranceTariffApiClient>();
builder.Services.AddScoped<IGovernmentSchemeApiClient,  GovernmentSchemeApiClient>();
builder.Services.AddScoped<IShiftMasterApiClient,        ShiftMasterApiClient>();
builder.Services.AddScoped<IHousekeepingApiClient,       HousekeepingApiClient>();
builder.Services.AddScoped<IConsentMasterApiClient,      ConsentMasterApiClient>();
builder.Services.AddScoped<IDoctorCommissionApiClient,   DoctorCommissionApiClient>();
builder.Services.AddScoped<IDoctorPayoutApiClient,       DoctorPayoutApiClient>();
builder.Services.AddScoped<IGeneralMasterApiClient,     GeneralMasterApiClient>();
builder.Services.AddScoped<IOpdMasterApiClient,        OpdMasterApiClient>();
builder.Services.AddScoped<ILabTestCategoryApiClient,   LabTestCategoryApiClient>();
builder.Services.AddScoped<ILabTestSubCategoryApiClient,LabTestSubCategoryApiClient>();
builder.Services.AddScoped<ILabSampleTypeApiClient,     LabSampleTypeApiClient>();
builder.Services.AddScoped<ILabTestMethodApiClient,     LabTestMethodApiClient>();
builder.Services.AddScoped<ILabUnitApiClient,           LabUnitApiClient>();
builder.Services.AddScoped<IAnalyzerApiClient,          AnalyzerApiClient>();
builder.Services.AddScoped<ILabInvestigationApiClient,        LabInvestigationApiClient>();
builder.Services.AddScoped<ILabInvestigationProfileApiClient, LabInvestigationProfileApiClient>();
builder.Services.AddScoped<ILabRateCardApiClient, LabRateCardApiClient>();
builder.Services.AddScoped<ILabSampleRejectionApiClient, LabSampleRejectionApiClient>();
builder.Services.AddScoped<ILabOrganismApiClient, LabOrganismApiClient>();
builder.Services.AddScoped<ILabAntibioticApiClient, LabAntibioticApiClient>();
builder.Services.AddScoped<ILabAntibioticPanelApiClient, LabAntibioticPanelApiClient>();
builder.Services.AddScoped<ILabParameterOptionApiClient, LabParameterOptionApiClient>();
builder.Services.AddScoped<ILabExpertRuleApiClient, LabExpertRuleApiClient>();
builder.Services.AddScoped<ILabBreakpointApiClient, LabBreakpointApiClient>();
builder.Services.AddScoped<IDoctorIpApiClient, DoctorIpApiClient>();
builder.Services.AddScoped<IDoctorIpCommissionApiClient, DoctorIpCommissionApiClient>();
builder.Services.AddScoped<ILabSampleRejectionReasonApiClient, LabSampleRejectionReasonApiClient>();
builder.Services.AddScoped<ILabMiscChargeApiClient, LabMiscChargeApiClient>();
builder.Services.AddScoped<ILabFranchiseApiClient,            LabFranchiseApiClient>();
builder.Services.AddScoped<ILabFranchiseBarcodeApiClient,     LabFranchiseBarcodeApiClient>();
builder.Services.AddScoped<ILabBulkUploadApiClient,           LabBulkUploadApiClient>();
builder.Services.AddScoped<ILabReferenceRangeApiClient,        LabReferenceRangeApiClient>();
builder.Services.AddScoped<ILabFormulaParameterApiClient,      LabFormulaParameterApiClient>();
builder.Services.AddScoped<ILabDescriptiveTestTemplateApiClient, LabDescriptiveTestTemplateApiClient>();
builder.Services.AddScoped<ILabReportingConditionApiClient,   LabReportingConditionApiClient>();
builder.Services.AddScoped<ILabReportDispatchApiClient,       LabReportDispatchApiClient>();
builder.Services.AddScoped<ILabUnapproveApiClient,             LabUnapproveApiClient>();
builder.Services.AddScoped<IPathologistDashboardApiClient,    PathologistDashboardApiClient>();
builder.Services.AddScoped<ILabCriticalApiClient,             LabCriticalApiClient>();
builder.Services.AddScoped<ILabDefaultSignatoryApiClient,     LabDefaultSignatoryApiClient>();
builder.Services.AddScoped<ILabApprovalFlowApiClient,           LabApprovalFlowApiClient>();
builder.Services.AddScoped<ILabReportPdfService,              LabReportPdfService>();
builder.Services.AddScoped<ILabReportEmailService,            LabReportEmailService>();
builder.Services.AddScoped<ILabReportWhatsAppService,         LabReportWhatsAppService>();
builder.Services.AddScoped<IMembershipPointsWhatsAppService, MembershipPointsWhatsAppService>();
builder.Services.AddScoped<ILabCriticalNotificationService,   LabCriticalNotificationService>();
// the bell: in-app notifications pushed live to the signed-in user (SQLScripts/2263)
builder.Services.AddSignalR();
builder.Services.AddScoped<EMR.Web.Services.Notifications.INotificationService, EMR.Web.Services.Notifications.NotificationService>();
builder.Services.AddScoped<IDiscountTypeApiClient,        DiscountTypeApiClient>();
builder.Services.AddScoped<IMembershipApiClient,          MembershipApiClient>();
builder.Services.AddScoped<IMembershipCardDeliveryService, MembershipCardDeliveryService>();
builder.Services.AddHostedService<MembershipRenewalReminderBackgroundService>();

builder.Services.AddHttpContextAccessor();
builder.Services.AddSession(options =>
{
    options.IdleTimeout = TimeSpan.FromMinutes(30);
    options.Cookie.HttpOnly = true;
    options.Cookie.IsEssential = true;
});


// Persist Data Protection keys to the shared SQL database so all environments
// (local dev, IIS, staging) share the same key ring and can decrypt each other's
// encrypted values (e.g. SMTP passwords). PersistKeysToFileSystem only works on
// the machine that created the keys.
builder.Services.AddDataProtection()
    .PersistKeysToDbContext<ApplicationDbContext>()
    .SetApplicationName("EMR_Web_App");

builder.Services.AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme)
    .AddCookie(options =>
    {
        options.LoginPath = "/Account/Login";
        options.AccessDeniedPath = "/Account/AccessDenied";
        options.SlidingExpiration = true;
        options.ExpireTimeSpan = TimeSpan.FromHours(1); // Auto logout if idle for 1 hour
    });

builder.Services.AddAuthorization();

builder.Services.AddSingleton<IQueryStringEncryptionService, QueryStringEncryptionService>();

var app = builder.Build();

if (!app.Environment.IsDevelopment() && !string.IsNullOrWhiteSpace(licensingOptions.EmailPickupDirectory))
    app.Logger.LogWarning("Licensing:EmailPickupDirectory is ignored outside Development; licence e-mails are sent by SMTP.");
if (!licensingOptions.Enabled)
    app.Logger.LogWarning("eCare360 licensing is skipped: Debug build (developer run). Set Licensing__EnforceInDebug=true to test it; a Release build always enforces it.");
else
{
    if (licensingOptions.ConfigurationProblem != null)
        app.Logger.LogError("eCare360 licensing is not configured, every page is blocked until it is: {Problem}", licensingOptions.ConfigurationProblem);
    app.Logger.LogInformation("eCare360 licensing: licence database {Database} (login from {LoginSource}); local keys {KeyLocation}.",
        licensingOptions.CentralDatabase, licensingOptions.CentralLoginSource, licensingOptions.LocalKeyLocation ?? "from configuration");
}

// licensing on: read the hardware fingerprint and make sure the local licence tables exist, off the request path
if (licensingOptions.Enabled)
{
    _ = Task.Run(async () =>
    {
        try
        {
            _ = app.Services.GetRequiredService<EMR.Web.Services.Licensing.IMachineFingerprintProvider>().Current;
            await app.Services.GetRequiredService<EMR.Web.Services.Licensing.ILocalLicenseRepository>().EnsureSchemaAsync();
        }
        catch (Exception ex) { app.Logger.LogWarning(ex, "Licensing warm-up failed; it is retried on the first request."); }
    });
}

// Configure the HTTP request pipeline.

// Trust X-Forwarded-For / X-Forwarded-Proto from any proxy (IIS, Nginx, load balancer)
var fwdOptions = new ForwardedHeadersOptions
{
    ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto
};
fwdOptions.KnownNetworks.Clear();   // accept from any network/proxy
fwdOptions.KnownProxies.Clear();
app.UseForwardedHeaders(fwdOptions);

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Home/Error");
    // The default HSTS value is 30 days. You may want to change this for production scenarios, see https://aka.ms/aspnetcore-hsts.
    app.UseHsts();
}

app.UseHttpsRedirection();

// A static file asked for with a version in its address (…?v=<hash> from asp-append-version, a library version,
// or the hash a stylesheet puts on its font files) never changes under that address, so the browser may keep it
// instead of re-checking it with the server on every page. A new build changes the address, so nothing goes stale.
app.Use(async (context, next) =>
{
    if (HttpMethods.IsGet(context.Request.Method) && context.Request.QueryString.HasValue)
    {
        var path = context.Request.Path.Value ?? string.Empty;
        var isFont = path.EndsWith(".woff2", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".woff", StringComparison.OrdinalIgnoreCase);
        var isVersionedAsset = context.Request.Query.ContainsKey("v")
            && (path.EndsWith(".js", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".css", StringComparison.OrdinalIgnoreCase));
        if (isFont || isVersionedAsset)
        {
            context.Response.OnStarting(() =>
            {
                if (context.Response.StatusCode == StatusCodes.Status200OK)
                    context.Response.Headers.CacheControl = "public, max-age=31536000, immutable";
                return Task.CompletedTask;
            });
        }
    }

    await next();
});

app.UseRouting();
app.UseRateLimiter();
app.UseMiddleware<EMR.Web.Middleware.QueryStringDecryptionMiddleware>();
app.UseSession();

app.UseAuthentication();

app.Use(async (context, next) =>
{
    var user = context.User;
    if (user.Identity?.IsAuthenticated == true)
    {
        var path = context.Request.Path.Value?.ToLowerInvariant() ?? string.Empty;
        var isAccountFlow = path.StartsWith("/account/login")
                         || path.StartsWith("/account/logout")
                         || path.StartsWith("/account/selectbranch")
                         || path.StartsWith("/account/selectrole")
                         || path.StartsWith("/account/sessiontimeoutlogout");

        var isStaticAsset = path.StartsWith("/css/")
                         || path.StartsWith("/js/")
                         || path.StartsWith("/lib/")
                         || path.StartsWith("/images/")
                         || path.StartsWith("/uploads/")
                         || path.Contains(".css")
                         || path.Contains(".js")
                         || path.Contains(".png")
                         || path.Contains(".jpg")
                         || path.Contains(".jpeg")
                         || path.Contains(".svg")
                         || path.Contains(".ico")
                         || path.Contains(".woff")
                         || path.Contains(".woff2");

        if (!isAccountFlow && !isStaticAsset)
        {
            var userIdClaim = user.FindFirstValue(ClaimTypes.NameIdentifier);
            var branchIdClaim = user.FindFirstValue("BranchId");
            var activeRole = user.FindFirstValue("ActiveRole");
            var isSuperAdmin = user.HasClaim("IsSuperAdmin", "true") || user.IsInRole("SuperAdmin");

            var userIdParsed = int.TryParse(userIdClaim, out var userId);
            var branchIdParsed = int.TryParse(branchIdClaim, out var branchId);
            var isValid = userIdParsed && branchIdParsed;

            if (isValid)
            {
                var db = context.RequestServices.GetRequiredService<ApplicationDbContext>();

                var hasActiveBranch = await db.UserBranches
                    .Include(x => x.Branch)
                    .AnyAsync(x => x.UserId == userId
                                   && x.BranchId == branchId
                                   && x.IsActive
                                   && x.Branch.IsActive);

                if (!hasActiveBranch)
                {
                    isValid = false;
                }

                var hasValidRole = isSuperAdmin;
                if (!hasValidRole)
                {
                    hasValidRole = !string.IsNullOrWhiteSpace(activeRole)
                        && await db.UserRoles
                            .Where(x => x.UserId == userId && x.IsActive)
                            .Join(db.Roles, ur => ur.RoleId, r => r.Id, (ur, r) => r.Name)
                            .AnyAsync(x => x == activeRole);
                }

                if (!hasValidRole)
                {
                    isValid = false;
                }
            }

            if (!isValid)
            {
                await context.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
                context.Response.Redirect("/Account/Login");
                return;
            }
        }
    }

    await next();
});

// eCare360 licence gate: after sign-in (so a blocked licence signs the user out), before authorization
app.UseMiddleware<EMR.Web.Middleware.LicensingMiddleware>();

app.UseAuthorization();

app.MapStaticAssets();

app.MapControllerRoute(
    name: "default",
    pattern: "{controller=Account}/{action=Login}/{id?}")
    .WithStaticAssets();


app.MapHub<EMR.Web.Services.Notifications.NotificationHub>("/hubs/notifications");

app.Run();
