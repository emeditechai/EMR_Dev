using System.Threading.RateLimiting;
using EMR.Api.Data;
using EMR.Api.Services;
using EMR.Shared.Security;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.OpenApi.Models;

var builder = WebApplication.CreateBuilder(args);

// ── Services ─────────────────────────────────────────────────────────────────
// ── Authentication: every call carries a token (see EMR.Api/Security/ApiCallerFilter) ──
builder.Services.AddEmrAuthorization(builder.Configuration, "DefaultConnection",
    new EmrAuthorizationApp { Name = "API", AlwaysJson = true });
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme).AddJwtBearer();
builder.Services.AddOptions<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme)
    .Configure<IApiTokenService>((o, tokens) =>
    {
        o.TokenValidationParameters = tokens.ValidationParameters();
        o.MapInboundClaims = true;   // "sub" -> NameIdentifier, as the web cookie carries it
    });
builder.Services.AddScoped<EMR.Api.Security.ApiCallerFilter>();

// Credential endpoints of api/auth: 20 requests a minute per client address.
builder.Services.AddRateLimiter(o =>
{
    o.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    o.AddPolicy(EMR.Api.Controllers.AuthController.RateLimitPolicy, http =>
        RateLimitPartition.GetFixedWindowLimiter(http.Connection.RemoteIpAddress?.ToString() ?? "unknown",
            _ => new FixedWindowRateLimiterOptions { PermitLimit = 20, Window = TimeSpan.FromMinutes(1), QueueLimit = 0 }));
    o.OnRejected = async (ctx, ct) =>
    {
        ctx.HttpContext.Response.Headers.RetryAfter = "60";
        await ctx.HttpContext.Response.WriteAsJsonAsync(
            new { success = false, code = "TOO_MANY_REQUESTS", message = "Too many attempts. Wait a minute and try again." }, ct);
    };
});

builder.Services.AddControllers(o => o.Filters.AddService<EMR.Api.Security.ApiCallerFilter>());
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(c =>
{
    c.SwaggerDoc("v1", new()
    {
        Title       = "EMR API",
        Version     = "v1",
        Description = "REST API for EMR system — Doctors, Patients and more."
    });
    // Include XML comments if available
    var xmlFile = $"{System.Reflection.Assembly.GetExecutingAssembly().GetName().Name}.xml";
    var xmlPath = Path.Combine(AppContext.BaseDirectory, xmlFile);
    if (File.Exists(xmlPath)) c.IncludeXmlComments(xmlPath);
    c.AddSecurityDefinition("Bearer", new OpenApiSecurityScheme
    {
        Type = SecuritySchemeType.Http, Scheme = "bearer", BearerFormat = "JWT",
        Description = "Access token from POST /api/auth/login."
    });
    c.AddSecurityRequirement(new OpenApiSecurityRequirement
    {
        [new OpenApiSecurityScheme { Reference = new OpenApiReference { Type = ReferenceType.SecurityScheme, Id = "Bearer" } }] = Array.Empty<string>()
    });
});

// ── Data & Application services ───────────────────────────────────────────────
builder.Services.AddSingleton<IDbConnectionFactory, DbConnectionFactory>();
builder.Services.AddScoped<IDoctorService,           DoctorService>();

