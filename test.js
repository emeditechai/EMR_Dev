const currentSchedules = [
  {
    scheduleId: 1, doctorId: 2, doctorName: "Purojit Bhar", branchId: 1, dayOfWeek: 1, dayName: "Monday",
    startTime: "11:15:00", endTime: "13:15:00", slotDurationMinutes: 15, maxPatientsPerSlot: 20, maxPatientsPerSession: null,
    roomName: null, scheduleType: "OPD", effectiveFrom: "2026-06-12T00:00:00", effectiveTo: "2026-06-30T00:00:00", isActive: true
  },
  {
    scheduleId: 2, doctorId: 2, doctorName: "Purojit Bhar", branchId: 1, dayOfWeek: 2, dayName: "Tuesday",
    startTime: "11:15:00", endTime: "13:15:00", slotDurationMinutes: 15, maxPatientsPerSlot: 1, maxPatientsPerSession: 50,
    roomName: null, scheduleType: "OPD", effectiveFrom: "2026-06-12T00:00:00", effectiveTo: "2026-06-30T00:00:00", isActive: true
  },
  {
    scheduleId: 3, doctorId: 2, doctorName: "Purojit Bhar", branchId: 1, dayOfWeek: 3, dayName: "Wednesday",
    startTime: "11:15:00", endTime: "13:15:00", slotDurationMinutes: 15, maxPatientsPerSlot: 20, maxPatientsPerSession: null,
    roomName: null, scheduleType: "OPD", effectiveFrom: "2026-06-12T00:00:00", effectiveTo: "2026-06-30T00:00:00", isActive: true
  }
];

const today = new Date(2026, 5, 12); // June 12
const startR = new Date(today.getFullYear(), today.getMonth() - 1, 1);
const endR = new Date(today.getFullYear(), today.getMonth() + 6, 0);

const events = [];

function fmtDate(d) {
    return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
}

currentSchedules.forEach(sch => {
    let jsDay   = sch.dayOfWeek === 7 ? 0 : sch.dayOfWeek;
    let effFrom = new Date(sch.effectiveFrom);
    let effTo   = sch.effectiveTo ? new Date(sch.effectiveTo) : endR;

    for (let d = new Date(startR); d <= endR; d.setDate(d.getDate() + 1)) {
        if (d.getDay() !== jsDay || d < effFrom || d > effTo) continue;

        const dateStr   = fmtDate(d);
        events.push({
            start: `${dateStr}T${sch.startTime}`,
        });
    }
});

console.log(events.length, "events generated");
console.log(events);
