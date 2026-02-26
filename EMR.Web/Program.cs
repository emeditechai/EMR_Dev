using EMR.Web.Data;
using EMR.Web.Services;
using EMR.Web.Services.Geography;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.EntityFrameworkCore;
using System.Security.Claims;

var builder = WebApplication.CreateBuilder(args);

// Add services to the container.
builder.Services.AddControllersWithViews();
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
builder.Services.AddScoped<IDepartmentService, DepartmentService>();
builder.Services.AddScoped<IDoctorService, DoctorService>();
builder.Services.AddScoped<IFloorService, FloorService>();
builder.Services.AddScoped<IDoctorRoomService, DoctorRoomService>();

builder.Services.AddHttpContextAccessor();

builder.Services.AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme)
    .AddCookie(options =>
    {
        options.LoginPath = "/Account/Login";
        options.AccessDeniedPath = "/Account/Login";
        options.SlidingExpiration = true;
        options.ExpireTimeSpan = TimeSpan.FromHours(8);
    });

builder.Services.AddAuthorization();

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