builder.Services.AddScoped<IDiscountTypeService,     DiscountTypeService>();
builder.Services.AddScoped<IPatientService,          PatientService>();
builder.Services.AddScoped<IReportService,           ReportService>();
builder.Services.AddScoped<IServiceBookingService,   ServiceBookingService>();
builder.Services.AddScoped<IPaymentSummaryService,   PaymentSummaryService>();
builder.Services.AddScoped<IVitalService,            VitalService>();
builder.Services.AddScoped<IDoctorScheduleService,   DoctorScheduleService>();
builder.Services.AddScoped<IEmrConsultationService,  EmrConsultationService>();
builder.Services.AddScoped<IPatientPortalService,    PatientPortalService>();
builder.Services.AddScoped<IIpdMasterService,        IpdMasterService>();
builder.Services.AddScoped<ILabRateCardService,      LabRateCardService>();
builder.Services.AddScoped<ILabOrderService,         LabOrderService>();
builder.Services.AddScoped<ISampleCollectionService, SampleCollectionService>();
builder.Services.AddScoped<ISampleTransferService,   SampleTransferService>();
builder.Services.AddScoped<ILabReportingService,     LabReportingService>();
builder.Services.AddScoped<ILabDashboardService,     LabDashboardService>();
builder.Services.AddScoped<IHospitalPackageService,   HospitalPackageService>();
builder.Services.AddScoped<ICorporateService,         CorporateService>();
builder.Services.AddScoped<ICorporateHospitalRateService, CorporateHospitalRateService>();
builder.Services.AddScoped<IInsuranceTPAService,      InsuranceTPAService>();
builder.Services.AddScoped<IInsuranceTariffService,   InsuranceTariffService>();
builder.Services.AddScoped<IGovernmentSchemeService,  GovernmentSchemeService>();
builder.Services.AddScoped<IShiftMasterService,        ShiftMasterService>();
builder.Services.AddScoped<IHousekeepingService,       HousekeepingService>();
builder.Services.AddScoped<IConsentMasterService,      ConsentMasterService>();
builder.Services.AddScoped<IDoctorCommissionService,   DoctorCommissionService>();
builder.Services.AddScoped<IGeneralMasterService,    GeneralMasterService>();
builder.Services.AddScoped<IOpdMasterService,        OpdMasterService>();
builder.Services.AddScoped<ILabTestCategoryService,    LabTestCategoryService>();
builder.Services.AddScoped<ILabTestSubCategoryService, LabTestSubCategoryService>();
builder.Services.AddScoped<ILabSampleTypeService,      LabSampleTypeService>();
builder.Services.AddScoped<ILabTestMethodService,      LabTestMethodService>();
builder.Services.AddScoped<ILabUnitService,            LabUnitService>();
builder.Services.AddScoped<IAnalyzerService,           AnalyzerService>();
builder.Services.AddScoped<ILabInvestigationService,        LabInvestigationService>();
builder.Services.AddScoped<ILabInvestigationProfileService, LabInvestigationProfileService>();
builder.Services.AddScoped<ILabSampleRejectionService,      LabSampleRejectionService>();
builder.Services.AddScoped<ILabOrganismService, LabOrganismService>();
builder.Services.AddScoped<ILabAntibioticService, LabAntibioticService>();
builder.Services.AddScoped<ILabAntibioticPanelService, LabAntibioticPanelService>();
builder.Services.AddScoped<ILabParameterOptionService, LabParameterOptionService>();
builder.Services.AddScoped<ILabExpertRuleService, LabExpertRuleService>();
builder.Services.AddScoped<ILabBreakpointService, LabBreakpointService>();
builder.Services.AddScoped<IDoctorIpService, DoctorIpService>();
builder.Services.AddScoped<IDoctorIpCommissionService, DoctorIpCommissionService>();
builder.Services.AddScoped<ILabSampleRejectionReasonService,LabSampleRejectionReasonService>();
builder.Services.AddScoped<ILabFranchiseService,            LabFranchiseService>();
builder.Services.AddScoped<ILabFranchiseBarcodeService,      LabFranchiseBarcodeService>();
builder.Services.AddScoped<ILabReferenceRangeService,        LabReferenceRangeService>();
builder.Services.AddScoped<ILabFormulaParameterService,      LabFormulaParameterService>();
builder.Services.AddScoped<ILabDescriptiveTestTemplateService, LabDescriptiveTestTemplateService>();
builder.Services.AddScoped<ILabReportingConditionService,     LabReportingConditionService>();
builder.Services.AddScoped<ILabReportDispatchService,              LabReportDispatchService>();
builder.Services.AddScoped<ILabUnapproveService,                  LabUnapproveService>();
builder.Services.AddScoped<IPathologistDashboardService,          PathologistDashboardService>();
builder.Services.AddScoped<ILabDefaultSignatoryService,           LabDefaultSignatoryService>();
builder.Services.AddScoped<ILabApprovalFlowService,                LabApprovalFlowService>();
builder.Services.AddScoped<IB2BBillingService,              B2BBillingService>();

