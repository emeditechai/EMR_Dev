using EMR.Api.Services;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Primitives;

namespace EMR.Api.Middleware;

public class QueryStringDecryptionMiddleware(RequestDelegate next)
{
    public async Task InvokeAsync(HttpContext context, IQueryStringEncryptionService encryptionService)
    {
        if (context.Request.Query.TryGetValue("q", out var encValue) ||
            context.Request.Query.TryGetValue("enc", out encValue))
        {
            string cipherText = encValue.ToString();
            if (!string.IsNullOrEmpty(cipherText))
            {
                var decryptedDict = encryptionService.DecryptToDictionary(cipherText);
                if (decryptedDict.Count > 0)
                {
                    var queryDict = new Dictionary<string, StringValues>(context.Request.Query, StringComparer.OrdinalIgnoreCase);
                    foreach (var kvp in decryptedDict)
                    {
                        queryDict[kvp.Key] = new StringValues(kvp.Value);
                    }
                    context.Request.Query = new QueryCollection(queryDict);
                }
            }
        }

        await next(context);
    }
}
