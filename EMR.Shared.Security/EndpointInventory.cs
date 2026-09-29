using System.Reflection;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc.ActionConstraints;
using Microsoft.AspNetCore.Mvc.Controllers;
using Microsoft.AspNetCore.Mvc.Infrastructure;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace EMR.Shared.Security;

/// <summary>
/// The endpoint scanner. On start-up it reads every controller action the application really
/// exposes (from routing, not from parsing source) and records it in PageEndpointMap: new ones as
/// unmapped, vanished ones as orphaned, mappings untouched. The unmapped count it reports is the
/// switch-on gate - enforcement waits until it reads zero.
/// </summary>
public sealed class EndpointInventoryService(
    IActionDescriptorCollectionProvider actions,
    IPermissionDataSource data,
    IHostApplicationLifetime lifetime,
    IOptionsMonitor<EmrAuthorizationOptions> options,
    EmrAuthorizationApp app,
    ILogger<EndpointInventoryService> logger) : IHostedService
{
    public Task StartAsync(CancellationToken cancellationToken)
    {
        if (!options.CurrentValue.ScanEndpointsOnStartup) return Task.CompletedTask;
        // Run once the app is up, so a slow database never delays start-up.
        lifetime.ApplicationStarted.Register(() => _ = Task.Run(ScanAsync));
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;

    public IReadOnlyList<DiscoveredEndpoint> Discover()
    {
        var found = new List<DiscoveredEndpoint>();
        foreach (var d in actions.ActionDescriptors.Items.OfType<ControllerActionDescriptor>())
        {
            var isPublic = d.EndpointMetadata.Any(m => m is PublicEndpointAttribute or IAllowAnonymous)
                           || d.ControllerTypeInfo.GetCustomAttribute<PublicEndpointAttribute>(true) != null;
            var verbs = d.ActionConstraints?.OfType<HttpMethodActionConstraint>().SelectMany(c => c.HttpMethods).Distinct().ToList();
            if (verbs is null || verbs.Count == 0) verbs = new List<string> { "GET" };
            var route = d.AttributeRouteInfo?.Template ?? $"{d.ControllerName}/{d.ActionName}";
            // An action that declares its page in code is mapped from the code.
            var declared = PermissionFilter.DeclaredTargets(d).FirstOrDefault();
            foreach (var v in verbs)
                found.Add(new DiscoveredEndpoint(v.ToUpperInvariant(), d.ControllerName, d.ActionName, route, isPublic,
                    declared.PageCode, declared.ControlCode));
        }
        return found.DistinctBy(f => (f.HttpMethod, f.Controller, f.Action)).ToList();
    }

    private async Task ScanAsync()
    {
        try
        {
            var found = Discover();
            var r = await data.RegisterDiscoveredEndpointsAsync(app.Name, found);
            logger.LogInformation("[AUTHZ] Endpoint inventory ({App}): {Found} endpoints, {Unmapped} unmapped, {Orphaned} orphaned, {Public} public.",
                app.Name, r.Found, r.Unmapped, r.Orphaned, r.Public);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "[AUTHZ] Endpoint inventory scan failed; the existing map is left as it is.");
        }
    }
}
