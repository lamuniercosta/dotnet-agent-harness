using System.Data.Common;

namespace Bad;

// VIOLATION: security analyzer gate (CA2100).
// The command text is concatenated from a caller-supplied value. This family of
// rules is OFF under the default AnalysisMode - it fires only because the
// harness sets AnalysisMode=All, which is precisely what it is there for.
public sealed class UserLookup(DbConnection connection)
{
    public DbCommand ByName(string name)
    {
        var command = connection.CreateCommand();
        command.CommandText = "SELECT Id FROM Users WHERE Name = '" + name + "'";
        return command;
    }
}
