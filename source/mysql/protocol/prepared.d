﻿module mysql.protocol.prepared;

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
import mysql.protocol.packet_helpers;

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
//TODO: Maybe this should be a class, to prevent isReleased from going out-of-date on a copy.
//      Or maybe refcounted
struct Prepared
{
private:
	Connection _conn;
	QuerySpecialization _qsn;

	//TODO: Test enforceNothingPending
	void enforceNotReleased()
	{
		enforceEx!MYX(_hStmt, "The prepared statement has already been released.");
	}

	//TODO: Test enforceNothingPending
	void enforceNothingPending()
	{
		//TODO: Implement Prepared.enforceNothingPending
	}

	void enforceReadyForCommand()
	{
		enforceNotReleased();
		enforceNothingPending();
	}

package:
	uint _hStmt;
	ushort _psParams, _psWarnings;
	PreparedStmtHeaders _psh;
	Variant[] _inParams;  //TODO? Convert to Nullable!Variant
	ParameterSpecialization[] _psa;

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

	// Set ParameterSpecialization.isNull for all null values.
	// This may not be the best way to handle it, but it'll do for now.
	void fixupNulls()
	{
		foreach (size_t i; 0.._inParams.length)
		{
			if (_inParams[i].type == typeid(typeof(null)))
				_psa[i].isNull = true;
		}
	}

	ubyte[] analyseParams(out ubyte[] vals, out bool longData)
	{
		fixupNulls();

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
			enum UNSIGNED  = 0x80;
			enum SIGNED    = 0;
			if (_psa[i].chunkSize)
				longData= true;
			if (_psa[i].isNull)
			{
				types[ct++] = SQLType.NULL;
				types[ct++] = SIGNED;
				continue;
			}
			Variant v = _inParams[i];
			SQLType ext = _psa[i].type;
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
					_conn.send(chunk);
					break;
				}
				_conn.send(chunk);
			}
		}
	}

	/++
	Execute a prepared command.
	
	Use this method when you will use the same SQL command repeatedly.
	It can be used with commands that don't produce a result set, or those that
	do. If there is a result set its existence will be indicated by the return value.
	
	Any result set can be accessed vis Connection.getNextRow(), but you should really be
	using execPreparedResult() or execPreparedSequence() for such queries.
	
	Params: ra = An out parameter to receive the number of rows affected.
	Returns: true if there was a (possibly empty) result set.
	+/
	bool execImpl(out ulong ra)
	{
		enforceReadyForCommand();
		scope(failure) _conn.kill();

		ubyte[] packet;
		_conn.resetPacket();

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
		packet.setPacketHeader(_conn.pktNumber);
		_conn.bumpPacket();
		_conn.send(packet);
		packet = _conn.getPacket();
		bool rv;
		if (packet.front == ResultPacketMarker.ok || packet.front == ResultPacketMarker.error)
		{
			_conn.resetPacket();
			auto okp = OKErrorPacket(packet);
			enforcePacketOK(okp);
			ra = okp.affected;
			_conn._serverStatus = okp.serverStatus;
			_conn._insertID = okp.insertID;
			rv = false;
		}
		else
		{
			// There was presumably a result set
			_conn._headersPending = _conn._rowsPending = _conn._binaryPending = true;
			auto lcb = packet.consumeIfComplete!LCB();
			assert(!lcb.isIncomplete);
			_conn._fieldCount = cast(ushort)lcb.value;
			rv = true;
		}
		return rv;
	}

