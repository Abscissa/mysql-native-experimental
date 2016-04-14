module mysql.protocol.commands;

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
import mysql.protocol.constants;
import mysql.protocol.extra_types;
import mysql.protocol.packets;

/**
 * Encapsulation of an SQL command or query.
 *
 * A Command be be either a one-off SQL query, or may use a prepared statement.
 * Commands that are expected to return a result set - queries - have distinctive methods
 * that are enforced. That is it will be an error to call such a method with an SQL command
 * that does not produce a result set.
 */
struct Command
{
package:
    Connection _con;
    const(char)[] _sql;
    uint _hStmt;
    ulong _insertID;
    bool _rowsPending, _headersPending, _pendingBinary, _rebound;
    ushort _psParams, _psWarnings, _fieldCount;
    ResultSetHeaders _rsh;
    PreparedStmtHeaders _psh;
    Variant[] _inParams;
    ParameterSpecialization[] _psa;
    string _prevFunc;

    bool sendCmd(CommandType cmd)
    {
        enforceEx!MYX(!(_headersPending || _rowsPending),
            "There are result set elements pending - purgeResult() required.");

        scope(failure) _con.kill();
        _con.sendCmd(cmd, _sql);
        return true;
    }

    static ubyte[] makeBitmap(in ParameterSpecialization[] psa) pure nothrow
    {
        size_t bml = (psa.length+7)/8;
        ubyte[] bma;
        bma.length = bml;
        foreach (size_t i, PSN psn; psa)
        {
            if (!psn.isNull)
                continue;
            size_t bn = i/8;
            size_t bb = i%8;
            ubyte sr = 1;
            sr <<= bb;
            bma[bn] |= sr;
        }
        return bma;
    }

    ubyte[] makePSPrefix(ubyte flags = 0) pure const nothrow
    {
        ubyte[] prefix;
        prefix.length = 14;

        prefix[4] = CommandType.STMT_EXECUTE;
        _hStmt.packInto(prefix[5..9]);
        prefix[9] = flags;   // flags, no cursor
        prefix[10] = 1; // iteration count - currently always 1
        prefix[11] = 0;
        prefix[12] = 0;
        prefix[13] = 0;

        return prefix;
    }

