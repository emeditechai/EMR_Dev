using System;
using System.IO;
using System.Data;
using Microsoft.Data.SqlClient;
using System.Text.RegularExpressions;

var cs = "Server=127.0.0.1,1433;Database=Dev_EMR;User Id=sa;Password=YourStrong@Passw0rd;TrustServerCertificate=True;";
var script = File.ReadAllText("SQLScripts/38_professional_token_generation.sql");
var batches = Regex.Split(script, @"^\s*GO\s*$", RegexOptions.Multiline | RegexOptions.IgnoreCase);

using var conn = new SqlConnection(cs);
conn.Open();
foreach (var batch in batches)
{
    var b = batch.Trim();
    if (string.IsNullOrEmpty(b)) continue;
    try
    {
        using var cmd = new SqlCommand(b, conn);
        cmd.ExecuteNonQuery();
        Console.WriteLine("Batch executed successfully");
    }
    catch (Exception ex)
    {
        Console.WriteLine("Error executing batch: " + ex.Message);
    }
}
