module mysql.protocol.extra_types;

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

/**
 * A simple struct to represent time difference.
 *
 * D's std.datetime does not have a type that is closely compatible with the MySQL
 * interpretation of a time difference, so we define a struct here to hold such
 * values.
 */
struct TimeDiff
{
    bool negative;
    int days;
    ubyte hours, minutes, seconds;
}

/**
 * A D struct to stand for a TIMESTAMP
 *
 * It is assumed that insertion of TIMESTAMP values will not be common, since in general,
 * such columns are used for recording the time of a row insertion, and are filled in
 * automatically by the server. If you want to force a timestamp value in a prepared insert,
 * set it into a timestamp struct as an unsigned long in the format YYYYMMDDHHMMSS
 * and use that for the approriate parameter. When TIMESTAMPs are retrieved as part of
 * a result set it will be as DateTime structs.
 */
struct Timestamp
{
    ulong rep;
}

struct SQLValue
{
    bool isNull;
    bool isIncomplete;
    Variant _value;

    // empty template as a template and non-template won't be added to the same overload set
    @property inout(Variant) value()() inout
    {
        enforceEx!MYX(!isNull, "SQL value is null");
        enforceEx!MYX(!isIncomplete, "SQL value not complete");
        return _value;
    }

    @property void value(T)(T value)
    {
        enforceEx!MYX(!isNull, "SQL value is null");
        enforceEx!MYX(!isIncomplete, "SQL value not complete");
        _value = value;
    }

    pure const nothrow invariant()
    {
        isNull && assert(!isIncomplete);
        isIncomplete && assert(!isNull);
    }
}

/**
 * Length Coded Binary Value
 * */
struct LCB
{
    /// True if the LCB contains a null value
    bool isNull;

    /// True if the packet that created this LCB didn't have enough bytes
    /// to store a value of the size specified. More bytes have to be fetched from the server
    bool isIncomplete;

    // Number of bytes needed to store the value (Extracted from the LCB header. The header byte is not included)
    ubyte numBytes;

    // Number of bytes total used for this LCB
    @property ubyte totalBytes() pure const nothrow
    {
        return cast(ubyte)(numBytes <= 1 ? 1 : numBytes+1);
    }

    /// The decoded value. This is always 0 if isNull or isIncomplete is set.
    ulong value;

    pure const nothrow invariant()
    {
        if(isIncomplete)
        {
            assert(!isNull);
            assert(value == 0);
            assert(numBytes > 0);
        }
        else if(isNull)
        {
            assert(!isIncomplete);
            assert(value == 0);
            assert(numBytes == 0);
        }
        else
        {
            assert(!isNull);
            assert(!isIncomplete);
            assert(numBytes > 0);
        }
    }
}

/** Length Coded String
 * */
struct LCS
{
    // dummy struct just to tell what value we are using
    // we don't need to store anything here as the result is always a string
}

/**
 * A struct to represent specializations of prepared statement parameters.
 *
 * There are two specializations. First you can set an isNull flag to indicate that the
 * parameter is to have the SQL NULL value.
 *
 * Second, if you need to send large objects to the database it might be convenient to
 * send them in pieces. These two variables allow for this. If both are provided
 * then the corresponding column will be populated by calling the delegate repeatedly.
 * the source should fill the indicated slice with data and arrange for the delegate to
 * return the length of the data supplied. Af that is less than the chunkSize
 * then the chunk will be assumed to be the last one.
 */
struct ParameterSpecialization
{
    import mysql.protocol.constants;
    
    size_t pIndex;    //parameter number 0 - number of params-1
    bool isNull;
    SQLType type = SQLType.INFER_FROM_D_TYPE;
    uint chunkSize;
    uint delegate(ubyte[]) chunkDelegate;
}
alias PSN = ParameterSpecialization;

/**
 * A struct to represent specializations of prepared statement parameters.
 *
 * If you are executing a query that will include result columns that are large objects
 * it may be expedient to deal with the data as it is received rather than first buffering
 * it to some sort of byte array. These two variables allow for this. If both are provided
 * then the corresponding column will be fed to the stipulated delegate in chunks of
 * chunkSize, with the possible exception of the last chunk, which may be smaller.
 * The 'finished' argument will be set to true when the last chunk is set.
 *
 * Be aware when specifying types for column specializations that for some reason the
 * field descriptions returned for a resultset have all of the types TINYTEXT, MEDIUMTEXT,
 * TEXT, LONGTEXT, TINYBLOB, MEDIUMBLOB, BLOB, and LONGBLOB lumped as type 0xfc
 * contrary to what it says in the protocol documentation.
 */