    ubyte[] analyseParams(out ubyte[] vals, out bool longData)
    {
        size_t pc = _inParams.length;
        ubyte[] types;
        types.length = pc*2;
        size_t alloc = pc*20;
        vals.length = alloc;
        uint vcl = 0, len;
        int ct = 0;

        void reAlloc(size_t n)
        {
            if (vcl+n < alloc)
                return;
            size_t inc = (alloc*3)/2;
            if (inc <  n)
                inc = n;
            alloc += inc;
            vals.length = alloc;
        }

        foreach (size_t i; 0..pc)
        {
            if (_psa[i].chunkSize)
                longData= true;
            bool isnull = _psa[i].isNull;
            Variant v = _inParams[i];
            SQLType ext = _psa[i].type;
            string ts = v.type.toString();
            bool isRef;
            if (ts[$-1] == '*')
            {
                ts.length = ts.length-1;
                isRef= true;
            }

            enum UNSIGNED  = 0x80;
            enum SIGNED    = 0;
            switch (ts)
            {
                case "bool":
                    if (ext == SQLType.INFER_FROM_D_TYPE)
                        types[ct++] = SQLType.BIT;
                    else
                        types[ct++] = cast(ubyte) ext;
                    types[ct++] = SIGNED;
                    if (isnull) break;
                    reAlloc(2);
                    bool bv = isRef? *(v.get!(bool*)): v.get!(bool);
                    vals[vcl++] = 1;
                    vals[vcl++] = bv? 0x31: 0x30;
                    break;
                case "byte":
                    types[ct++] = SQLType.TINY;
                    types[ct++] = SIGNED;
                    if (isnull) break;
                    reAlloc(1);
                    vals[vcl++] = isRef? *(v.get!(byte*)): v.get!(byte);
                    break;
                case "ubyte":
                    types[ct++] = SQLType.TINY;
                    types[ct++] = UNSIGNED;
                    if (isnull) break;
                    reAlloc(1);
                    vals[vcl++] = isRef? *(v.get!(ubyte*)): v.get!(ubyte);
                    break;
                case "short":
                    types[ct++] = SQLType.SHORT;
                    types[ct++] = SIGNED;
                    if (isnull) break;
                    reAlloc(2);
                    short si = isRef? *(v.get!(short*)): v.get!(short);
                    vals[vcl++] = cast(ubyte) (si & 0xff);
                    vals[vcl++] = cast(ubyte) ((si >> 8) & 0xff);
                    break;
                case "ushort":
                    types[ct++] = SQLType.SHORT;
                    types[ct++] = UNSIGNED;
                    reAlloc(2);
                    ushort us = isRef? *(v.get!(ushort*)): v.get!(ushort);
                    vals[vcl++] = cast(ubyte) (us & 0xff);
                    vals[vcl++] = cast(ubyte) ((us >> 8) & 0xff);
                    break;
                case "int":
                    types[ct++] = SQLType.INT;
                    types[ct++] = SIGNED;
                    if (isnull) break;
                    reAlloc(4);
                    int ii = isRef? *(v.get!(int*)): v.get!(int);
                    vals[vcl++] = cast(ubyte) (ii & 0xff);
                    vals[vcl++] = cast(ubyte) ((ii >> 8) & 0xff);
                    vals[vcl++] = cast(ubyte) ((ii >> 16) & 0xff);
                    vals[vcl++] = cast(ubyte) ((ii >> 24) & 0xff);
                    break;
                case "uint":
                    types[ct++] = SQLType.INT;
                    types[ct++] = UNSIGNED;
                    if (isnull) break;
                    reAlloc(4);
                    uint ui = isRef? *(v.get!(uint*)): v.get!(uint);
                    vals[vcl++] = cast(ubyte) (ui & 0xff);
                    vals[vcl++] = cast(ubyte) ((ui >> 8) & 0xff);
                    vals[vcl++] = cast(ubyte) ((ui >> 16) & 0xff);
                    vals[vcl++] = cast(ubyte) ((ui >> 24) & 0xff);
                    break;
                case "long":
                    types[ct++] = SQLType.LONGLONG;
                    types[ct++] = SIGNED;
                    if (isnull) break;
                    reAlloc(8);
                    long li = isRef? *(v.get!(long*)): v.get!(long);
                    vals[vcl++] = cast(ubyte) (li & 0xff);
                    vals[vcl++] = cast(ubyte) ((li >> 8) & 0xff);
                    vals[vcl++] = cast(ubyte) ((li >> 16) & 0xff);
                    vals[vcl++] = cast(ubyte) ((li >> 24) & 0xff);
                    vals[vcl++] = cast(ubyte) ((li >> 32) & 0xff);
                    vals[vcl++] = cast(ubyte) ((li >> 40) & 0xff);
                    vals[vcl++] = cast(ubyte) ((li >> 48) & 0xff);
                    vals[vcl++] = cast(ubyte) ((li >> 56) & 0xff);
                    break;
                case "ulong":
                    types[ct++] = SQLType.LONGLONG;
                    types[ct++] = UNSIGNED;
                    if (isnull) break;
                    reAlloc(8);
                    ulong ul = isRef? *(v.get!(ulong*)): v.get!(ulong);
                    vals[vcl++] = cast(ubyte) (ul & 0xff);
                    vals[vcl++] = cast(ubyte) ((ul >> 8) & 0xff);
                    vals[vcl++] = cast(ubyte) ((ul >> 16) & 0xff);
                    vals[vcl++] = cast(ubyte) ((ul >> 24) & 0xff);
                    vals[vcl++] = cast(ubyte) ((ul >> 32) & 0xff);
                    vals[vcl++] = cast(ubyte) ((ul >> 40) & 0xff);
                    vals[vcl++] = cast(ubyte) ((ul >> 48) & 0xff);
                    vals[vcl++] = cast(ubyte) ((ul >> 56) & 0xff);
                    break;
                case "float":
                    types[ct++] = SQLType.FLOAT;
                    types[ct++] = SIGNED;
                    if (isnull) break;
                    reAlloc(4);
                    float f = isRef? *(v.get!(float*)): v.get!(float);
                    ubyte* ubp = cast(ubyte*) &f;
                    vals[vcl++] = *ubp++;
                    vals[vcl++] = *ubp++;
                    vals[vcl++] = *ubp++;
                    vals[vcl++] = *ubp;
                    break;
                case "double":
                    types[ct++] = SQLType.DOUBLE;
                    types[ct++] = SIGNED;
                    if (isnull) break;
                    reAlloc(8);
                    double d = isRef? *(v.get!(double*)): v.get!(double);
                    ubyte* ubp = cast(ubyte*) &d;
                    vals[vcl++] = *ubp++;
                    vals[vcl++] = *ubp++;
                    vals[vcl++] = *ubp++;
                    vals[vcl++] = *ubp++;
                    vals[vcl++] = *ubp++;
                    vals[vcl++] = *ubp++;
                    vals[vcl++] = *ubp++;
                    vals[vcl++] = *ubp;
                    break;
                case "std.datetime.Date":
                    types[ct++] = SQLType.DATE;
                    types[ct++] = SIGNED;
                    Date date = isRef? *(v.get!(Date*)): v.get!(Date);
                    ubyte[] da = pack(date);
                    size_t l = da.length;
                    if (isnull) break;
                    reAlloc(l);
                    vals[vcl..vcl+l] = da[];
                    vcl += l;
                    break;
                case "std.datetime.Time":
                    types[ct++] = SQLType.TIME;
                    types[ct++] = SIGNED;
                    TimeOfDay time = isRef? *(v.get!(TimeOfDay*)): v.get!(TimeOfDay);
                    ubyte[] ta = pack(time);
                    size_t l = ta.length;
                    if (isnull) break;
                    reAlloc(l);
                    vals[vcl..vcl+l] = ta[];
                    vcl += l;
                    break;
                case "std.datetime.DateTime":
                    types[ct++] = SQLType.DATETIME;
                    types[ct++] = SIGNED;
                    DateTime dt = isRef? *(v.get!(DateTime*)): v.get!(DateTime);
                    ubyte[] da = pack(dt);
                    size_t l = da.length;
                    if (isnull) break;
                    reAlloc(l);
                    vals[vcl..vcl+l] = da[];
                    vcl += l;
                    break;
                case "connect.Timestamp":
                    types[ct++] = SQLType.TIMESTAMP;
                    types[ct++] = SIGNED;
                    Timestamp tms = isRef? *(v.get!(Timestamp*)): v.get!(Timestamp);
                    DateTime dt = mysql.protocol.packet_helpers.toDateTime(tms.rep);
                    ubyte[] da = pack(dt);
                    size_t l = da.length;
                    if (isnull) break;
                    reAlloc(l);
                    vals[vcl..vcl+l] = da[];
                    vcl += l;
                    break;
                case "immutable(char)[]":
                    if (ext == SQLType.INFER_FROM_D_TYPE)
                        types[ct++] = SQLType.VARCHAR;
                    else
                        types[ct++] = cast(ubyte) ext;
                    types[ct++] = SIGNED;
                    if (isnull) break;
                    string s = isRef? *(v.get!(string*)): v.get!(string);
                    ubyte[] packed = packLCS(cast(void[]) s);
                    reAlloc(packed.length);
                    vals[vcl..vcl+packed.length] = packed[];
                    vcl += packed.length;
                    break;
                case "char[]":
                    if (ext == SQLType.INFER_FROM_D_TYPE)
                        types[ct++] = SQLType.VARCHAR;
                    else
                        types[ct++] = cast(ubyte) ext;
                    types[ct++] = SIGNED;
                    if (isnull) break;
                    char[] ca = isRef? *(v.get!(char[]*)): v.get!(char[]);
                    ubyte[] packed = packLCS(cast(void[]) ca);
                    reAlloc(packed.length);
                    vals[vcl..vcl+packed.length] = packed[];
                    vcl += packed.length;
                    break;
                case "byte[]":
                    if (ext == SQLType.INFER_FROM_D_TYPE)
                        types[ct++] = SQLType.TINYBLOB;
                    else
                        types[ct++] = cast(ubyte) ext;
                    types[ct++] = SIGNED;
                    if (isnull) break;
                    byte[] ba = isRef? *(v.get!(byte[]*)): v.get!(byte[]);
                    ubyte[] packed = packLCS(cast(void[]) ba);
                    reAlloc(packed.length);
                    vals[vcl..vcl+packed.length] = packed[];
                    vcl += packed.length;
                    break;
                case "ubyte[]":
                    if (ext == SQLType.INFER_FROM_D_TYPE)
                        types[ct++] = SQLType.TINYBLOB;
                    else
                        types[ct++] = cast(ubyte) ext;
                    types[ct++] = SIGNED;
                    if (isnull) break;
                    ubyte[] uba = isRef? *(v.get!(ubyte[]*)): v.get!(ubyte[]);
                    ubyte[] packed = packLCS(cast(void[]) uba);
                    reAlloc(packed.length);
                    vals[vcl..vcl+packed.length] = packed[];
                    vcl += packed.length;
                    break;
                case "void":
                    throw new MYX("Unbound parameter " ~ to!string(i), __FILE__, __LINE__);
                default:
                    throw new MYX("Unsupported parameter type " ~ ts, __FILE__, __LINE__);
            }
        }
        vals.length = vcl;
        return types;
    }

