using System.Data;
using Microsoft.Data.SqlClient;

namespace SqlScriptRunner;

class Program
{
    static void Main(string[] args)
    {
        string connStr = "Server=103.178.113.61,1232;Database=Dev_EMR;User Id=sa;Password=Ehospit@lity@#1926;TrustServerCertificate=True;MultipleActiveResultSets=True";
        string[] scripts = args.Length > 0 ? args : new[]
        {
            "SQLScripts/78_api_master_list_stored_procedures.sql",
            "SQLScripts/2000_lab_test_category_master.sql",
            "SQLScripts/2001_lab_test_sub_category_master.sql",
            "SQLScripts/2002_lab_sample_type_master.sql",
            "SQLScripts/2003_lab_test_method_master.sql",
            "SQLScripts/2004_lab_unit_master.sql",
            "SQLScripts/2005_seed_lab_masters_data.sql",
            "SQLScripts/2006_lab_investigation_master.sql",
            "SQLScripts/2007_seed_lab_investigations_data.sql",
            "SQLScripts/2008_lab_investigation_profile_master.sql",
            "SQLScripts/2009_seed_lab_investigation_profile_data.sql",
            "SQLScripts/2010_analyzer_master_tbl_mst_analyzer.sql"
        };

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
