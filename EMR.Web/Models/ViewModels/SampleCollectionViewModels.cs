using System;
using System.Collections.Generic;
using EMR.Web.Models.DTOs;

namespace EMR.Web.Models.ViewModels
{
    public class SampleCollectionDashboardViewModel
    {
        public SampleCollectionStatsDto Stats { get; set; } = new();
        public List<SampleCollectionHeaderDto> Headers { get; set; } = new();
        public List<SampleCollectionStatusMasterDto> Statuses { get; set; } = new();

        public int BranchId { get; set; }
        public DateTime FromDate { get; set; }
        public DateTime ToDate { get; set; }
        public string DateFilterType { get; set; } = "BookingDate";
        public string StatusFilter { get; set; } = "All";
        public string? Search { get; set; }
    }

    public class BarcodeLabelPrintViewModel
    {
        public int LabOrderId { get; set; }
        public string BillNo { get; set; } = string.Empty;
        public string? TokenNo { get; set; }
        public string PatientCode { get; set; } = string.Empty;
        public string PatientName { get; set; } = string.Empty;
        public int? Age { get; set; }
        public string? Gender { get; set; }
        public string BarcodeNo { get; set; } = string.Empty;
        public string SampleTypeName { get; set; } = string.Empty;
        public string ContainerType { get; set; } = string.Empty;
        public string? CollectionDateTime { get; set; }
        public string? ProfileOrPackageName { get; set; }
        public List<string> TestNames { get; set; } = new();
    }
}
