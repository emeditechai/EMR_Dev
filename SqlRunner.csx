using System;
using System.IO;
using System.Data.SqlClient;
using System.Text.RegularExpressions;

string connStr = "Server=103.178.113.61,1232;Database=Dev_EMR;User Id=sa;Password=Ehospit@lity@#1926;TrustServerCertificate=True;MultipleActiveResultSets=True";
string script = File.ReadAllText("SQLScripts/35_doctor_roster_multi.sql");
string[] batches = Regex.Split(script, @"^\s*GO\s*$", RegexOptions.Multiline | RegexOptions.IgnoreCase);

using (var conn = new SqlConnection(connStr))
{
    conn.Open();
    foreach (var batch in batches)
    {
        if (string.IsNullOrWhiteSpace(batch)) continue;
        using (var cmd = new SqlCommand(batch, conn))
        {
            try { cmd.ExecuteNonQuery(); }
            catch (Exception ex) { Console.WriteLine("Error: " + ex.Message + "\nBatch: " + batch.Substring(0, Math.Min(100, batch.Length))); }
        }
    }
}
Console.WriteLine("Done.");