// Lab master bulk upload (Excel)
builder.Services.AddScoped<EMR.Api.Services.BulkUpload.LabBulkLookups>();
builder.Services.AddScoped<EMR.Api.Services.BulkUpload.ILabBulkUploadHandler, EMR.Api.Services.BulkUpload.TestMethodBulkHandler>();
builder.Services.AddScoped<EMR.Api.Services.BulkUpload.ILabBulkUploadHandler, EMR.Api.Services.BulkUpload.SubCategoryBulkHandler>();
builder.Services.AddScoped<EMR.Api.Services.BulkUpload.ILabBulkUploadHandler, EMR.Api.Services.BulkUpload.InvestigationBulkHandler>();
builder.Services.AddScoped<EMR.Api.Services.BulkUpload.ILabBulkUploadHandler, EMR.Api.Services.BulkUpload.FranchiseBulkHandler>();
builder.Services.AddScoped<EMR.Api.Services.BulkUpload.ILabBulkUploadHandler, EMR.Api.Services.BulkUpload.InvestigationProfileBulkHandler>();
builder.Services.AddScoped<EMR.Api.Services.BulkUpload.ILabBulkUploadHandler>(sp => new EMR.Api.Services.BulkUpload.RateCardBulkHandler(
    sp.GetRequiredService<ILabRateCardService>(), sp.GetRequiredService<EMR.Api.Services.BulkUpload.LabBulkLookups>(), EMR.Api.Services.BulkUpload.RateCardBulkHandler.B2C));
builder.Services.AddScoped<EMR.Api.Services.BulkUpload.ILabBulkUploadHandler>(sp => new EMR.Api.Services.BulkUpload.RateCardBulkHandler(
    sp.GetRequiredService<ILabRateCardService>(), sp.GetRequiredService<EMR.Api.Services.BulkUpload.LabBulkLookups>(), EMR.Api.Services.BulkUpload.RateCardBulkHandler.Franchise));
builder.Services.AddScoped<ILabBulkUploadService,             LabBulkUploadService>();

// ── CORS (allow EMR.Web to call this API) ─────────────────────────────────────
builder.Services.AddCors(opt =>
    opt.AddPolicy("EmrWebOrigin", p =>
        p.WithOrigins(
            builder.Configuration["AllowedOrigins:EmrWeb"] ?? "https://localhost:5124",
            "http://localhost:5124")
         .AllowAnyHeader()
         .AllowAnyMethod()));

builder.Services.AddSingleton<IQueryStringEncryptionService, QueryStringEncryptionService>();
builder.Services.AddHostedService<DoctorIpCommissionBackgroundService>();

var app = builder.Build();

// ── Middleware ────────────────────────────────────────────────────────────────
// The API description is published in Development, elsewhere only with Swagger:Enabled = true.
if (app.Environment.IsDevelopment() || app.Configuration.GetValue<bool>("Swagger:Enabled"))
{
    app.UseSwagger();
    app.UseSwaggerUI(c =>
    {
        c.SwaggerEndpoint("/swagger/v1/swagger.json", "EMR API v1");
    });
}

app.UseHttpsRedirection();
app.UseMiddleware<EMR.Api.Middleware.QueryStringDecryptionMiddleware>();
app.UseCors("EmrWebOrigin");
app.UseRateLimiter();
app.UseAuthentication();
app.UseAuthorization();
app.MapControllers();

app.Run();
