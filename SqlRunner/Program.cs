using System;
using Microsoft.Data.SqlClient;

var cs = "Server=103.178.113.61,1232;Database=Dev_EMR;User Id=sa;Password=Ehospit@lity@#1926;TrustServerCertificate=True;MultipleActiveResultSets=True;";

using var conn = new SqlConnection(cs);
conn.Open();

Console.WriteLine("=== VERIFYING GetHistoryByTariffId QUERY WITH USERS TABLE ===");

var sql = @"
    SELECT 
        h.HistoryId,
        h.BedRateId,
        h.EffectiveFrom,
        h.EffectiveTo,
        h.RoomCharge,
        h.BedCharge,
        h.NursingCharge,
        h.AttendantCharge,
        h.IsolationCharge,
        h.GstPercentage,
        h.IsActive,
        h.ChangeAction,
        h.ChangeReason,
        COALESCE(u.FullName, u.FirstName + ' ' + u.LastName, u.Username, 'System Admin') AS ChangedByName,
        h.ChangedDate
    FROM BedRoomTariffHistory h
    LEFT JOIN Users u ON h.ChangedBy = u.Id
    WHERE h.BedRateId = 1
    ORDER BY h.ChangedDate DESC, h.HistoryId DESC";

using (var cmd = new SqlCommand(sql, conn))
using (var reader = cmd.ExecuteReader())
{
    while (reader.Read())
    {
        Console.WriteLine($"✓ History ID: {reader["HistoryId"]} | Rate ID: {reader["BedRateId"]} | Action: {reader["ChangeAction"]} | ChangedBy: {reader["ChangedByName"]} | Date: {reader["ChangedDate"]}");
    }
}

Console.WriteLine("=== QUERY EXECUTED SUCCESSFULLY WITHOUT ANY ERRORS ===");
