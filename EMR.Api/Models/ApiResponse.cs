namespace EMR.Api.Models;

/// <summary>Uniform JSON envelope returned by all API endpoints.</summary>
public class ApiResponse<T>
{
    public bool   Success { get; set; }
    public string Message { get; set; } = string.Empty;
    public T?     Data    { get; set; }

    public static ApiResponse<T> Ok(T data, string message = "Success")
        => new() { Success = true,  Message = message, Data = data };

    public static ApiResponse<T> Fail(string message)
        => new() { Success = false, Message = message };
}

public class ApiResponse : ApiResponse<object>
{
    public static ApiResponse Ok(string message = "Success")
        => new() { Success = true, Message = message };

    public new static ApiResponse Fail(string message)
        => new() { Success = false, Message = message };
}
