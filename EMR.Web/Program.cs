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

// Cancellation & Refund (Dapper)
builder.Services.AddScoped<ICancellationService, CancellationService>();


// Email (SMTP)
builder.Services.AddScoped<IEmailService, EmailService>();

// WhatsApp Notification Service
builder.Services.AddScoped<IWhatsAppService, WhatsAppService>();

// Video Consultation (Whereby)
builder.Services.AddHttpClient("Whereby", client =>
{
    client.BaseAddress = new Uri("https://api.whereby.dev/");
    client.DefaultRequestHeaders.Add("Accept", "application/json");
});
builder.Services.AddScoped<IWherebyService, WherebyService>();
builder.Services.AddScoped<IVideoConsultationService, VideoConsultationService>();

// Sign-in throttling per client address (staff and patient portal sign-in; accounts also lock after repeated wrong passwords)
builder.Services.AddRateLimiter(o =>
{
    o.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    o.AddPolicy(EMR.Web.Controllers.AccountController.SignInRateLimit, http =>
        System.Threading.RateLimiting.RateLimitPartition.GetFixedWindowLimiter(http.Connection.RemoteIpAddress?.ToString() ?? "unknown",
            _ => new System.Threading.RateLimiting.FixedWindowRateLimiterOptions { PermitLimit = 60, Window = TimeSpan.FromMinutes(1), QueueLimit = 0 }));
    o.OnRejected = async (ctx, ct) =>
    {
        ctx.HttpContext.Response.Headers.RetryAfter = "60";
        ctx.HttpContext.Response.ContentType = "text/plain; charset=utf-8";
        await ctx.HttpContext.Response.WriteAsync("Too many sign-in attempts from this network. Wait a minute and try again.", ct);
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
builder.Services.AddScoped<ILabSampleRejectionReasonApiClient, LabSampleRejectionReasonApiClient>();
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
builder.Services.AddScoped<ILabCriticalNotificationService,   LabCriticalNotificationService>();
builder.Services.AddScoped<IDiscountTypeApiClient,        DiscountTypeApiClient>();

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

app.UseAuthorization();

app.MapStaticAssets();

app.MapControllerRoute(
    name: "default",
    pattern: "{controller=Account}/{action=Login}/{id?}")
    .WithStaticAssets();


app.Run();
