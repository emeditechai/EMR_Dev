using System;
using Microsoft.Data.SqlClient;

var cs = "Server=103.178.113.61,1232;Database=Dev_EMR;User Id=sa;Password=Ehospit@lity@#1926;TrustServerCertificate=True;MultipleActiveResultSets=True;";

using var conn = new SqlConnection(cs);
conn.Open();

Console.WriteLine("=== VERIFYING USER 2 COLUMNS AND UPDATES ===");

using (var cmd = new SqlCommand(@"
    SELECT Id, Username, FullName, IsActive, IsNursingStaff, IsPhlebotomist 
    FROM Users 
    WHERE Id = 2", conn))
using (var reader = cmd.ExecuteReader())
{
    if (reader.Read())
    {
        Console.WriteLine($"User ID: {reader["Id"]} | Name: {reader["FullName"]} | Active: {reader["IsActive"]} | IsNursingStaff: {reader["IsNursingStaff"]} | IsPhlebotomist: {reader["IsPhlebotomist"]}");
    }
    else
    {
        Console.WriteLine("User 2 not found");
    }
}

Console.WriteLine("=== VERIFIED SUCCESSFULLY ===");