    void sendLongData()
    {
        assert(_psa.length <= ushort.max); // parameter number is sent as short
        foreach (ushort i, PSN psn; _psa)
        {
            if (!psn.chunkSize) continue;
            uint cs = psn.chunkSize;
            uint delegate(ubyte[]) dg = psn.chunkDelegate;

            ubyte[] chunk;
            chunk.length = cs+11;
            chunk.setPacketHeader(0 /*each chunk is separate cmd*/);
            chunk[4] = CommandType.STMT_SEND_LONG_DATA;
            _hStmt.packInto(chunk[5..9]); // statement handle
            packInto(i, chunk[9..11]); // parameter number

            // byte 11 on is payload
            for (;;)
            {
                uint sent = dg(chunk[11..cs+11]);
                if (sent < cs)
                {
                    if (sent == 0)    // data was exact multiple of chunk size - all sent
                        break;
                    sent += 7;        // adjust for non-payload bytes
                    chunk.length = chunk.length - (cs-sent);     // trim the chunk
                    packInto!(uint, true)(cast(uint)sent, chunk[0..3]);
                    _con.send(chunk);
                    break;
                }
                _con.send(chunk);
            }
        }
    }

public:

    /**
     * Construct a naked Command object
     *
     * Params: con = A Connection object to communicate with the server
     */
    this(Connection con)
    {
        _con = con;
        _con.resetPacket();
    }

    /**
     * Construct a Command object complete with SQL
     *
     * Params: con = A Connection object to communicate with the server
     *                sql = SQL command string.
     */
    this(Connection con, const(char)[] sql)
    {
        _sql = sql;
        this(con);
    }