struct ColumnSpecialization
{
    size_t  cIndex;    // parameter number 0 - number of params-1
    ushort  type;
    uint    chunkSize;
    void delegate(const(ubyte)[] chunk, bool finished) chunkDelegate;
}
alias CSN = ColumnSpecialization;

/**
 * A struct to hold column metadata
 */
struct ColumnInfo
{
    /// The database that the table having this column belongs to.
    string schema;
    /// The table that this column belongs to.
    string table;
    /// The name of the column.
    string name;
    /// Zero based index of the column within a table row.
    size_t index;
    /// Is the default value NULL?
    bool defaultNull;
    /// The default value as a string if not NULL
    string defaultValue;
    /// Can the column value be set to NULL
    bool nullable;
    /// What type is the column - tinyint, char, varchar, blob, date etc
    string type;
    /// Capacity in characters, -1L if not applicable
    long charsMax;
    /// Capacity in bytes - same as chars if not a unicode table definition, -1L if not applicable.
    long octetsMax;
    /// Presentation information for numerics, -1L if not applicable.
    short numericPrecision;
    /// Scale information for numerics or NULL, -1L if not applicable.
    short numericScale;
    /// Character set, "<NULL>" if not applicable.
    string charSet;
    /// Collation, "<NULL>" if not applicable.
    string collation;
    /// More detail about the column type, e.g. "int(10) unsigned".
    string colType;
    /// Information about the column's key status, blank if none.
    string key;
    /// Extra information.
    string extra;
    /// Privileges for logged in user.
    string privileges;
    /// Any comment that was set at table definition time.
    string comment;
}

/**
 * A struct to hold stored function metadata
 *
 */
struct MySQLProcedure
{
    string db;
    string name;
    string type;
    string definer;
    DateTime modified;
    DateTime created;
    string securityType;
    string comment;
    string charSetClient;
    string collationConnection;
    string collationDB;
}

/**
 * Facilities to recover meta-data from a connection
 *
 * It is important to bear in mind that the methods provided will only return the
 * information that is available to the connected user. This may well be quite limited.
 */
struct MetaData
{
    import mysql.connection;
    
private:
    Connection _con;

    MySQLProcedure[] stored(bool procs)
    {
        enforceEx!MYX(_con.currentDB.length, "There is no selected database");
        string query = procs ? "SHOW PROCEDURE STATUS WHERE db='": "SHOW FUNCTION STATUS WHERE db='";
        query ~= _con.currentDB ~ "'";

        auto cmd = Command(_con, query);
        auto rs = cmd.execSQLResult();
        MySQLProcedure[] pa;
        pa.length = rs.length;
        foreach (size_t i; 0..rs.length)
        {
            MySQLProcedure foo;
            Row r = rs[i];
            foreach (int j; 0..11)
            {
                if (r.isNull(j))
                    continue;
                auto value = r[j].toString();
                switch (j)
                {
                    case 0:
                        foo.db = value;
                        break;
                    case 1:
                        foo.name = value;
                        break;
                    case 2:
                        foo.type = value;
                        break;
                    case 3:
                        foo.definer = value;
                        break;
                    case 4:
                        foo.modified = r[j].get!(DateTime);
                        break;
                    case 5:
                        foo.created = r[j].get!(DateTime);
                        break;
                    case 6:
                        foo.securityType = value;
                        break;
                    case 7:
                        foo.comment = value;
                        break;
                    case 8:
                        foo.charSetClient = value;
                        break;
                    case 9:
                        foo.collationConnection = value;
                        break;
                    case 10:
                        foo.collationDB = value;
                        break;
                    default:
                        assert(0);
                }
            }
            pa[i] = foo;
        }
        return pa;
    }

public:
    this(Connection con)
    {
        _con = con;
    }

