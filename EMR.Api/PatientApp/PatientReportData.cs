using System.Text.Json;
using EMR.Api.Services;
using EMR.Common;

namespace EMR.Api.PatientApp;

/// <summary>
/// What EMR.Web's report code reads from this API over HTTP (api/LabReporting, api/LabOrders, api/lab-parameter-options,
/// conditions of reporting, print templates), read here from the same services and handed over in EMR.Web's shapes (the
/// JSON EMR.Web would have received), so the copied report builder sees exactly the same data.
/// </summary>
public sealed class PatientReportData(
    ILabReportingService reporting,
    ILabOrderService orders,
    ILabReportingConditionService conditions,
    ILabParameterOptionService parameterOptions,
    IPrintTemplateService printTemplates,
    ILabReportDispatchService dispatch,
    IServiceBookingService serviceBookings)
{
    private static readonly JsonSerializerOptions Web = new(JsonSerializerDefaults.Web);

    // the service's object, as EMR.Web reads it from the API's JSON
    private static T? As<T>(object? value) where T : class =>
        value is null ? null : JsonSerializer.Deserialize<T>(JsonSerializer.Serialize(value, value.GetType(), Web), Web);

    public async Task<LabReportingOrderDetailDto?> GetDetailAsync(int labOrderId, int? branchId = null, string? reportingType = "Numeric") =>
        As<LabReportingOrderDetailDto>(await reporting.GetDetailAsync(labOrderId, branchId, reportingType));

    public async Task<LabReportPrintMetaDto?> GetPrintMetaAsync(int labOrderId) =>
        As<LabReportPrintMetaDto>(await reporting.GetPrintMetaAsync(labOrderId));

    public async Task<List<LabReportSignoffLevelDto>> GetSignoffPanelAsync(int labOrderId, int? branchId = null, int? departmentId = null, string? reportingType = null) =>
        As<List<LabReportSignoffLevelDto>>(await reporting.GetSignoffPanelAsync(labOrderId, branchId, departmentId, reportingType)) ?? [];

    public async Task<LabOrderDetailDto?> GetOrderDetailAsync(int labOrderId) =>
        As<LabOrderDetailDto>(await orders.GetOrderDetailAsync(labOrderId));

    public async Task<LabReportConditionsForReportModel?> GetForReportAsync(int companyId, int? branchId) =>
        As<LabReportConditionsForReportModel>(await conditions.GetForReportAsync(companyId, branchId));

    public async Task<IEnumerable<LabParameterOptionModel>> GetListAsync(bool? status = null, string? search = null, int? companyId = null, int? test_ID = null) =>
        As<List<LabParameterOptionModel>>(await parameterOptions.GetListAsync(status, search, companyId, test_ID)) ?? [];

    public async Task<IEnumerable<LabReportDispatchTestDto>> GetBillTestsAsync(int labOrderId) =>
        As<List<LabReportDispatchTestDto>>(await dispatch.GetBillTestsAsync(labOrderId)) ?? [];

    public async Task<ServiceBookingDetail?> GetServiceBookingAsync(int opdServiceId) =>
        As<ServiceBookingDetail>(await serviceBookings.GetByIdAsync(opdServiceId));

    /// <summary>The branch's published print template of a kind ("REPORT" / "BILL"); null = the Classic print.</summary>
    public async Task<PrintLayout?> ResolveTemplateAsync(int branchId, string kind)
    {
        if (branchId <= 0) return null;
        try { return PrintLayout.Parse((await printTemplates.ResolveAsync(branchId, kind))?.LayoutJson); }
        catch { return null; }   // never stop a print: the Classic header / footer is used
    }
}