    @property
    {
        /// Get the current SQL for the Command
        const(char)[] sql() pure const nothrow { return _sql; }

        /**
        * Set a new SQL command.
        *
        * This can have quite profound side effects. It resets the Command to
        * an initial state. If a query has been issued on the Command that
        * produced a result set, then all of the result set packets - field
        * description sequence, EOF packet, result rows sequence, EOF packet
        * must be flushed from the server before any further operation can be
        * performed on the Connection. If you want to write speedy and efficient
        * MySQL programs, you should bear this in mind when designing your
        * queries so that you are not requesting many rows when one would do.
        *
        * Params: sql = SQL command string.
        */
        const(char)[] sql(const(char)[] sql)
        {
            if (_hStmt)
            {
                purgeResult();
                releaseStatement();
                _con.resetPacket();
            }
            return this._sql = sql;
        }
    }

    /**
     * Submit an SQL command to the server to be compiled into a prepared statement.
     *
     * The result of a successful outcome will be a statement handle - an ID -
     * for the prepared statement, a count of the parameters required for
     * excution of the statement, and a count of the columns that will be present
     * in any result set that the command generates. Thes values will be stored
     * in in the Command struct.
     *
     * The server will then proceed to send prepared statement headers,
     * including parameter descriptions, and result set field descriptions,
     * followed by an EOF packet.
     *
     * If there is an existing statement handle in the Command struct, that
     * prepared statement is released.
     *
     * Throws: MySQLException if there are pending result set items, or if the
     * server has a problem.
     */
    void prepare()
    {
        enforceEx!MYX(!(_headersPending || _rowsPending),
            "There are result set elements pending - purgeResult() required.");

        scope(failure) _con.kill();

        if (_hStmt)
            releaseStatement();
        _con.sendCmd(CommandType.STMT_PREPARE, _sql);
        _fieldCount = 0;

        ubyte[] packet = _con.getPacket();
        if (packet.front == ResultPacketMarker.ok)
        {
            packet.popFront();
            _hStmt              = packet.consume!int();
            _fieldCount         = packet.consume!short();
            _psParams           = packet.consume!short();

            _inParams.length    = _psParams;
            _psa.length         = _psParams;

            packet.popFront(); // one byte filler
            _psWarnings         = packet.consume!short();

            // At this point the server also sends field specs for parameters
            // and columns if there were any of each
            _psh = PreparedStmtHeaders(_con, _fieldCount, _psParams);
        }
        else if(packet.front == ResultPacketMarker.error)
        {
            auto error = OKErrorPacket(packet);
            enforcePacketOK(error);
            assert(0); // FIXME: what now?
        }
        else
            assert(0); // FIXME: what now?
    }

    /**
     * Release a prepared statement.
     *
     * This method tells the server that it can dispose of the information it
     * holds about the current prepared statement, and resets the Command
     * object to an initial state in that respect.
     */
    void releaseStatement()
    {
        scope(failure) _con.kill();

        ubyte[] packet;
        packet.length = 9;
        packet.setPacketHeader(0/*packet number*/);
        _con.bumpPacket();
        packet[4] = CommandType.STMT_CLOSE;
        _hStmt.packInto(packet[5..9]);
        purgeResult();
        _con.send(packet);
        // It seems that the server does not find it necessary to send a response
        // for this command.
        _hStmt = 0;
    }

    /**
     * Flush any outstanding result set elements.
     *
     * When the server responds to a command that produces a result set, it
     * queues the whole set of corresponding packets over the current connection.
     * Before that Connection can embark on any new command, it must receive
     * all of those packets and junk them.
     * http://www.mysqlperformanceblog.com/2007/07/08/mysql-net_write_timeout-vs-wait_timeout-and-protocol-notes/
     */
    ulong purgeResult()
    {
        scope(failure) _con.kill();

        ulong rows = 0;
        if (_fieldCount)
        {
            if (_headersPending)
            {
                for (size_t i = 0;; i++)
                {
                    if (_con.getPacket().isEOFPacket())
                    {
                        _headersPending = false;
                        break;
                    }
                    enforceEx!MYXProtocol(i < _fieldCount, "Field header count exceeded but no EOF packet found.");
                }
            }
            if (_rowsPending)
            {
                for (;;  rows++)
                {
                    if (_con.getPacket().isEOFPacket())
                    {
                        _rowsPending = _pendingBinary = false;
                        break;
                    }
                }
            }
        }
        _fieldCount = 0;
        _con.resetPacket();
        return rows;
    }