public:
	/+ ******************************************

	//TODO: Returns rowsAffected
	//TODO: Throws if resultset was returned ("Use query insetad!")
	//TODO: Throws if already in the middle of receiving a resultset
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
	//TODO: Throws if already in the middle of receiving a resultset
	this(Connection conn, string sql)
	{
		this._conn = conn;

		enforceEx!MYX(!(conn._headersPending || conn._rowsPending),
			"There are result set elements pending - purgeResult() required.");

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

	/++
	Execute a prepared command.
	
	Use this method when you will use the same SQL command repeatedly.
	It can be used with commands that don't produce a result set, or those that
	do. If there is a result set its existence will be indicated by the return value.
	
	Any result set can be accessed vis Connection.getNextRow(), but you should really be
	using execPreparedResult() or execPreparedSequence() for such queries.
	
	Returns: The number of rows affected.
	+/
	//TODO: Unittest: Throws if resultset was returned ("Use query instead!")
	ulong exec()
	{
		enforceReadyForCommand();

		ulong rowsAffected;
		auto receivedResultSet = execImpl(rowsAffected);
		enforceEx!MYX(
			receivedResultSet,
			"A result set was returned. Use the query functions, not exec, "~
			"for commands that return result sets."
		);
		
		return rowsAffected;
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
	//TODO: Unittest: Throws if resultset NOT returned ("Use exec instead!")
	ResultSet queryResult(ColumnSpecialization[] csa = null)
	{
		enforceReadyForCommand();

		ulong ra;
		enforceEx!MYX(execImpl(ra),
			"The executed query did not produce a result set. Use the exec "~
			"functions, not query, for commands that don't produce result sets.");

		uint alloc = 20;
		Row[] rra;
		rra.length = alloc;
		uint cr = 0;
		_conn._rsh = ResultSetHeaders(_conn, _conn._fieldCount);
		if (csa !is null)
			_conn._rsh.addSpecializations(csa);
		_conn._headersPending = false;

		ubyte[] packet;
		for (size_t i = 0;; i++)
		{
			scope(failure) _conn.kill();
			
			packet = _conn.getPacket();
			if (packet.isEOFPacket())
				break;
			Row row = Row(_conn, packet, _conn._rsh, true);
			if (cr >= alloc)
			{
				alloc = (alloc*3)/2;
				rra.length = alloc;
			}
			rra[cr++] = row;
			if (!packet.empty && packet.isEOFPacket())
				break;
		}
		_conn._rowsPending = _conn._binaryPending = false;
		rra.length = cr;
		ResultSet rs = ResultSet(rra, _conn._rsh.fieldNames);
		return rs;
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
	//TODO: Unittest: Throws if resultset NOT returned ("Use exec instead!")
	//TODO: This needs unittested
	ResultSequence querySequence(ColumnSpecialization[] csa = null)
	{
		enforceReadyForCommand();

		ulong ra;
		enforceEx!MYX(execImpl(ra),
			"The executed query did not produce a result set. Use the exec "~
			"functions, not query, for commands that don't produce result sets.");

		uint alloc = 20;
		Row[] rra;
		rra.length = alloc;
		uint cr = 0;
		_conn._rsh = ResultSetHeaders(_conn, _conn._fieldCount);
		if (csa !is null)
			_conn._rsh.addSpecializations(csa);
		_conn._headersPending = false;
		return ResultSequence(_conn, _conn._rsh, _conn._rsh.fieldNames);
	}

	/++
	Execute a prepared SQL command to place result values into a set of D variables.
	
	Use this method when you will use the same command repeatedly.
	It will throw if the specified command does not produce a result set, or
	if any column type is incompatible with the corresponding D variable
	
	Params: args = A tuple of D variables to receive the results.
	Returns: true if there was a (possibly empty) result set.
	+/
	//TODO: Unittest: Throws if resultset NOT returned ("Use exec instead!")
	void queryTuple(T...)(ref T args)
	{
		enforceReadyForCommand();

		ulong ra;
		enforceEx!MYX(execImpl(ra),
			"The executed query did not produce a result set. Use the exec "~
			"functions, not query, for commands that don't produce result sets.");
		Row rr = _conn.getNextRow();
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
		_conn.purgeResult();
	}

	/++
	Prepared statement parameter setter.

	The value may, but doesn't have to be, wrapped in a Variant.
	
	The value may, but doesn't have to be, be a pointer to the desired value.

	The value can be null.

	Params: index = The zero based index
	+/
	//TODO? Change "ref Variant" to "Nullable!Variant"
	void setParam(T)(size_t index, T val, ParameterSpecialization psn = PSN(0, false, SQLType.INFER_FROM_D_TYPE, 0, null))
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
		fixupNulls();
	}

	/++
	Bind a tuple of D variables to the parameters of a prepared statement.
	
	You can use this method to bind a set of variables if you don't need any specialization,
	that is chunked transfer is not neccessary.
	
	The tuple must match the required number of parameters, and it is the programmer's
	responsibility to ensure that they are of appropriate types.
	+/
	void setParams(T...)(T args)
		if(T.length == 0 || !is(T[0] == Variant[]))
	{
		enforceNotReleased();
		enforceEx!MYX(args.length == _psParams, "Argument list supplied does not match the number of parameters.");

		foreach (size_t i, dummy; args)
			_inParams[i] = &args[i];
		fixupNulls();
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
	//TODO: Move to struct Prepared
	//TODO? Overload with "Variant" to "Nullable!Variant"
	void setParams(Variant[] va, ParameterSpecialization[] psnList= null)
	{
		enforceNotReleased();
		enforceEx!MYX(va.length == _psParams, "Param count supplied does not match prepared statement");
		_inParams[] = va[];
		if (psnList !is null)
		{
			foreach (PSN psn; psnList)
				_psa[psn.pIndex] = psn;
		}
		fixupNulls();
	}

	/++
	Prepared statement parameter getter.

	Params: index = The zero based index
	+/
	//TODO? Change "ref Variant" to "Nullable!Variant"
	Variant getParam(size_t index)
	{
		enforceNotReleased();
		enforceEx!MYX(index < _psParams, "Parameter index out of range.");
		return _inParams[index];
	}

	/++
	Sets a prepared statement parameter to NULL.
	
	Params: index = The zero based index
	+/
	void setNullParam(size_t index)
	{
		enforceNotReleased();
		setParam(index, null);
		//setParam(index, Variant(null));
		/+
		//TODO: Encapsulate this and check for it on ALL access to Prepared
		enforceEx!MYX(_hStmt, "The prepared statement has already been released.");

		enforceEx!MYX(index < _psParams, "Parameter index out of range.");
		_inParams[index] = Variant(null);
		fixupNulls();
		+/
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

	/// Has this statement been released?
	@property bool isReleased() pure const nothrow
	{
		return _hStmt == 0;
	}

	/// Gets the number of parameters in this Command
	@property ushort numParams() pure const nothrow
	{
		return _psParams;
	}

	/// Gets the prepared header's field descriptions.
	@property FieldDescription[] preparedFieldDescriptions() pure { return _psh.fieldDescriptions; }

	/// Gets the prepared header's param descriptions.
	@property ParamDescription[] preparedParamDescriptions() pure { return _psh.paramDescriptions; }
}