using System.Data;
using Microsoft.Data.SqlClient;

namespace SqlScriptRunner;

class Program
{
    static void Main(string[] args)
    {
        string connStr = "Server=103.178.113.61,1232;Database=Dev_EMR;User Id=sa;Password=Ehospit@lity@#1926;TrustServerCertificate=True;MultipleActiveResultSets=True";
        string scriptPath1 = args.Length > 0 ? args[0] : "SQLScripts/102_lab_investigation_profile_master.sql";
        string scriptPath2 = args.Length > 1 ? args[1] : "SQLScripts/103_seed_lab_investigation_profile_data.sql";

        RunScript(connStr, scriptPath1);
        RunScript(connStr, scriptPath2);
    }

    static void RunScript(string connStr, string filePath)
    {
        Console.WriteLine($"Running {filePath}...");
        string content = File.ReadAllText(filePath);
        string[] batches = content.Split(new[] { "\nGO", "\r\nGO", "\nGO\r", "\ngo" }, StringSplitOptions.RemoveEmptyEntries);

        using var conn = new SqlConnection(connStr);
        conn.Open();

        foreach (var batch in batches)
        {
            if (string.IsNullOrWhiteSpace(batch)) continue;
            using var cmd = conn.CreateCommand();
            cmd.CommandText = batch;
            cmd.CommandType = CommandType.Text;
            cmd.ExecuteNonQuery();
        }
        Console.WriteLine($"Successfully executed {filePath}.");
    }
}