    /**
     * Bind a D variable to a prepared statement parameter.
     *
     * In this implementation, binding comprises setting a value into the
     * appropriate element of an array of Variants which represent the
     * parameters, and setting any required specializations.
     *
     * To bind to some D variable, we set the corrsponding variant with its
     * address, so there is no need to rebind between calls to execPreparedXXX.
     */
    void bindParameter(T)(ref T val, size_t pIndex, ParameterSpecialization psn = PSN(0, false, SQLType.INFER_FROM_D_TYPE, 0, null))
    {
        // Now in theory we should be able to check the parameter type here, since the
        // protocol is supposed to send us type information for the parameters, but this
        // capability seems to be broken. This assertion is supported by the fact that
        // the same information is not available via the MySQL C API either. It is up
        // to the programmer to ensure that appropriate type information is embodied
        // in the variant array, or provided explicitly. This sucks, but short of
        // having a client side SQL parser I don't see what can be done.
        //
        // We require that the statement be prepared at this point so we can at least
        // check that the parameter number is within the required range
        enforceEx!MYX(_hStmt, "The statement must be prepared before parameters are bound.");
        enforceEx!MYX(pIndex < _psParams, "Parameter number is out of range for the prepared statement.");
        _inParams[pIndex] = &val;
        psn.pIndex = pIndex;
        _psa[pIndex] = psn;
    }

    /**
     * Bind a tuple of D variables to the parameters of a prepared statement.
     *
     * You can use this method to bind a set of variables if you don't need any specialization,
     * that is there will be no null values, and chunked transfer is not neccessary.
     *
     * The tuple must match the required number of parameters, and it is the programmer's
     * responsibility to ensure that they are of appropriate types.
     */
    void bindParameterTuple(T...)(ref T args)
    {
        enforceEx!MYX(_hStmt, "The statement must be prepared before parameters are bound.");
        enforceEx!MYX(args.length == _psParams, "Argument list supplied does not match the number of parameters.");
        foreach (size_t i, dummy; args)
            _inParams[i] = &args[i];
    }

    /**
     * Bind a Variant[] as the parameters of a prepared statement.
     *
     * You can use this method to bind a set of variables in Variant form to
     * the parameters of a prepared statement.
     *
     * Parameter specializations can be added if required. This method could be
     * used to add records from a data entry form along the lines of
     * ------------
     * auto c = Command(con, "insert into table42 values(?, ?, ?)");
     * c.prepare();
     * Variant[] va;
     * va.length = 3;
     * DataRecord dr;    // Some data input facility
     * ulong ra;
     * do
     * {
     *     dr.get();
     *     va[0] = dr("Name");
     *     va[1] = dr("City");
     *     va[2] = dr("Whatever");
     *     c.bindParameters(va);
     *     c.execPrepared(ra);
     * } while(tod < "17:30");
     * ------------
     * Params: va = External list of Variants to be used as parameters
     *                psnList = any required specializations
     */
    void bindParameters(Variant[] va, ParameterSpecialization[] psnList= null)
    {
        enforceEx!MYX(_hStmt, "The statement must be prepared before parameters are bound.");
        enforceEx!MYX(va.length == _psParams, "Param count supplied does not match prepared statement");
        _inParams[] = va[];
        if (psnList !is null)
        {
            foreach (PSN psn; psnList)
                _psa[psn.pIndex] = psn;
        }
    }

    /**
     * Access a prepared statement parameter for update.
     *
     * Another style of usage would simply update the parameter Variant directly
     *
     * ------------
     * c.param(0) = 42;
     * c.param(1) = "The answer";
     * ------------
     * Params: index = The zero based index
     */
    ref Variant param(size_t index) pure
    {
        enforceEx!MYX(_hStmt, "The statement must be prepared before parameters are bound.");
        enforceEx!MYX(index < _psParams, "Parameter index out of range.");
        return _inParams[index];
    }

    /**
     * Sets a prepared statement parameter to NULL.
     *
     * Params: index = The zero based index
     */
    void setNullParam(size_t index)
    {
        enforceEx!MYX(_hStmt, "The statement must be prepared before parameters are bound.");
        enforceEx!MYX(index < _psParams, "Parameter index out of range.");
        _psa[index].isNull = true;
        _inParams[index] = "";
    }

    /**
     * Execute a one-off SQL command.
     *
     * Use this method when you are not going to be using the same command repeatedly.
     * It can be used with commands that don't produce a result set, or those that
     * do. If there is a result set its existence will be indicated by the return value.
     *
     * Any result set can be accessed vis getNextRow(), but you should really be
     * using execSQLResult() or execSQLSequence() for such queries.
     *
     * Params: ra = An out parameter to receive the number of rows affected.
     * Returns: true if there was a (possibly empty) result set.
     */
    bool execSQL(out ulong ra)
    {
        scope(failure) _con.kill();

        _con.sendCmd(CommandType.QUERY, _sql);
        _fieldCount = 0;
        ubyte[] packet = _con.getPacket();
        bool rv;
        if (packet.front == ResultPacketMarker.ok || packet.front == ResultPacketMarker.error)
        {
            _con.resetPacket();
            auto okp = OKErrorPacket(packet);
            enforcePacketOK(okp);
            ra = okp.affected;
            _con._serverStatus = okp.serverStatus;
            _insertID = okp.insertID;
            rv = false;
        }
        else
        {
            // There was presumably a result set
            assert(packet.front >= 1 && packet.front <= 250); // ResultSet packet header should have this value
            _headersPending = _rowsPending = true;
            _pendingBinary = false;
            auto lcb = packet.consumeIfComplete!LCB();
            assert(!lcb.isNull);
            assert(!lcb.isIncomplete);
            _fieldCount = cast(ushort)lcb.value;
            assert(_fieldCount == lcb.value);
            rv = true;
            ra = 0;
        }
        return rv;
    }

