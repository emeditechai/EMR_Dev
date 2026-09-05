using Microsoft.AspNetCore.Mvc.Filters;
using EMR.Web.Services;

namespace EMR.Web.Filters;

public class GlobalAuditLogFilter(IAuditLogService auditLogService) : IAsyncActionFilter
{
    public async Task OnActionExecutionAsync(ActionExecutingContext context, ActionExecutionDelegate next)
    {
        // Execute the action first
        var resultContext = await next();

        var httpContext = context.HttpContext;
        var request = httpContext.Request;

        // Skip AJAX/Fetch requests to reduce noise
        if (request.Headers.XRequestedWith == "XMLHttpRequest" || 
            (request.Headers.Accept.ToString()?.Contains("application/json") == true))
        {
            return;
        }

        var controllerName = context.RouteData.Values["controller"]?.ToString();
        var actionName = context.RouteData.Values["action"]?.ToString();

        // Skip noisy/unnecessary controllers
        var ignoredControllers = new[] { "AuditLogs", "Auth", "Home", "Error" };
        if (controllerName == null || ignoredControllers.Contains(controllerName, StringComparer.OrdinalIgnoreCase))
        {
            return;
        }

        // To prevent massive duplication with manual POST logging, we focus on GET requests (page views)
        if (request.Method == "GET")
        {
            string eventType = $"{controllerName}";
            string action = $"{controllerName}.{actionName}";
            string description = $"Viewed {controllerName} > {actionName} page";

            try 
            {
                await auditLogService.LogAsync(eventType, action, description);
            }
            catch 
            {
                // Ignore logging errors to not break the application flow
            }
        }
    }
}