    /**
     * List the available databases
     *
     * Note that if you have connected using the credentials of a user with
     * limited permissions you may not get many results.
     *
     * Returns:
     *    An array of strings
     */
    string[] databases()
    {
        auto cmd = Command(_con, "SHOW DATABASES");
        auto rs = cmd.execSQLResult();
        string[] dbNames;
        dbNames.length = rs.length;
        foreach (size_t i; 0..rs.length)
            dbNames[i] = rs[i][0].toString();
        return dbNames;
    }

    /**
     * List the tables in the current database
     *
     * Returns:
     *    An array of strings
     */
    string[] tables()
    {
        auto cmd = Command(_con, "SHOW TABLES");
        auto rs = cmd.execSQLResult();
        string[] tblNames;
        tblNames.length = rs.length;
        foreach (size_t i; 0..rs.length)
            tblNames[i] = rs[i][0].toString();
        return tblNames;
    }

    /**
     * Get column metadata for a table in the current database
     *
     * Params:
     *    table = The table name
     * Returns:
     *    An array of ColumnInfo structs
     */
    ColumnInfo[] columns(string table)
    {
        // Manually specify all fields to avoid problems when newer versions of
        // the server add or rearrange fields. (Issue #45)
        string query =
            "SELECT " ~
            " TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME," ~
            " COLUMN_NAME, ORDINAL_POSITION, COLUMN_DEFAULT," ~
            " IS_NULLABLE, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH," ~
            " CHARACTER_OCTET_LENGTH, NUMERIC_PRECISION, NUMERIC_SCALE," ~
            " CHARACTER_SET_NAME, COLLATION_NAME, COLUMN_TYPE," ~
            " COLUMN_KEY, EXTRA, PRIVILEGES, COLUMN_COMMENT" ~
            " FROM information_schema.COLUMNS WHERE" ~
            " table_schema='" ~ _con.currentDB ~ "' AND table_name='" ~ table ~ "'";
        auto cmd = Command(_con, query);
        auto rs = cmd.execSQLResult();
        ColumnInfo[] ca;
        ca.length = rs.length;
        foreach (size_t i; 0..rs.length)
        {
            ColumnInfo col;
            Row r = rs[i];
            for (int j = 1; j < 19; j++)
            {
                string t;
                bool isNull = r.isNull(j);
                if (!isNull)
                    t = to!string(r[j]);
                switch (j)
                {
                    case 1:
                        col.schema = t;
                        break;
                    case 2:
                        col.table = t;
                        break;
                    case 3:
                        col.name = t;
                        break;
                    case 4:
                        if(isNull)
                            col.index = -1;
                        else
                            col.index = cast(size_t)(r[j].coerce!ulong() - 1);
                        //col.index = cast(size_t)(r[j].get!(ulong)-1);
                        break;
                    case 5:
                        if (isNull)
                            col.defaultNull = true;
                        else
                            col.defaultValue = t;
                        break;
                    case 6:
                        if (t == "YES")
                        col.nullable = true;
                        break;
                    case 7:
                        col.type = t;
                        break;
                    case 8:
                        col.charsMax = cast(long)(isNull? -1L: r[j].coerce!(ulong));
                        break;
                    case 9:
                        col.octetsMax = cast(long)(isNull? -1L: r[j].coerce!(ulong));
                        break;
                    case 10:
                        col.numericPrecision = cast(short) (isNull? -1: r[j].coerce!(ulong));
                        break;
                    case 11:
                        col.numericScale = cast(short) (isNull? -1: r[j].coerce!(ulong));
                        break;
                    case 12:
                        col.charSet = isNull? "<NULL>": t;
                        break;
                    case 13:
                        col.collation = isNull? "<NULL>": t;
                        break;
                    case 14:
                        col.colType = r[j].get!string();
                        break;
                    case 15:
                        col.key = t;
                        break;
                    case 16:
                        col.extra = t;
                        break;
                    case 17:
                        col.privileges = t;
                        break;
                    case 18:
                        col.comment = t;
                        break;
                    default:
                        break;
                }
            }
            ca[i] = col;
        }
        return ca;
    }

    /**
     * Get list of stored functions in the current database, and their properties
     *
     */
    MySQLProcedure[] functions()
    {
        return stored(false);
    }

    /**
     * Get list of stored procedures in the current database, and their properties
     *
     */
    MySQLProcedure[] procedures()
    {
        return stored(true);
    }
}
