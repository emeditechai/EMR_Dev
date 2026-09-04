using System;

namespace EMR.Web.Utils;

public static class AgeCalculator
{
    /// <summary>
    /// Computes Years, Months, and Days between DateOfBirth and asOf date (default Today).
    /// </summary>
    public static (int Years, int Months, int Days) FromDateOfBirth(DateTime dob, DateTime? asOf = null)
    {
        var today = (asOf ?? DateTime.Today).Date;
        var birthDate = dob.Date;
        if (birthDate > today) return (0, 0, 0);

        int years = today.Year - birthDate.Year;
        int months = today.Month - birthDate.Month;
        int days = today.Day - birthDate.Day;

        if (days < 0)
        {
            months--;
            var prevMonthDate = today.AddMonths(-1);
            days += DateTime.DaysInMonth(prevMonthDate.Year, prevMonthDate.Month);
        }

        if (months < 0)
        {
            years--;
            months += 12;
        }

        return (Math.Max(0, years), Math.Max(0, months), Math.Max(0, days));
    }

    /// <summary>
    /// Computes approximate DateOfBirth from Years, Months, and Days as of date (default Today).
    /// </summary>
    public static DateTime ToDateOfBirth(int years, int months, int days, DateTime? asOf = null)
    {
        var today = (asOf ?? DateTime.Today).Date;
        int y = Math.Max(0, years);
        int m = Math.Max(0, months);
        int d = Math.Max(0, days);

        return today.AddYears(-y).AddMonths(-m).AddDays(-d);
    }

    /// <summary>
    /// Formats age into a readable string like "9 Y 3 M 30 D" or "9 Yrs" or "3 Mos 10 Days".
    /// </summary>
    public static string FormatAge(DateTime? dob, DateTime? asOf = null)
    {
        if (!dob.HasValue) return string.Empty;
        var (y, m, d) = FromDateOfBirth(dob.Value, asOf);
        if (y > 0)
            return m > 0 ? $"{y} Y {m} M" : $"{y} Yrs";
        if (m > 0)
            return d > 0 ? $"{m} M {d} D" : $"{m} Mos";
        return $"{d} Days";
    }

    /// <summary>
    /// Formats age into the standard Year Month Day pattern requested by user,
    /// e.g. "09 Year 03 Month 30 Days" or "25 Year 06 Month 15 Days".
    /// </summary>
    public static string FormatAgePattern(DateTime? dob, int? fallbackAgeYears = null, DateTime? asOf = null)
    {
        if (dob.HasValue)
        {
            var (y, m, d) = FromDateOfBirth(dob.Value, asOf);
            return $"{y:D2} Year {m:D2} Month {d:D2} Days";
        }
        if (fallbackAgeYears.HasValue)
        {
            return $"{fallbackAgeYears.Value:D2} Year 00 Month 00 Days";
        }
        return string.Empty;
    }
}
