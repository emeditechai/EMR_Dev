using System;
using System.Collections.Generic;
using Microsoft.AspNetCore.Mvc.Rendering;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.Models.ViewModels
{
    public class DoctorScheduleIndexViewModel
    {
        public int DoctorId { get; set; }
        public string DoctorName { get; set; }
        public List<DoctorScheduleListItem> Schedules { get; set; } = new List<DoctorScheduleListItem>();
        public List<DoctorScheduleExceptionListItem> Exceptions { get; set; } = new List<DoctorScheduleExceptionListItem>();

        // For the dropdowns in the modals
        public SelectList DayOfWeekOptions { get; set; }
        public SelectList RoomOptions { get; set; }
    }
}
