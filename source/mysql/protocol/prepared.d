module mysql.protocol.prepared;

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
import std.typecons;
import std.variant;

import mysql.common;
import mysql.connection;
import mysql.protocol.constants;
import mysql.protocol.extra_types;
import mysql.protocol.packets;
import mysql.protocol.packet_helpers;

/++
Encapsulation of a prepared statement.

Commands that are expected to return a result set - queries - have distinctive methods
that are enforced. That is it will be an error to call such a method with an SQL command
that does not produce a result set.
+/
struct Prepared
{
	RefCounted!(PreparedImpl, RefCountedAutoInitialize.no) preparedImpl;
	alias preparedImpl this;
	
	@property bool isPrepared() pure const
	{
		return preparedImpl.refCountedStore.isInitialized && !preparedImpl.isReleased;
	}
}

/++
Submit an SQL command to the server to be compiled into a prepared statement.

The result of a successful outcome will be a statement handle - an ID -
for the prepared statement, a count of the parameters required for
excution of the statement, and a count of the columns that will be present
in any result set that the command generates. Thes values will be stored
in in the Command struct.

The server will then proceed to send prepared statement headers,
including parameter descriptions, and result set field descriptions,
followed by an EOF packet.

Throws: MySQLException if there are pending result set items, or if the
server has a problem.
+/
Prepared prepare(Connection conn, string sql)
{
	return Prepared( refCounted(PreparedImpl(conn, sql)) );
}

/++
Convenience function to create a prepared statement which calls a stored function.

Throws: MySQLException if there are pending result set items, or if the
server has a problem.

Params:
	name = The name of the stored function.
	numArgs = The number of arguments the stored procedure takes.
+/
Prepared prepareFunction(Connection conn, string name, int numArgs)
{
	auto sql = "select " ~ name ~ preparedPlaceholderArgs(numArgs);
	return prepare(conn, sql);
}

///
unittest
{
	debug(MYSQL_INTEGRATION_TESTS)
	{
		import mysql.test.common;
		mixin(scopedCn);

		exec(cn, `DROP FUNCTION IF EXISTS hello`);
		exec(cn, `
			CREATE FUNCTION hello (s CHAR(20))
			RETURNS CHAR(50) DETERMINISTIC
			RETURN CONCAT('Hello ',s,'!')
		`);

		auto preparedHello = prepareFunction(cn, "hello", 1);
		preparedHello.setArgs("World");
		ResultSet rs = preparedHello.queryResult();
		assert(rs.length == 1);
		assert(rs[0][0] == "Hello World!");
	}
}

/++
Convenience function to create a prepared statement which calls a stored procedure.

OUT parameters are not currently supported. It should generally be
possible with MySQL to present them as a result set.

Throws: MySQLException if there are pending result set items, or if the
server has a problem.

Params:
	name = The name of the stored procedure.
	numArgs = The number of arguments the stored procedure takes.

+/
Prepared prepareProcedure(Connection conn, string name, int numArgs)
{
	auto sql = "call " ~ name ~ preparedPlaceholderArgs(numArgs);
	return prepare(conn, sql);
}

///
unittest
{
	debug(MYSQL_INTEGRATION_TESTS)
	{
		import mysql.test.common;
		mixin(scopedCn);
		initBaseTestTables(cn);

		exec(cn, `DROP PROCEDURE IF EXISTS insert2`);
		exec(cn, `
			CREATE PROCEDURE insert2 (IN p1 INT, IN p2 CHAR(50))
			BEGIN
				INSERT INTO basetest (intcol, stringcol) VALUES(p1, p2);
			END
		`);

		auto preparedInsert2 = prepareProcedure(cn, "insert2", 2);
		preparedInsert2.setArgs(2001, "inserted string 1");
		preparedInsert2.exec();

		ResultSet rs = queryResult(cn, "SELECT stringcol FROM basetest WHERE intcol=2001");
		assert(rs.length == 1);
		assert(rs[0][0] == "inserted string 1");
	}
}

private string preparedPlaceholderArgs(int numArgs)
{
	auto sql = "(";
	bool comma = false;
	foreach(i; 0..numArgs)
	{
		if (comma)
			sql ~= ",?";
		else
		{
			sql ~= "?";
			comma = true;
		}
	}
	sql ~= ")";

	return sql;
}

debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	assert(preparedPlaceholderArgs(3) == "(?,?,?)");
	assert(preparedPlaceholderArgs(2) == "(?,?)");
	assert(preparedPlaceholderArgs(1) == "(?)");
	assert(preparedPlaceholderArgs(0) == "()");
}

//TODO: Move this next to ColumnSpecialization definition
struct QuerySpecialization
{
	ColumnSpecialization[] csn;
	
	// Same notes apply
	//TODO: ulong exec(Connection cn, string sql)
	//TODO: ulong exec(Params...)(Connection cn, string sql, Params params)

	// Same notes apply
	//TODO: ResultSet query(Connection cn, string sql)
	//TODO: ResultSet query(Params...)(Connection cn, string sql, Params params)
	//querySingle/queryScalar/etc...

	// Same notes apply
	//TODO: Prepared prepare(Connection cn, string sql)
}

/++
Encapsulation of a prepared statement.

Commands that are expected to return a result set - queries - have distinctive methods
that are enforced. That is it will be an error to call such a method with an SQL command
that does not produce a result set.
+/
struct PreparedImpl
{
private:
	Connection _conn;
	QuerySpecialization _qsn;

	void enforceNotReleased()
	{
		enforceNotReleased(_hStmt);
	}

	static void enforceNotReleased(uint hStmt)
	{
		enforceEx!MYXNotPrepared(hStmt);
	}

	void enforceReadyForCommand()
	{
		enforceReadyForCommand(_conn, _hStmt);
	}

	static void enforceReadyForCommand(Connection conn, uint hStmt)
	{
		enforceNotReleased(hStmt);
		conn.enforceNothingPending();
	}

	debug(MYSQL_INTEGRATION_TESTS)
	unittest
	{
		import mysql.protocol.prepared;
		import mysql.test.common : scopedCn;
		mixin(scopedCn);

		cn.exec("DROP TABLE IF EXISTS `enforceNotReleased`");
		cn.exec("CREATE TABLE `enforceNotReleased` (
			`val` INTEGER
		) ENGINE=InnoDB DEFAULT CHARSET=utf8");

		immutable insertSQL = "INSERT INTO `enforceNotReleased` VALUES (1), (2)";
		immutable selectSQL = "SELECT * FROM `enforceNotReleased`";
		Prepared preparedInsert;
		Prepared preparedSelect;
		int queryTupleResult;
		assertNotThrown!MYXNotPrepared(preparedInsert = cn.prepare(insertSQL));
		assertNotThrown!MYXNotPrepared(preparedSelect = cn.prepare(selectSQL));
		assertNotThrown!MYXNotPrepared(preparedInsert.exec());
		assertNotThrown!MYXNotPrepared(preparedSelect.queryResult());
		assertNotThrown!MYXNotPrepared(preparedSelect.querySequence().each());
		assertNotThrown!MYXNotPrepared(preparedSelect.queryTuple(queryTupleResult));
		
		preparedInsert.release();
		assertThrown!MYXNotPrepared(preparedInsert.exec());
		assertNotThrown!MYXNotPrepared(preparedSelect.queryResult());
		assertNotThrown!MYXNotPrepared(preparedSelect.querySequence().each());
		assertNotThrown!MYXNotPrepared(preparedSelect.queryTuple(queryTupleResult));

		preparedSelect.release();
		assertThrown!MYXNotPrepared(preparedInsert.exec());
		assertThrown!MYXNotPrepared(preparedSelect.queryResult());
		assertThrown!MYXNotPrepared(preparedSelect.querySequence().each());
		assertThrown!MYXNotPrepared(preparedSelect.queryTuple(queryTupleResult));
	}

	@disable this(this); // Not copyable

	/++
	Submit an SQL command to the server to be compiled into a prepared statement.

	The result of a successful outcome will be a statement handle - an ID -
	for the prepared statement, a count of the parameters required for
	excution of the statement, and a count of the columns that will be present
	in any result set that the command generates. Thes values will be stored
	in in the Command struct.

	The server will then proceed to send prepared statement headers,
	including parameter descriptions, and result set field descriptions,
	followed by an EOF packet.

