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
builder.Services.AddScoped<IPatientService,          PatientService>();
builder.Services.AddScoped<IServiceBookingService,   ServiceBookingService>();
builder.Services.AddScoped<IPaymentSummaryService,   PaymentSummaryService>();

// ── CORS (allow EMR.Web to call this API) ─────────────────────────────────────
builder.Services.AddCors(opt =>
    opt.AddPolicy("EmrWebOrigin", p =>
        p.WithOrigins(
            builder.Configuration["AllowedOrigins:EmrWeb"] ?? "https://localhost:5124",
            "http://localhost:5124")
         .AllowAnyHeader()
         .AllowAnyMethod()));

var app = builder.Build();

// ── Middleware ────────────────────────────────────────────────────────────────
if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI(c =>
    {
        c.SwaggerEndpoint("/swagger/v1/swagger.json", "EMR API v1");
        c.RoutePrefix = string.Empty; // Swagger at root
    });
}

app.UseHttpsRedirection();
app.UseCors("EmrWebOrigin");
app.UseAuthorization();
app.MapControllers();

app.Run();