	///ditto
    bool execSQL()
    {
		ulong ra;
		return execSQL(ra);
    }
    
    /**
     * Execute a one-off SQL command for the case where you expect a result set,
     * and want it all at once.
     *
     * Use this method when you are not going to be using the same command repeatedly.
     * This method will throw if the SQL command does not produce a result set.
     *
     * If there are long data items among the expected result columns you can specify
     * that they are to be subject to chunked transfer via a delegate.
     *
     * Params: csa = An optional array of ColumnSpecialization structs.
     * Returns: A (possibly empty) ResultSet.
     */
    ResultSet execSQLResult(ColumnSpecialization[] csa = null)
    {
        ulong ra;
        enforceEx!MYX(execSQL(ra), "The executed query did not produce a result set.");

        _rsh = ResultSetHeaders(_con, _fieldCount);
        if (csa !is null)
            _rsh.addSpecializations(csa);
        _headersPending = false;

        Row[] rows;
        while(true)
        {
            auto packet = _con.getPacket();
            if(packet.isEOFPacket())
                break;
            rows ~= Row(_con, packet, _rsh, false);
            // As the row fetches more data while incomplete, it might already have
            // fetched the EOF marker, so we have to check it again
            if(!packet.empty && packet.isEOFPacket())
                break;
        }
        _rowsPending = _pendingBinary = false;

        return ResultSet(rows, _rsh.fieldNames);
    }

    /**
     * Execute a one-off SQL command for the case where you expect a result set,
     * and want to deal with it a row at a time.
     *
     * Use this method when you are not going to be using the same command repeatedly.
     * This method will throw if the SQL command does not produce a result set.
     *
     * If there are long data items among the expected result columns you can specify
     * that they are to be subject to chunked transfer via a delegate.
     *
     * Params: csa = An optional array of ColumnSpecialization structs.
     * Returns: A (possibly empty) ResultSequence.
     */
    ResultSequence execSQLSequence(ColumnSpecialization[] csa = null)
    {
        uint alloc = 20;
        Row[] rra;
        rra.length = alloc;
        uint cr = 0;
        ulong ra;
        enforceEx!MYX(execSQL(ra), "The executed query did not produce a result set.");
        _rsh = ResultSetHeaders(_con, _fieldCount);
        if (csa !is null)
            _rsh.addSpecializations(csa);

        _headersPending = false;
        return ResultSequence(&this, _rsh.fieldNames);
    }

    /**
     * Execute a one-off SQL command to place result values into a set of D variables.
     *
     * Use this method when you are not going to be using the same command repeatedly.
     * It will throw if the specified command does not produce a result set, or if
     * any column type is incompatible with the corresponding D variable.
     *
     * Params: args = A tuple of D variables to receive the results.
     * Returns: true if there was a (possibly empty) result set.
     */
    void execSQLTuple(T...)(ref T args)
    {
        ulong ra;
        enforceEx!MYX(execSQL(ra), "The executed query did not produce a result set.");
        Row rr = getNextRow();
        /+if (!rr._valid)   // The result set was empty - not a crime.
            return;+/
        enforceEx!MYX(rr._values.length == args.length, "Result column count does not match the target tuple.");
        foreach (size_t i, dummy; args)
        {
            enforceEx!MYX(typeid(args[i]).toString() == rr._values[i].type.toString(),
                "Tuple "~to!string(i)~" type and column type are not compatible.");
            args[i] = rr._values[i].get!(typeof(args[i]));
        }
        // If there were more rows, flush them away
        // Question: Should I check in purgeResult and throw if there were - it's very inefficient to
        // allow sloppy SQL that does not ensure just one row!
        purgeResult();
    }

    /**
     * Execute a prepared command.
     *
     * Use this method when you will use the same SQL command repeatedly.
     * It can be used with commands that don't produce a result set, or those that
     * do. If there is a result set its existence will be indicated by the return value.
     *
     * Any result set can be accessed vis getNextRow(), but you should really be
     * using execPreparedResult() or execPreparedSequence() for such queries.
     *
     * Params: ra = An out parameter to receive the number of rows affected.
     * Returns: true if there was a (possibly empty) result set.
     */
    bool execPrepared(out ulong ra)
    {
        enforceEx!MYX(_hStmt, "The statement has not been prepared.");
        scope(failure) _con.kill();

        ubyte[] packet;
        _con.resetPacket();

        ubyte[] prefix = makePSPrefix(0);
        size_t len = prefix.length;
        bool longData;

        if (_psh._paramCount)
        {
            ubyte[] one = [ 1 ];
            ubyte[] vals;
            ubyte[] types = analyseParams(vals, longData);
            ubyte[] nbm = makeBitmap(_psa);
            packet = prefix ~ nbm ~ one ~ types ~ vals;
        }
        else
            packet = prefix;

        if (longData)
            sendLongData();

        assert(packet.length <= uint.max);
        packet.setPacketHeader(_con.pktNumber);
        _con.bumpPacket();
        _con.send(packet);
        packet = _con.getPacket();
        bool rv;
        if (packet.front == ResultPacketMarker.ok || packet.front == ResultPacketMarker.error)
        {
            _con.resetPacket();
            auto okp = OKErrorPacket(packet);
            enforcePacketOK(okp);
            ra = okp.affected;
            _con._serverStatus = okp.serverStatus;
            _insertID = okp.insertID;
            rv = false;
        }
        else
        {
            // There was presumably a result set
            _headersPending = _rowsPending = _pendingBinary = true;
            auto lcb = packet.consumeIfComplete!LCB();
            assert(!lcb.isIncomplete);
            _fieldCount = cast(ushort)lcb.value;
            rv = true;
        }
        return rv;
    }

