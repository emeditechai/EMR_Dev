using System;
using System.IO;
using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;

class Program
{
    static void Main()
    {
        string connectionString = "Server=103.178.113.61,1232;Database=Dev_EMR;User Id=sa;Password=Ehospit@lity@#1926;TrustServerCertificate=True;MultipleActiveResultSets=True";
        string sqlDir = "/Users/purojitbhar/My work/EMR_Dev/SQLScripts";
        string[] scripts = new[]
        {
            "2000_lab_test_category_master.sql",
            "2001_lab_test_sub_category_master.sql",
            "2002_lab_sample_type_master.sql",
            "2003_lab_test_method_master.sql",
            "2004_lab_unit_master.sql",
            "2006_lab_investigation_master.sql",
            "2007_seed_lab_investigations_data.sql",
            "2008_lab_investigation_profile_master.sql",
            "2009_seed_lab_investigation_profile_data.sql",
            "2010_analyzer_master_tbl_mst_analyzer.sql",
            "2011_lab_rate_card_master.sql"
        };

        using (SqlConnection conn = new SqlConnection(connectionString))
        {
            conn.Open();
            foreach (var script in scripts)
            {
                string scriptPath = Path.Combine(sqlDir, script);
                Console.WriteLine($"Executing {script}...");
                string scriptContent = File.ReadAllText(scriptPath);
                
                string[] batches = Regex.Split(scriptContent, @"^\s*GO\s*$", RegexOptions.IgnoreCase | RegexOptions.Multiline);
                foreach (var batch in batches)
                {
                    if (string.IsNullOrWhiteSpace(batch)) continue;
                    using (SqlCommand cmd = new SqlCommand(batch, conn))
                    {
                        try
                        {
                            cmd.ExecuteNonQuery();
                        }
                        catch (Exception ex)
                        {
                            Console.WriteLine($"Error executing batch in {script}: {ex.Message}");
                        }
                    }
                }
                Console.WriteLine($"Completed {script}");
            }
        }
    }
}
