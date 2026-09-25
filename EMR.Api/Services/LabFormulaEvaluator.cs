using System.Globalization;
using System.Text;

namespace EMR.Api.Services;

/// <summary>
/// Evaluates a Lab Formula Component expression such as <c>([TST0040] - [TST0041]) / 5</c>.
/// Supported: test codes in square brackets, numbers, + - * / and brackets, and a leading minus.
/// The value of each test code comes from what the technician has entered on the Report Entry screen.
/// </summary>
public static class LabFormulaEvaluator
{
    public sealed record Result(bool HasValue, decimal Value, string? Message, IReadOnlyList<string> UsedCodes, IReadOnlyList<string> MissingCodes);

    /// <summary>Test codes the expression refers to, in the order they appear.</summary>
    public static List<string> ReferencedCodes(string? expression)
    {
        var codes = new List<string>();
        if (string.IsNullOrWhiteSpace(expression)) return codes;

        for (int i = 0; i < expression.Length; i++)
        {
            if (expression[i] != '[') continue;
            int end = expression.IndexOf(']', i + 1);
            if (end < 0) break;
            var code = expression[(i + 1)..end].Trim();
            if (code.Length > 0 && !codes.Contains(code, StringComparer.OrdinalIgnoreCase)) codes.Add(code);
            i = end;
        }
        return codes;
    }

    public static Result Evaluate(string? expression, IDictionary<string, decimal> values)
    {
        var used = new List<string>();
        var missing = new List<string>();

        if (string.IsNullOrWhiteSpace(expression))
            return new Result(false, 0m, "No formula is configured.", used, missing);

        List<string> tokens;
        try { tokens = Tokenise(expression, values, used, missing); }
        catch (FormatException ex) { return new Result(false, 0m, ex.Message, used, missing); }

        if (missing.Count > 0)
            return new Result(false, 0m, null, used, missing);   // waiting for values, not an error

        try
        {
            var rpn = ToRpn(tokens);
            var value = EvaluateRpn(rpn);
            return new Result(true, value, null, used, missing);
        }
        catch (DivideByZeroException)
        {
            return new Result(false, 0m, "Cannot calculate: it would divide by zero.", used, missing);
        }
        catch (FormatException ex)
        {
            return new Result(false, 0m, ex.Message, used, missing);
        }
        catch (OverflowException)
        {
            return new Result(false, 0m, "The result is too large to show.", used, missing);
        }
    }

    private static List<string> Tokenise(string expression, IDictionary<string, decimal> values, List<string> used, List<string> missing)
    {
        var tokens = new List<string>();
        for (int i = 0; i < expression.Length; i++)
        {
            char c = expression[i];
            if (char.IsWhiteSpace(c)) continue;

            if (c == '[')
            {
                int end = expression.IndexOf(']', i + 1);
                if (end < 0) throw new FormatException("The formula has a test code that is not closed with \"]\".");
                var code = expression[(i + 1)..end].Trim();
                i = end;

                if (!used.Contains(code, StringComparer.OrdinalIgnoreCase)) used.Add(code);
                if (values.TryGetValue(code, out var v))
                    tokens.Add(v.ToString(CultureInfo.InvariantCulture));
                else if (!missing.Contains(code, StringComparer.OrdinalIgnoreCase))
                    missing.Add(code);
                continue;
            }

            if (char.IsDigit(c) || c == '.')
            {
                var sb = new StringBuilder();
                while (i < expression.Length && (char.IsDigit(expression[i]) || expression[i] == '.')) sb.Append(expression[i++]);
                i--;
                if (!decimal.TryParse(sb.ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out _))
                    throw new FormatException($"\"{sb}\" is not a valid number in the formula.");
                tokens.Add(sb.ToString());
                continue;
            }

            if (c is '+' or '-' or '*' or '/' or 'x' or 'X' or '÷' or '(' or ')')
            {
                tokens.Add(c switch { 'x' or 'X' => "*", '÷' => "/", _ => c.ToString() });
                continue;
            }

            throw new FormatException($"The formula contains \"{c}\", which is not allowed.");
        }
        return tokens;
    }

    private static int Precedence(string op) => op is "*" or "/" ? 2 : 1;

    private static List<string> ToRpn(List<string> tokens)
    {
        var output = new List<string>();
        var ops = new Stack<string>();
        string? previous = null;

        foreach (var token in tokens)
        {
            if (token is "+" or "-" or "*" or "/")
            {
                // a leading minus, or one right after "(" or another operator, negates the next value
                if (token == "-" && (previous == null || previous == "(" || previous is "+" or "-" or "*" or "/"))
                {
                    output.Add("0");
                }
                while (ops.Count > 0 && ops.Peek() != "(" && Precedence(ops.Peek()) >= Precedence(token)) output.Add(ops.Pop());
                ops.Push(token);
            }
            else if (token == "(") ops.Push(token);
            else if (token == ")")
            {
                while (ops.Count > 0 && ops.Peek() != "(") output.Add(ops.Pop());
                if (ops.Count == 0) throw new FormatException("The formula has a closing bracket without an opening one.");
                ops.Pop();
            }
            else output.Add(token);

            previous = token;
        }

        while (ops.Count > 0)
        {
            var op = ops.Pop();
            if (op == "(") throw new FormatException("The formula has an opening bracket that is never closed.");
            output.Add(op);
        }
        return output;
    }

    private static decimal EvaluateRpn(List<string> rpn)
    {
        var stack = new Stack<decimal>();
        foreach (var token in rpn)
        {
            if (decimal.TryParse(token, NumberStyles.Float, CultureInfo.InvariantCulture, out var number))
            {
                stack.Push(number);
                continue;
            }

            if (stack.Count < 2) throw new FormatException("The formula is incomplete.");
            var b = stack.Pop();
            var a = stack.Pop();
            stack.Push(token switch
            {
                "+" => a + b,
                "-" => a - b,
                "*" => a * b,
                "/" => b == 0m ? throw new DivideByZeroException() : a / b,
                _ => throw new FormatException("The formula is not valid.")
            });
        }

        if (stack.Count != 1) throw new FormatException("The formula is incomplete.");
        return stack.Pop();
    }
}
