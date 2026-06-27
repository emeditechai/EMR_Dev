#r "nuget: Microsoft.Data.SqlClient, 5.1.1"
#r "nuget: Dapper, 2.0.123"
using System;
using System.Data.SqlClient;
using Dapper;

var cs = "Server=103.178.113.61,1232;Database=Dev_EMR;User Id=sa;Password=Ehospit@lity@#1926;TrustServerCertificate=True;MultipleActiveResultSets=True;";
using (var con = new SqlConnection(cs)) {
    con.Open();
    var rows = con.Query(@"
        SELECT DISTINCT d.DoctorId, d.FullName, d.PrimarySpecialityId
        FROM DoctorMaster d
        LEFT JOIN DoctorDepartmentMap ddm ON ddm.DoctorId = d.DoctorId AND ddm.IsActive = 1
        INNER JOIN DepartmentMaster    dm  ON dm.DeptId    = ddm.DeptId  AND dm.DeptType = 'OPD' AND dm.IsActive = 1
        INNER JOIN DoctorScheduleMaster dsm ON d.DoctorId = dsm.DoctorId AND dsm.IsActive = 1
        WHERE d.IsActive = 1
        ORDER BY d.FullName");
    foreach(var r in rows) {
        Console.WriteLine($"{r.DoctorId} | {r.FullName} | {r.PrimarySpecialityId}");
    }
}
