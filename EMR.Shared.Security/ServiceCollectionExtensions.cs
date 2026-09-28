using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace EMR.Shared.Security;

public static class ServiceCollectionExtensions
{
    /// <summary>
    /// Registers the decision point, the endpoint scanner and the decision log for one application.
    /// Add <see cref="PermissionFilter"/> to the MVC filters to enforce it on every action.
    /// </summary>
    public static IServiceCollection AddEmrAuthorization(this IServiceCollection services, IConfiguration configuration,
        string connectionStringName, EmrAuthorizationApp app)
    {
        var cs = configuration.GetConnectionString(connectionStringName)
                 ?? throw new InvalidOperationException($"Connection string '{connectionStringName}' is not configured.");

        services.Configure<EmrAuthorizationOptions>(configuration.GetSection(EmrAuthorizationOptions.SectionName));
        services.AddMemoryCache();
        services.AddSingleton(app);
        services.AddSingleton<IPermissionDataSource>(_ => new SqlPermissionDataSource(cs));
        services.AddSingleton<IPermissionService, PermissionService>();
        services.AddSingleton<DecisionLogWriter>();
        services.AddSingleton<IDecisionLogWriter>(sp => sp.GetRequiredService<DecisionLogWriter>());
        services.AddHostedService(sp => sp.GetRequiredService<DecisionLogWriter>());
        services.AddSingleton<EndpointInventoryService>();
        services.AddHostedService(sp => sp.GetRequiredService<EndpointInventoryService>());
        services.AddScoped<PermissionFilter>();
        services.AddSingleton<IActionPermissionGuard, ActionPermissionGuard>();

        // Tokens between EMR.Web and EMR.Api, api/auth, and the sign-in lockout.
        services.Configure<ApiAuthOptions>(configuration.GetSection(ApiAuthOptions.SectionName));
        services.AddSingleton<IApiTokenService, ApiTokenService>();
        services.AddSingleton<ILoginSecurity>(sp => new SqlLoginSecurity(cs, sp.GetRequiredService<Microsoft.Extensions.Options.IOptionsMonitor<ApiAuthOptions>>()));
        return services;
    }
}