	If there is an existing statement handle in the Command struct, that
	prepared statement is released.

	Throws: MySQLException if there are pending result set items, or if the
	server has a problem.
	+/
	public this(Connection conn, string sql)
	{
		this._conn = conn;

		_conn.enforceNothingPending();

		scope(failure) conn.kill();

		conn.sendCmd(CommandType.STMT_PREPARE, sql);
		conn._fieldCount = 0;

		ubyte[] packet = conn.getPacket();
		if (packet.front == ResultPacketMarker.ok)
		{
			packet.popFront();
			_hStmt              = packet.consume!int();
			conn._fieldCount    = packet.consume!short();
			_psParams           = packet.consume!short();

			_inParams.length    = _psParams;
			_psa.length         = _psParams;

			packet.popFront(); // one byte filler
			_psWarnings         = packet.consume!short();

			// At this point the server also sends field specs for parameters
			// and columns if there were any of each
			_psh = PreparedStmtHeaders(conn, conn._fieldCount, _psParams);
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

package:
	uint _hStmt; // Server's identifier for this prepared statement. This is 0 when released.
	ushort _psParams, _psWarnings;
	PreparedStmtHeaders _psh;
	Variant[] _inParams;
	ParameterSpecialization[] _psa;

	static ubyte[] makeBitmap(in Variant[] inParams)
	{
		size_t bml = (inParams.length+7)/8;
		ubyte[] bma;
		bma.length = bml;
		foreach (i; 0..inParams.length)
		{
			if(inParams[i].type != typeid(typeof(null)))
				continue;
			size_t bn = i/8;
			size_t bb = i%8;
			ubyte sr = 1;
			sr <<= bb;
			bma[bn] |= sr;
		}
		return bma;
	}

	static ubyte[] makePSPrefix(uint hStmt, ubyte flags = 0) pure nothrow
	{
		ubyte[] prefix;
		prefix.length = 14;

		prefix[4] = CommandType.STMT_EXECUTE;
		hStmt.packInto(prefix[5..9]);
		prefix[9] = flags;   // flags, no cursor
		prefix[10] = 1; // iteration count - currently always 1
		prefix[11] = 0;
		prefix[12] = 0;
		prefix[13] = 0;

		return prefix;
	}

	static ubyte[] analyseParams(Variant[] inParams, ParameterSpecialization[] psa,
		out ubyte[] vals, out bool longData)
	{
		size_t pc = inParams.length;
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
			enum UNSIGNED  = 0x80;
			enum SIGNED    = 0;
			if (psa[i].chunkSize)
				longData= true;
			if (inParams[i].type == typeid(typeof(null)))
			{
				types[ct++] = SQLType.NULL;
				types[ct++] = SIGNED;
				continue;
			}
			Variant v = inParams[i];
			SQLType ext = psa[i].type;
			string ts = v.type.toString();
			bool isRef;
			if (ts[$-1] == '*')
			{
				ts.length = ts.length-1;
				isRef= true;
			}

			switch (ts)
			{
				case "bool":
					if (ext == SQLType.INFER_FROM_D_TYPE)
						types[ct++] = SQLType.BIT;
					else
						types[ct++] = cast(ubyte) ext;
					types[ct++] = SIGNED;
					reAlloc(2);
					bool bv = isRef? *(v.get!(bool*)): v.get!(bool);
					vals[vcl++] = 1;
					vals[vcl++] = bv? 0x31: 0x30;
					break;
				case "byte":
					types[ct++] = SQLType.TINY;
					types[ct++] = SIGNED;
					reAlloc(1);
					vals[vcl++] = isRef? *(v.get!(byte*)): v.get!(byte);
					break;
				case "ubyte":
					types[ct++] = SQLType.TINY;
					types[ct++] = UNSIGNED;
					reAlloc(1);
					vals[vcl++] = isRef? *(v.get!(ubyte*)): v.get!(ubyte);
					break;
				case "short":
					types[ct++] = SQLType.SHORT;
					types[ct++] = SIGNED;
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

	static void sendLongData(Connection conn, uint hStmt, ParameterSpecialization[] psa)
	{
		assert(psa.length <= ushort.max); // parameter number is sent as short
		foreach (ushort i, PSN psn; psa)
		{
			if (!psn.chunkSize) continue;
			uint cs = psn.chunkSize;
			uint delegate(ubyte[]) dg = psn.chunkDelegate;

			ubyte[] chunk;
			chunk.length = cs+11;
			chunk.setPacketHeader(0 /*each chunk is separate cmd*/);
			chunk[4] = CommandType.STMT_SEND_LONG_DATA;
			hStmt.packInto(chunk[5..9]); // statement handle
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
					conn.send(chunk);
					break;
				}
				conn.send(chunk);
			}
		}
	}

	/++
	Internal implementation for the exec and query functions.

	Execute a prepared command.
	
	Use this method when you will use the same SQL command repeatedly.
	It can be used with commands that don't produce a result set, or those that
	do. If there is a result set its existence will be indicated by the return value.
	
	Any result set can be accessed vis Connection.getNextRow(), but you should really be
	using execPreparedResult() or execPreparedSequence() for such queries.
	
	Params: ra = An out parameter to receive the number of rows affected.
	Returns: true if there was a (possibly empty) result set.
	+/
	static bool execQueryImpl(Connection conn, uint hStmt, PreparedStmtHeaders psh,
		ref Variant[] inParams, ref ParameterSpecialization[] psa, out ulong ra)
	{
		enforceReadyForCommand(conn, hStmt);
		scope(failure) conn.kill();

		ubyte[] packet;
		conn.resetPacket();

		ubyte[] prefix = makePSPrefix(hStmt, 0);
		size_t len = prefix.length;
		bool longData;

		if (psh._paramCount)
		{
			ubyte[] one = [ 1 ];
			ubyte[] vals;
			ubyte[] types = analyseParams(inParams, psa, vals, longData);
			ubyte[] nbm = makeBitmap(inParams);
			packet = prefix ~ nbm ~ one ~ types ~ vals;
		}
		else
			packet = prefix;

		if (longData)
			sendLongData(conn, hStmt, psa);

		assert(packet.length <= uint.max);
		packet.setPacketHeader(conn.pktNumber);
		conn.bumpPacket();
		conn.send(packet);
		packet = conn.getPacket();
		bool rv;
		if (packet.front == ResultPacketMarker.ok || packet.front == ResultPacketMarker.error)
		{
			conn.resetPacket();
			auto okp = OKErrorPacket(packet);
			enforcePacketOK(okp);
			ra = okp.affected;
			conn._serverStatus = okp.serverStatus;
			conn._insertID = okp.insertID;
			rv = false;
		}
		else
		{
			// There was presumably a result set
			conn._headersPending = conn._rowsPending = conn._binaryPending = true;
			auto lcb = packet.consumeIfComplete!LCB();
			assert(!lcb.isIncomplete);
			conn._fieldCount = cast(ushort)lcb.value;
			rv = true;
		}
		return rv;
	}
	
	bool execQueryImpl2(out ulong ra)
	{
		return execQueryImpl(_conn, _hStmt, _psh, _inParams, _psa, ra);
	}

	/// Has this statement been released?
	@property bool isReleased() pure const nothrow
	{
		return _hStmt == 0;
	}

public:
	/+ ******************************************

	// Returns rowsAffected
	// Throws if resultset was returned ("Use query insetad!")
	// Throws if already in the middle of receiving a resultset
	ulong exec()
	ulong exec(Params...)(Params params)

	// Throws if no result set returned ("Use exec insetad!")
	// Throws if already in the middle of receiving a resultset
	ResultSet query()
	ResultSet query(Params...)(Params params)

	ResultSequence query()()
	ResultSequence query(Params...)(Params params)
	ResultSet querySet()()
	ResultSet querySet(Params...)(Params params)
	//TODO: querySingle/queryScalar/etc...

	//bindParameters/bindParameterTuple... // TODO

	****************************************** +/

	~this()
	{
		release();
	}

	/++
	Execute a prepared command.
	
	Use this method when you will use the same SQL command repeatedly.
	It can be used with commands that don't produce a result set, or those that
	do. If there is a result set its existence will be indicated by the return value.
	
	Any result set can be accessed vis Connection.getNextRow(), but you should really be
	using execPreparedResult() or execPreparedSequence() for such queries.
	
	Returns: The number of rows affected.
	+/
	ulong exec()
	{
		enforceReadyForCommand();
		return execImpl(&execQueryImpl, _conn, _hStmt, _psh, _inParams, _psa);
	}

	/++
	Execute a prepared SQL command for the case where you expect a result set,
	and want it all at once.

	Use this method when you will use the same command repeatedly.
	This method will throw if the SQL command does not produce a result set.

	If there are long data items among the expected result columns you can specify
	that they are to be subject to chunked transfer via a delegate.

	Params: csa = An optional array of ColumnSpecialization structs.
	Returns: A (possibly empty) ResultSet.
	+/
	ResultSet queryResult(ColumnSpecialization[] csa = null)
	{
		enforceReadyForCommand();
		return queryResultImpl(&execQueryImpl, csa, true, _conn, _hStmt, _psh, _inParams, _psa);
	}

	/++
	Execute a prepared SQL command for the case where you expect a result set,
	and want to deal with it one row at a time.

	Use this method when you will use the same command repeatedly.
	This method will throw if the SQL command does not produce a result set.

	If there are long data items among the expected result columns you can
	specify that they are to be subject to chunked transfer via a delegate.

	Params: csa = An optional array of ColumnSpecialization structs.
	Returns: A (possibly empty) ResultSequence.
	+/
	ResultSequence querySequence(ColumnSpecialization[] csa = null)
	{
		enforceReadyForCommand();
		return querySequenceImpl(&execQueryImpl, csa, _conn, _hStmt, _psh, _inParams, _psa);
	}

	/++
	Execute a prepared SQL command to place result values into a set of D variables.
	
	Use this method when you will use the same command repeatedly.
	It will throw if the specified command does not produce a result set, or
	if any column type is incompatible with the corresponding D variable
	
	Params: args = A tuple of D variables to receive the results.
	Returns: true if there was a (possibly empty) result set.
	+/
	void queryTuple(T...)(ref T args)
	{
		enforceReadyForCommand();

		ulong ra;
		enforceEx!MYXNoResultRecieved(execQueryImpl(_conn, _hStmt, _psh, _inParams, _psa, ra));

		return queryTupleImpl(_conn, args);
	}

	/++
	Prepared statement parameter setter.

	The value may, but doesn't have to be, wrapped in a Variant.
	
	The value may, but doesn't have to be, a pointer to the desired value.

	The value can be null.

	Params: index = The zero based index
	+/
	//TODO? Change "ref Variant" to "Nullable!Variant"
	void setArg(T)(size_t index, T val, ParameterSpecialization psn = PSN(0, SQLType.INFER_FROM_D_TYPE, 0, null))
	{
		// Now in theory we should be able to check the parameter type here, since the
		// protocol is supposed to send us type information for the parameters, but this
		// capability seems to be broken. This assertion is supported by the fact that
		// the same information is not available via the MySQL C API either. It is up
		// to the programmer to ensure that appropriate type information is embodied
		// in the variant array, or provided explicitly. This sucks, but short of
		// having a client side SQL parser I don't see what can be done.

		enforceNotReleased();
		enforceEx!MYX(index < _psParams, "Parameter index out of range.");

		_inParams[index] = val;
		psn.pIndex = index;
		_psa[index] = psn;
	}

	/++
	Bind a tuple of D variables to the parameters of a prepared statement.
	
	You can use this method to bind a set of variables if you don't need any specialization,
	that is chunked transfer is not neccessary.
	
	The tuple must match the required number of parameters, and it is the programmer's
	responsibility to ensure that they are of appropriate types.
	+/
	void setArgs(T...)(T args)
		if(T.length == 0 || !is(T[0] == Variant[]))
	{
		enforceNotReleased();
		enforceEx!MYX(args.length == _psParams, "Argument list supplied does not match the number of parameters.");

		foreach (size_t i, dummy; args)
			_inParams[i] = args[i];
	}

	/++
	Bind a Variant[] as the parameters of a prepared statement.
	
	You can use this method to bind a set of variables in Variant form to
	the parameters of a prepared statement.
	
	Parameter specializations can be added if required. This method could be
	used to add records from a data entry form along the lines of
	------------
	auto c = Command(con, "insert into table42 values(?, ?, ?)");
	c.prepare();
	Variant[] va;
	va.length = 3;
	DataRecord dr;    // Some data input facility
	ulong ra;
	do
	{
	    dr.get();
	    va[0] = dr("Name");
	    va[1] = dr("City");
	    va[2] = dr("Whatever");
	    c.bindParameters(va);
	    c.execPrepared(ra);
	} while(tod < "17:30");
	------------
	Params: va = External list of Variants to be used as parameters
	               psnList = any required specializations
	+/
	//TODO? Overload with "Variant" to "Nullable!Variant"
	void setArgs(Variant[] va, ParameterSpecialization[] psnList= null)
	{
		enforceNotReleased();
		enforceEx!MYX(va.length == _psParams, "Param count supplied does not match prepared statement");
		_inParams[] = va[];
		if (psnList !is null)
		{
			foreach (PSN psn; psnList)
				_psa[psn.pIndex] = psn;
		}
	}

	/++
	Prepared statement parameter getter.

	Params: index = The zero based index
	+/
	//TODO? Change "ref Variant" to "Nullable!Variant"
	Variant getArg(size_t index)
	{
		enforceNotReleased();
		enforceEx!MYX(index < _psParams, "Parameter index out of range.");
		return _inParams[index];
	}

	/++
	Sets a prepared statement parameter to NULL.
	
	This is here mainly for legacy reasons. You can set a field to null
	simply by saying `prepared.setArg(index, null);`

	Params: index = The zero based index
	+/
	void setNullArg(size_t index)
	{
		enforceNotReleased();
		setArg(index, null);
	}

	debug(MYSQL_INTEGRATION_TESTS)
	unittest
	{
		import mysql.protocol.prepared;
		import mysql.test.common : scopedCn;
		mixin(scopedCn);

		cn.exec("DROP TABLE IF EXISTS `setNullArg`");
		cn.exec("CREATE TABLE `setNullArg` (
			`val` INTEGER
		) ENGINE=InnoDB DEFAULT CHARSET=utf8");

		immutable insertSQL = "INSERT INTO `setNullArg` VALUES (?)";
		immutable selectSQL = "SELECT * FROM `setNullArg`";
		auto preparedInsert = cn.prepare(insertSQL);
		ResultSet rs;

		preparedInsert.setArg(0, 5);
		preparedInsert.exec();
		rs = cn.queryResult(selectSQL);
		assert(rs.length == 1);
		assert(rs[0][0] == 5);

		preparedInsert.setArg(0, null);
		preparedInsert.exec();
		rs = cn.queryResult(selectSQL);
		assert(rs.length == 2);
		assert(rs[0][0] == 5);
		assert(rs[1].isNull(0));
		assert(rs[1][0].type == typeid(typeof(null)));

		preparedInsert.setArg(0, Variant(null));
		preparedInsert.exec();
		rs = cn.queryResult(selectSQL);
		assert(rs.length == 3);
		assert(rs[0][0] == 5);
		assert(rs[1].isNull(0));
		assert(rs[2].isNull(0));
		assert(rs[1][0].type == typeid(typeof(null)));
		assert(rs[2][0].type == typeid(typeof(null)));
	}

	/++
	Release a prepared statement.
	
	This method tells the server that it can dispose of the information it
	holds about the current prepared statement.
	+/
	void release()
	{
		if(!_hStmt)
			return;

		scope(failure) _conn.kill();

		ubyte[] packet;
		packet.length = 9;
		packet.setPacketHeader(0/*packet number*/);
		_conn.bumpPacket();
		packet[4] = CommandType.STMT_CLOSE;
		_hStmt.packInto(packet[5..9]);
		_conn.purgeResult();
		_conn.send(packet);
		// It seems that the server does not find it necessary to send a response
		// for this command.
		_hStmt = 0;
	}

	/// Gets the number of arguments this prepared statement expects to be passed in.
	@property ushort numArgs() pure const nothrow
	{
		return _psParams;
	}

	/// Gets the prepared header's field descriptions.
	@property FieldDescription[] preparedFieldDescriptions() pure { return _psh.fieldDescriptions; }

	/// Gets the prepared header's param descriptions.
	@property ParamDescription[] preparedParamDescriptions() pure { return _psh.paramDescriptions; }
}