    /**
     * Execute a prepared SQL command for the case where you expect a result set,
     * and want it all at once.
     *
     * Use this method when you will use the same command repeatedly.
     * This method will throw if the SQL command does not produce a result set.
     *
     * If there are long data items among the expected result columns you can specify
     * that they are to be subject to chunked transfer via a delegate.
     *
     * Params: csa = An optional array of ColumnSpecialization structs.
     * Returns: A (possibly empty) ResultSet.
     */
    ResultSet execPreparedResult(ColumnSpecialization[] csa = null)
    {
        ulong ra;
        enforceEx!MYX(execPrepared(ra), "The executed query did not produce a result set.");
        uint alloc = 20;
        Row[] rra;
        rra.length = alloc;
        uint cr = 0;
        _rsh = ResultSetHeaders(_con, _fieldCount);
        if (csa !is null)
            _rsh.addSpecializations(csa);
        _headersPending = false;
        ubyte[] packet;
        for (size_t i = 0;; i++)
        {
            packet = _con.getPacket();
            if (packet.isEOFPacket())
                break;
            Row row = Row(_con, packet, _rsh, true);
            if (cr >= alloc)
            {
                alloc = (alloc*3)/2;
                rra.length = alloc;
            }
            rra[cr++] = row;
            if (!packet.empty && packet.isEOFPacket())
                break;
        }
        _rowsPending = _pendingBinary = false;
        rra.length = cr;
        ResultSet rs = ResultSet(rra, _rsh.fieldNames);
        return rs;
    }

    /**
     * Execute a prepared SQL command for the case where you expect a result set,
     * and want to deal with it one row at a time.
     *
     * Use this method when you will use the same command repeatedly.
     * This method will throw if the SQL command does not produce a result set.
     *
     * If there are long data items among the expected result columns you can
     * specify that they are to be subject to chunked transfer via a delegate.
     *
     * Params: csa = An optional array of ColumnSpecialization structs.
     * Returns: A (possibly empty) ResultSequence.
     */
    ResultSequence execPreparedSequence(ColumnSpecialization[] csa = null)
    {
        ulong ra;
        enforceEx!MYX(execPrepared(ra), "The executed query did not produce a result set.");
        uint alloc = 20;
        Row[] rra;
        rra.length = alloc;
        uint cr = 0;
        _rsh = ResultSetHeaders(_con, _fieldCount);
        if (csa !is null)
            _rsh.addSpecializations(csa);
        _headersPending = false;
        return ResultSequence(&this, _rsh.fieldNames);
    }

    /**
     * Execute a prepared SQL command to place result values into a set of D variables.
     *
     * Use this method when you will use the same command repeatedly.
     * It will throw if the specified command does not produce a result set, or
     * if any column type is incompatible with the corresponding D variable
     *
     * Params: args = A tuple of D variables to receive the results.
     * Returns: true if there was a (possibly empty) result set.
     */
    void execPreparedTuple(T...)(ref T args)
    {
        ulong ra;
        enforceEx!MYX(execPrepared(ra), "The executed query did not produce a result set.");
        Row rr = getNextRow();
        // enforceEx!MYX(rr._valid, "The result set was empty.");
        enforceEx!MYX(rr._values.length == args.length, "Result column count does not match the target tuple.");
        foreach (size_t i, dummy; args)
        {
            enforceEx!MYX(typeid(args[i]).toString() == rr._values[i].type.toString(),
                "Tuple "~to!string(i)~" type and column type are not compatible.");
            args[i] = rr._values[i].get!(typeof(args[i]));
        }
        // If there were more rows, flush them away
        // Question: Should I check in purgeResult and throw if there were - it's very inefficient to
        // allow sloppy SQL that does not ensure just one row!
        purgeResult();
    }

    /**
     * Get the next Row of a pending result set.
     *
     * This method can be used after either execSQL() or execPrepared() have returned true
     * to retrieve result set rows sequentially.
     *
     * Similar functionality is available via execSQLSequence() and execPreparedSequence() in
     * which case the interface is presented as a forward range of Rows.
     *
     * This method allows you to deal with very large result sets either a row at a time,
     * or by feeding the rows into some suitable container such as a linked list.
     *
     * Returns: A Row object.
     */
    Row getNextRow()
    {
        scope(failure) _con.kill();

        if (_headersPending)
        {
            _rsh = ResultSetHeaders(_con, _fieldCount);
            _headersPending = false;
        }
        ubyte[] packet;
        Row rr;
        packet = _con.getPacket();
        if (packet.isEOFPacket())
        {
            _rowsPending = _pendingBinary = false;
            return rr;
        }
        if (_pendingBinary)
            rr = Row(_con, packet, _rsh, true);
        else
            rr = Row(_con, packet, _rsh, false);
        //rr._valid = true;
        return rr;
    }

