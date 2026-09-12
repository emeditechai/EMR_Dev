using System;
using Microsoft.Data.SqlClient;
using System.IO;

class Program
{
    static void Main(string[] args)
    {
        string cs = "Server=103.178.113.61,1232;Database=Dev_EMR;User Id=sa;Password=Ehospit@lity@#1926;TrustServerCertificate=True;";
        // Support --file argument to specify which SQL file to run
        string scriptPath = "/Users/abhikporel/dev/EMR_Web/SQLScripts/2019_add_lab_order_collection_type_and_phlebotomist.sql";
        for (int i = 0; i < args.Length - 1; i++)
        {
            if (args[i] == "--file")
            {
                scriptPath = args[i + 1];
                break;
            }
        }



        if (!File.Exists(scriptPath))
        {
            Console.WriteLine($"ERROR: File not found: {scriptPath}");
            Environment.Exit(1);
        }

        using var conn = new SqlConnection(cs);
        conn.FireInfoMessageEventOnUserErrors = true;
        conn.InfoMessage += (s, e) => Console.WriteLine(e.Message);
        conn.Open();

        string script = File.ReadAllText(scriptPath);
        var batches = script.Split(new[] { "GO\r\n", "GO\n", "\nGO" }, StringSplitOptions.RemoveEmptyEntries);

        foreach (var b in batches)
        {
            var trimmed = b.Trim();
            if (!string.IsNullOrWhiteSpace(trimmed))
            {
                using var cmd = new SqlCommand(trimmed, conn);
                cmd.CommandTimeout = 120;
                cmd.ExecuteNonQuery();
            }
        }

        Console.WriteLine($"Migration '{Path.GetFileName(scriptPath)}' executed successfully.");
    }
}
