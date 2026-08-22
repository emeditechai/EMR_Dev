using System;
using System.IO;
using System.Data;
using Microsoft.Data.SqlClient;
using System.Text.RegularExpressions;

var cs = "Server=103.178.113.61,1232;Database=Dev_EMR;User Id=sa;Password=Ehospit@lity@#1926;TrustServerCertificate=True;MultipleActiveResultSets=True";
var script = File.ReadAllText("SQLScripts/86_insurance_tpa_master.sql");
var batches = Regex.Split(script, @"^\s*GO\s*$", RegexOptions.Multiline | RegexOptions.IgnoreCase);

using var conn = new SqlConnection(cs);
conn.Open();
Console.WriteLine("Connected to Database successfully.");
int batchIndex = 0;
foreach (var batch in batches)
{
    var b = batch.Trim();
    if (string.IsNullOrEmpty(b)) continue;
    batchIndex++;
    try
    {
        using var cmd = new SqlCommand(b, conn);
        cmd.ExecuteNonQuery();
        Console.WriteLine($"Batch {batchIndex} executed successfully.");
    }
    catch (Exception ex)
    {
        Console.WriteLine($"Error executing batch {batchIndex}: {ex.Message}");
    }
}
Console.WriteLine("All batches completed.");