    /**
     * Execute a stored function, with any required input variables, and store the
     * return value into a D variable.
     *
     * For this method, no query string is to be provided. The required one is of
     * the form "select foo(?, ? ...)". The method generates it and the appropriate
     * bindings - in, and out. Chunked transfers are not supported in either
     * direction. If you need them, create the parameters separately, then use
     * execPreparedResult() to get a one-row, one-column result set.
     *
     * If it is not possible to convert the column value to the type of target,
     * then execFunction will throw. If the result is NULL, that is indicated
     * by a false return value, and target is unchanged.
     *
     * In the interest of performance, this method assumes that the user has the
     * equired information about the number and types of IN parameters and the
     * type of the output variable. In the same interest, if the method is called
     * repeatedly for the same stored function, prepare() is omitted after the first call.
     *
     * Params:
     *    T = The type of the variable to receive the return result.
     *    U = type tuple of arguments
     *    name = The name of the stored function.
     *    target = the D variable to receive the stored function return result.
     *    args = The list of D variables to act as IN arguments to the stored function.
     *
     */
    bool execFunction(T, U...)(string name, ref T target, U args)
    {
        bool repeatCall = (name == _prevFunc);
        enforceEx!MYX(repeatCall || _hStmt == 0, "You must not prepare the statement before calling execFunction");
        if (!repeatCall)
        {
            _sql = "select " ~ name ~ "(";
            bool comma = false;
            foreach (arg; args)
            {
                if (comma)
                    _sql ~= ",?";
                else
                {
                    _sql ~= "?";
                    comma = true;
                }
            }
            _sql ~= ")";
            prepare();
            _prevFunc = name;
        }
        bindParameterTuple(args);
        ulong ra;
        enforceEx!MYX(execPrepared(ra), "The executed query did not produce a result set.");
        Row rr = getNextRow();
        /+enforceEx!MYX(rr._valid, "The result set was empty.");+/
        enforceEx!MYX(rr._values.length == 1, "Result was not a single column.");
        enforceEx!MYX(typeid(target).toString() == rr._values[0].type.toString(),
                        "Target type and column type are not compatible.");
        if (!rr.isNull(0))
            target = rr._values[0].get!(T);
        // If there were more rows, flush them away
        // Question: Should I check in purgeResult and throw if there were - it's very inefficient to
        // allow sloppy SQL that does not ensure just one row!
        purgeResult();
        return !rr.isNull(0);
    }

    /**
     * Execute a stored procedure, with any required input variables.
     *
     * For this method, no query string is to be provided. The required one is
     * of the form "call proc(?, ? ...)". The method generates it and the
     * appropriate in bindings. Chunked transfers are not supported. If you
     * need them, create the parameters separately, then use execPrepared() or
     * execPreparedResult().
     *
     * In the interest of performance, this method assumes that the user has
     * the required information about the number and types of IN parameters.
     * In the same interest, if the method is called repeatedly for the same
     * stored function, prepare() and other redundant operations are omitted
     * after the first call.
     *
     * OUT parameters are not currently supported. It should generally be
     * possible with MySQL to present them as a result set.
     *
     * Params:
     *    T = Type tuple
     *    name = The name of the stored procedure.
     *    args = Tuple of args
     * Returns: True if the SP created a result set.
     */
    bool execProcedure(T...)(string name, ref T args)
    {
        bool repeatCall = (name == _prevFunc);
        enforceEx!MYX(repeatCall || _hStmt == 0, "You must not prepare a statement before calling execProcedure");
        if (!repeatCall)
        {
            _sql = "call " ~ name ~ "(";
            bool comma = false;
            foreach (arg; args)
            {
                if (comma)
                    _sql ~= ",?";
                else
                {
                    _sql ~= "?";
                    comma = true;
                }
            }
            _sql ~= ")";
            prepare();
            _prevFunc = name;
        }
        bindParameterTuple(args);
        ulong ra;
        return execPrepared(ra);
    }

    /// After a command that inserted a row into a table with an auto-increment
    /// ID column, this method allows you to retrieve the last insert ID.
    @property ulong lastInsertID() pure const nothrow { return _insertID; }

    /// Gets the number of parameters in this Command
    @property ushort numParams() pure const nothrow
    {
        return _psParams;
    }

    /// Gets the number of rows pending
    @property bool rowsPending() pure const nothrow { return _rowsPending; }

    /// Gets the result header's field descriptions.
    @property FieldDescription[] resultFieldDescriptions() pure { return _rsh.fieldDescriptions; }
    /// Gets the prepared header's field descriptions.
    @property FieldDescription[] preparedFieldDescriptions() pure { return _psh.fieldDescriptions; }
    /// Gets the prepared header's param descriptions.
    @property ParamDescription[] preparedParamDescriptions() pure { return _psh.paramDescriptions; }
}
