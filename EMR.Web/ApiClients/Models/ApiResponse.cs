namespace EMR.Web.ApiClients.Models;

/// <summary>Generic envelope returned by every EMR.Api endpoint.</summary>
public class ApiResponse<T>
{
    public bool    Success { get; set; }
    public string? Message { get; set; }
    public T?      Data    { get; set; }
}
