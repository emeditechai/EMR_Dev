using System;
using System.Data.SqlClient;

class Program {
    static void Main() {
        var cs = "Server=103.178.113.61,1232;Database=Dev_EMR;User Id=sa;Password=Ehospit@lity@#1926;TrustServerCertificate=True;MultipleActiveResultSets=True;";
        using (var conn = new SqlConnection(cs)) {
            conn.Open();
            var cmd = new SqlCommand("SELECT DoctorId, FullName, PrimarySpecialityId FROM DoctorMaster WHERE IsActive = 1;", conn);
            using (var reader = cmd.ExecuteReader()) {
                while(reader.Read()) {
                    Console.WriteLine($"{reader["DoctorId"]} | {reader["FullName"]} | {reader["PrimarySpecialityId"]}");
                }
            }
        }
    }
}
