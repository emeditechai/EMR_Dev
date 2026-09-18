using System.Data;
using Microsoft.Data.SqlClient;

namespace SqlScriptRunner;

class Program
{
    static void Main(string[] args)
    {
        string connStr = "Server=103.178.113.61,1232;Database=Dev_EMR;User Id=sa;Password=Ehospit@lity@#1926;TrustServerCertificate=True;MultipleActiveResultSets=True";
        if (args.Length > 0 && args[0] == "--query")
        {
            using var conn = new SqlConnection(connStr);
            conn.Open();
            using var cmd = conn.CreateCommand();
            cmd.CommandText = string.Join(" ", args.Skip(1));
            using var reader = cmd.ExecuteReader();
            for (int i = 0; i < reader.FieldCount; i++)
            {
                Console.Write(reader.GetName(i) + " | ");
            }
            Console.WriteLine();
            while (reader.Read())
            {
                for (int i = 0; i < reader.FieldCount; i++)
                {
                    Console.Write(reader[i]?.ToString() + " | ");
                }
                Console.WriteLine();
            }
            return;
        }

        string[] scripts = args;
        foreach (var s in scripts)
        {
            RunScript(connStr, s);
        }
    }

    static void RunScript(string connStr, string filePath)
    {
        Console.WriteLine($"Running {filePath}...");
        string content = File.ReadAllText(filePath);
        string[] batches = content.Split(new[] { "\nGO", "\r\nGO", "\nGO\r", "\ngo" }, StringSplitOptions.RemoveEmptyEntries);

        using var conn = new SqlConnection(connStr);
        conn.Open();

        int idx = 0;
        foreach (var batch in batches)
        {
            if (string.IsNullOrWhiteSpace(batch)) continue;
            idx++;
            using var cmd = conn.CreateCommand();
            cmd.CommandText = batch;
            cmd.CommandType = CommandType.Text;
            try
            {
                cmd.ExecuteNonQuery();
            }
            catch (SqlException ex)
            {
                Console.WriteLine($"SqlException at Line {ex.LineNumber} in batch {idx}: {ex.Message}");
                Console.WriteLine($"Full batch text:\n{batch}");
                throw;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Error in batch {idx}: {ex.Message}");
                throw;
            }
        }
        Console.WriteLine($"Successfully executed {filePath}.");
    }
}
