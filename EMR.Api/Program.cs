using EMR.Api.Data;
using EMR.Api.Services;

var builder = WebApplication.CreateBuilder(args);

// ── Services ─────────────────────────────────────────────────────────────────
builder.Services.AddControllers();
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
builder.Services.AddScoped<ILabInvestigationService,     LabInvestigationService>();
builder.Services.AddScoped<ILabInvestigationProfileService, LabInvestigationProfileService>();

// ── CORS (allow EMR.Web to call this API) ─────────────────────────────────────
builder.Services.AddCors(opt =>
    opt.AddPolicy("EmrWebOrigin", p =>
        p.WithOrigins(
            builder.Configuration["AllowedOrigins:EmrWeb"] ?? "https://localhost:5124",
            "http://localhost:5124")
         .AllowAnyHeader()
         .AllowAnyMethod()));

builder.Services.AddSingleton<IQueryStringEncryptionService, QueryStringEncryptionService>();

var app = builder.Build();

// ── Middleware ────────────────────────────────────────────────────────────────
app.UseSwagger();
app.UseSwaggerUI(c =>
{
    c.SwaggerEndpoint("/swagger/v1/swagger.json", "EMR API v1");
});

app.UseHttpsRedirection();
app.UseMiddleware<EMR.Api.Middleware.QueryStringDecryptionMiddleware>();
app.UseCors("EmrWebOrigin");
app.UseAuthorization();
app.MapControllers();

app.Run();
