/**
 * Package mysql.test contains integration and regression tests, not unittests.
 * Unittests (including regression unittests) are located together with the
 * units they test.
 */
module mysql.test.common;

import std.algorithm;
import std.conv;
import std.datetime;
import std.digest.sha;
import std.exception;
import std.range;
import std.socket;
import std.stdio;
import std.string;
import std.traits;
import std.variant;

import mysql.common;
import mysql.connection;
import mysql.result;

/+
To enable these tests, you have to add the MYSQL_INTEGRATION_TESTS
debug specifier. The reason it uses debug and not version is because dub
doesn't allow adding version specifiers on the command-line.
+/
debug(MYSQL_INTEGRATION_TESTS)
{
    import std.stdio;
    import std.conv;
    import std.datetime;

    private @property string testConnectionStrFile()
    {
        import std.file, std.path;
        
        static string cached;
        if(!cached)
            cached = buildPath(thisExePath().dirName(), "testConnectionStr.txt");

        return cached;
    }
    
    private @property string testConnectionStr()
    {
        import std.file, std.string;

        static string cached;
        if(!cached)
        {
            if(!testConnectionStrFile.exists())
            {
                // Create a default file
                std.file.write(
                    testConnectionStrFile,
                    "host=localhost;port=3306;user=mysqln_test;pwd=pass123;db=mysqln_testdb"
                );
                
                import std.stdio;
                writeln(
                    "Connection string file for tests wasn't found, so a default "~
                    "has been created. Please open it, verify its settings, and "~
                    "run the mysql-native tests again:"
                );
                writeln(testConnectionStrFile);
                assert(false, "Halting so the user can check connection string settings.");
            }
            
            cached = cast(string) std.file.read(testConnectionStrFile);
            cached = cached.strip();
        }
        
        return cached;
    }

    Connection createCn(string cnStr = testConnectionStr)
    {
        return new Connection(cnStr);
    }

    enum scopedCn = "auto cn = createCn(); scope(exit) cn.close();";

    void assertScalar(T, U)(Connection cn, string query, U expected)
    {
        // Timestamp is a bit special as it's converted to a DateTime when
        // returning from MySql to avoid having to use a mysql specific type.
        static if(is(T == DateTime) && is(U == Timestamp))
            assert(cn.queryScalar(query).get!DateTime == expected.toDateTime());
        else
            assert(cn.queryScalar(query).get!T == expected);
    }

    void truncate(Connection cn, string table)
    {
        cn.exec("TRUNCATE `"~table~"`;");
    }

    // At the moment, the following functions are here just for the tests
    // borrowed from simendsjo's fork. I'm not quite ready to expose a public
    // interface just yet.
    ulong exec(Connection cn, string sql)
    {
        auto cmd = Command(cn);
        cmd.sql = sql;

        ulong rowsAffected;
        cmd.execSQL(rowsAffected);
        return rowsAffected;
    }

    ulong exec(Params...)(Connection cn, string sql, ref Params params)
    {
        auto cmd = cn.prepare(sql);
        cmd.bindAll(params);
        return cmd.exec();
    }
    
    ResultSet query(Connection cn, string sql)
    {
        auto cmd = Command(cn);
        cmd.sql = sql;

        return cmd.execSQLResult();
    }
    
    ResultSet query(Params...)(Connection cn, string sql, ref Params params)
    {
        auto cmd = cn.prepare(sql);
        cmd.bindAll(params);
        return cmd.query();
    }

    Row querySingle(Connection cn, string sql)
    {
        return cn.query(sql)[0];
    }

    Row querySingle(Params...)(Connection cn, string sql, ref Params params)
    {
        return cn.query(sql, params)[0];
    }

    Variant queryScalar(Connection cn, string sql)
    {
        return cn.query(sql)[0][0];
    }
    
    Variant queryScalar(Params...)(Connection cn, string sql, ref Params params)
    {
        return cn.query(sql, params)[0][0];
    }

    Command prepare(Connection cn, string sql)
    {
        auto cmd = Command(cn);
        cmd.sql = sql;
        cmd.prepare();
        return cmd;
    }
    
    ulong exec(Command cmd)
    {
        ulong rowsAffected;
        cmd.execPrepared(rowsAffected);
        return rowsAffected;
    }
    
    ResultSet query(Command cmd)
    {
        return cmd.execPreparedResult();
    }
    
    Row querySingle(Command cmd)
    {
        return cmd.query()[0];
    }
    
    void bind(T)(ref Command cmd, ushort index, ref T value)
    {
        static if(is(T==typeof(null)))
            cmd.setNullParam(index);
        else
            cmd.bindParameter(value, index);
    }
    
    void bindAll(Params...)(ref Command cmd, ref Params params)
    {
        foreach(i, ref param; params)
            cmd.bind(i, param);
    }

    void initDB(Connection cn, string db)
    {
        scope(exit) cn.resetPacket();
        //cn.sendCommand(CommandType.INIT_DB, db);
        cn.selectDB(db);
        auto packet = cn.pktNumber();
        //packet.enforceOK();
    }

    /// Convert a Timestamp to DateTime
    DateTime toDateTime(Timestamp value) pure
    {
        auto x = value.rep;
        int second = cast(int) (x%100);
        x /= 100;
        int minute = cast(int) (x%100);
        x /= 100;
        int hour   = cast(int) (x%100);
        x /= 100;
        int day    = cast(int) (x%100);
        x /= 100;
        int month  = cast(int) (x%100);
        x /= 100;
        int year   = cast(int) (x%10000);

        return DateTime(year, month, day, hour, minute, second);
    }
}
