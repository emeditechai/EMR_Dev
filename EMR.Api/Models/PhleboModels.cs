namespace EMR.Api.Models;

public sealed class PhleboDeviceRequest
{
    public string? DeviceName { get; set; }
    public string? Platform { get; set; }
    public string? AppVersion { get; set; }
}

public class PhleboGpsRequest
{
    public DateTime? DeviceTime { get; set; }
    public decimal? Latitude { get; set; }
    public decimal? Longitude { get; set; }
    public decimal? AccuracyM { get; set; }
    public bool IsMock { get; set; }
}

public sealed class PhleboPunchRequest : PhleboGpsRequest
{
    public string PunchType { get; set; } = "";
    public string ClientEventId { get; set; } = "";
    public decimal? Temperature { get; set; }
    public bool FieldStart { get; set; }
    public string? Reason { get; set; }
}

public sealed class PhleboLocationPoint
{
    public DateTime Time { get; set; }
    public decimal Lat { get; set; }
    public decimal Lng { get; set; }
    public decimal? Accuracy { get; set; }
    public decimal? Speed { get; set; }
    public bool Mock { get; set; }
}

public sealed class PhleboEventRequest : PhleboGpsRequest
{
    public string Status { get; set; } = "";
    public string ClientEventId { get; set; } = "";
    public string? Reason { get; set; }
}

/// <summary>Action: SEND, CHECK (with Code) or ID_PROOF (with Reason, after the ID photo is uploaded).</summary>
public sealed class PhleboVerifyRequest
{
    public string Action { get; set; } = "";
    public string? Code { get; set; }
    public string? Reason { get; set; }
}

public sealed class PhleboTube
{
    public long SampleCollectionId { get; set; }
    public bool Collected { get; set; }
    public string? Barcode { get; set; }
    public int? ReasonId { get; set; }
    public string? Remarks { get; set; }
}

public sealed class PhleboSamplesRequest : PhleboGpsRequest
{
    public string ClientEventId { get; set; } = "";
    public List<PhleboTube> Tubes { get; set; } = new();
    public string? DueReason { get; set; }
}

public sealed class PhleboPaymentRequest
{
    public string ClientEventId { get; set; } = "";
    public string MethodCode { get; set; } = "";
    public decimal Amount { get; set; }
    public string? Reference { get; set; }
}

public sealed class PhleboBillChangeLine
{
    public string Action { get; set; } = "";
    public int InvestigationId { get; set; }
}

public sealed class PhleboBillChangeRequest
{
    public int VisitId { get; set; }
    public string ClientEventId { get; set; } = "";
    public string RequestType { get; set; } = "";
    public string Reason { get; set; } = "";
    public string? Details { get; set; }
    public List<PhleboBillChangeLine> Lines { get; set; } = new();
}

public sealed class PhleboHandoverRequest
{
    public string ClientEventId { get; set; } = "";
    public string ReceiverName { get; set; } = "";
    public decimal? TemperatureC { get; set; }
    public List<int> VisitIds { get; set; } = new();
}
