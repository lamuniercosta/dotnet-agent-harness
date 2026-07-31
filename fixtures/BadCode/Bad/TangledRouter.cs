namespace Bad;

// VIOLATION: cyclomatic complexity gate (CA1502).
// Route has ~24 independent branches, well over the default ceiling of 15.
// The fix is extraction, not a suppression - see scripts/apply-fix.ps1.
public static class TangledRouter
{
    public static string Route(int code, bool retry, bool urgent, string? region)
    {
        if (code < 0)
        {
            return "invalid";
        }

        if (code == 0)
        {
            return retry ? "retry-zero" : "zero";
        }

        if (code < 10)
        {
            if (urgent && retry)
            {
                return "urgent-retry-low";
            }

            if (urgent)
            {
                return "urgent-low";
            }

            return retry ? "retry-low" : "low";
        }

        if (code < 100)
        {
            if (region == "eu")
            {
                return urgent ? "eu-urgent" : "eu";
            }

            if (region == "us")
            {
                return urgent ? "us-urgent" : "us";
            }

            if (region == "apac")
            {
                return retry ? "apac-retry" : "apac";
            }

            return "mid";
        }

        if (code < 1000)
        {
            if (retry && urgent && region is not null)
            {
                return "high-all";
            }

            if (retry && urgent)
            {
                return "high-retry-urgent";
            }

            return retry ? "high-retry" : "high";
        }

        return urgent ? "overflow-urgent" : "overflow";
    }
}
