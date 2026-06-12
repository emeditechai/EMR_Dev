using System;
using System.Collections.Generic;
using System.ComponentModel.DataAnnotations;

namespace EMR.Api.Models
{
    public class DoctorScheduleListItem
    {
        public int ScheduleId { get; set; }
        public int DoctorId { get; set; }
        public string? DoctorName { get; set; }
        public int BranchId { get; set; }
        public byte DayOfWeek { get; set; }
        public string? DayName { get; set; }
        public TimeSpan StartTime { get; set; }
        public TimeSpan EndTime { get; set; }
        public int SlotDurationMinutes { get; set; }
        public int MaxPatientsPerSlot { get; set; }
        public int? MaxPatientsPerSession { get; set; }
        public string? RoomName { get; set; }
        public string? ScheduleType { get; set; }
        public DateTime EffectiveFrom { get; set; }
        public DateTime? EffectiveTo { get; set; }
        public bool IsActive { get; set; }
    }

    public class DoctorScheduleDetail : DoctorScheduleListItem
    {
        public int? RoomId { get; set; }
    }

    public class DoctorScheduleUpsertRequest
    {
        public int ScheduleId { get; set; }
        [Required]
        public int DoctorId { get; set; }
        [Required]
        public int BranchId { get; set; }
        public int? RoomId { get; set; }
        [Required]
        public byte DayOfWeek { get; set; }
        [Required]
        public TimeSpan StartTime { get; set; }
        [Required]
        public TimeSpan EndTime { get; set; }
        [Required]
        public int SlotDurationMinutes { get; set; }
        [Required]
        public int MaxPatientsPerSlot { get; set; }
        public int? MaxPatientsPerSession { get; set; }
        public string ScheduleType { get; set; } = "OPD";
        [Required]
        public DateTime EffectiveFrom { get; set; }
        public DateTime? EffectiveTo { get; set; }
        [Required]
        public int RequestedByUserId { get; set; }
    }

    public class AvailableSlot
    {
        public int ScheduleId { get; set; }
        public string? SlotTime { get; set; }
        public int BookedCount { get; set; }
        public int MaxPerSlot { get; set; }
        public bool IsAvailable { get; set; }
    }

    public class AvailableSlotsResult
    {
        public DateTime Date { get; set; }
        public int DoctorId { get; set; }
        public string? DoctorName { get; set; }
        public bool HasException { get; set; }
        public string? ExceptionReason { get; set; }
        public List<AvailableSlot> Slots { get; set; } = new List<AvailableSlot>();
    }

    public class DoctorScheduleExceptionListItem
    {
        public int ExceptionId { get; set; }
        public int DoctorId { get; set; }
        public string? DoctorName { get; set; }
        public int BranchId { get; set; }
        public DateTime ExceptionDate { get; set; }
        public string? Reason { get; set; }
        public string? ExceptionType { get; set; }
    }

    public class DoctorScheduleExceptionUpsertRequest
    {
        public int ExceptionId { get; set; }
        [Required]
        public int DoctorId { get; set; }
        [Required]
        public int BranchId { get; set; }
        [Required]
        public DateTime ExceptionDate { get; set; }
        public string? Reason { get; set; }
        public string ExceptionType { get; set; } = "Leave";
        [Required]
        public int RequestedByUserId { get; set; }
    }
}
