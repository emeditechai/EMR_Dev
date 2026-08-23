using EMR.Web.Services;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Primitives;

namespace EMR.Web.Middleware;

public class QueryStringDecryptionMiddleware(RequestDelegate next)
{
    public async Task InvokeAsync(HttpContext context, IQueryStringEncryptionService encryptionService)
    {
        // 1. Check if 'q' or 'enc' query parameter is present in the request
        if (context.Request.Query.TryGetValue("q", out var encValue) ||
            context.Request.Query.TryGetValue("enc", out encValue))
        {
            string cipherText = encValue.ToString();
            if (!string.IsNullOrEmpty(cipherText))
            {
                var decryptedDict = encryptionService.DecryptToDictionary(cipherText);
                if (decryptedDict.Count > 0)
                {
                    // Merge decrypted parameters into HttpContext.Request.Query
                    var queryDict = new Dictionary<string, StringValues>(context.Request.Query, StringComparer.OrdinalIgnoreCase);

                    foreach (var kvp in decryptedDict)
                    {
                        queryDict[kvp.Key] = new StringValues(kvp.Value);
                        if (kvp.Key.Equals("id", StringComparison.OrdinalIgnoreCase))
                        {
                            context.Request.RouteValues["id"] = kvp.Value;
                        }
                    }

                    context.Request.Query = new QueryCollection(queryDict);
                }
            }
        }
        else if (context.Request.Query.Count > 0)
        {
            // 2. Check if a direct encrypted string was passed e.g. ?ENC_DATA or key-value where value is encrypted
            // If any individual parameter value looks encrypted or single positional param exists
            var queryDict = new Dictionary<string, StringValues>(context.Request.Query, StringComparer.OrdinalIgnoreCase);
            bool updated = false;

            foreach (var kvp in context.Request.Query)
            {
                // Try decrypting parameter value or key
                string val = kvp.Value.ToString();
                if (!string.IsNullOrEmpty(val))
                {
                    var decrypted = encryptionService.DecryptToDictionary(val);
                    if (decrypted.Count > 0)
                    {
                        foreach (var d in decrypted)
                        {
                            queryDict[d.Key] = new StringValues(d.Value);
                        }
                        updated = true;
                    }
                    else
                    {
                        string singleDec = encryptionService.Decrypt(val);
                        if (!string.IsNullOrEmpty(singleDec))
                        {
                            queryDict[kvp.Key] = new StringValues(singleDec);
                            updated = true;
                        }
                    }
                }
            }

            if (updated)
            {
                context.Request.Query = new QueryCollection(queryDict);
            }
        }

        await next(context);
    }
}
