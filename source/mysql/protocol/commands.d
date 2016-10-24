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
import mysql.protocol.packet_helpers;
import mysql.protocol.prepared;

/++
Encapsulation of an SQL command or query.

A Command be be either a one-off SQL query, or may use a prepared statement.
Commands that are expected to return a result set - queries - have distinctive methods
that are enforced. That is it will be an error to call such a method with an SQL command
that does not produce a result set.
+/
struct Command
{
package:
	Connection _con;    // This can disappear along with Command
	const(char)[] _sql; // This can disappear along with Command
	string _prevFunc; // Has to do with stored procedures
	Prepared _prepared; // The current prepared statement info

public:

	/++
	Construct a naked Command object
	
	Params: con = A Connection object to communicate with the server
	+/
	// This can disappear along with Command
	this(Connection con)
	{
		_con = con;
		_con.resetPacket();
	}

	/++
	Construct a Command object complete with SQL
	
	Params: con = A Connection object to communicate with the server
	               sql = SQL command string.
	+/
	// This can disappear along with Command
	this(Connection con, const(char)[] sql)
	{
		_sql = sql;
		this(con);
	}

	@property
	{
		/// Get the current SQL for the Command
		// This can disappear along with Command
		const(char)[] sql() pure const nothrow { return _sql; }

		/++
		Set a new SQL command.
		
		This can have quite profound side effects. It resets the Command to
		an initial state. If a query has been issued on the Command that
		produced a result set, then all of the result set packets - field
		description sequence, EOF packet, result rows sequence, EOF packet
		must be flushed from the server before any further operation can be
		performed on the Connection. If you want to write speedy and efficient
		MySQL programs, you should bear this in mind when designing your
		queries so that you are not requesting many rows when one would do.
		
		Params: sql = SQL command string.
		+/
		// This can disappear along with Command
		const(char)[] sql(const(char)[] sql)
		{
			if (!_prepared.isReleased)
			{
				_con.purgeResult();
				releaseStatement();
				_con.resetPacket();
			}
			return this._sql = sql;
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
	
	If there is an existing statement handle in the Command struct, that
	prepared statement is released.
	
	Throws: MySQLException if there are pending result set items, or if the
	server has a problem.
	+/
	deprecated("Use Prepare.this(Connection conn, string sql) instead")
	void prepare()
	{
		_prepared = Prepared(_con, _sql.idup);
	}

	/++
	Release a prepared statement.
	
	This method tells the server that it can dispose of the information it
	holds about the current prepared statement, and resets the Command
	object to an initial state in that respect.
	+/
	deprecated("Use Prepared.release instead")
	void releaseStatement()
	{
		_prepared.release();
	}

	/++
	Flush any outstanding result set elements.
	
	When the server responds to a command that produces a result set, it
	queues the whole set of corresponding packets over the current connection.
	Before that Connection can embark on any new command, it must receive
	all of those packets and junk them.
	http://www.mysqlperformanceblog.com/2007/07/08/mysql-net_write_timeout-vs-wait_timeout-and-protocol-notes/
	+/
	deprecated("Use Connection.purgeResult() instead.")
	ulong purgeResult()
	{
		return _con.purgeResult();
	}

	/++
	Bind a D variable to a prepared statement parameter.
	
	In this implementation, binding comprises setting a value into the
	appropriate element of an array of Variants which represent the
	parameters, and setting any required specializations.
	
	To bind to some D variable, we set the corrsponding variant with its
	address, so there is no need to rebind between calls to execPreparedXXX.
	+/
	deprecated("Use Prepared.setParam instead")
	void bindParameter(T)(ref T val, size_t pIndex, ParameterSpecialization psn = PSN(0, false, SQLType.INFER_FROM_D_TYPE, 0, null))
	{
		enforceEx!MYX(!_prepared.isReleased, "The statement must be prepared before parameters are bound.");
		_prepared.setParam(pIndex, &val, psn);
	}

	/++
	Bind a tuple of D variables to the parameters of a prepared statement.
	
	You can use this method to bind a set of variables if you don't need any specialization,
	that is there will be no null values, and chunked transfer is not neccessary.
	
	The tuple must match the required number of parameters, and it is the programmer's
	responsibility to ensure that they are of appropriate types.
	+/
	deprecated("Use Prepared.setParams instead")
	void bindParameterTuple(T...)(ref T args)
	{
		enforceEx!MYX(!_prepared.isReleased, "The statement must be prepared before parameters are bound.");
		enforceEx!MYX(args.length == _prepared.numParams, "Argument list supplied does not match the number of parameters.");
		foreach (size_t i, dummy; args)
			_prepared.setParam(&args[i], i);
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
	deprecated("Use Prepared.setParams instead")
	void bindParameters(Variant[] va, ParameterSpecialization[] psnList= null)
	{
		_prepared.setParams(va, psnList);
	}

	/++
	Access a prepared statement parameter for update.
	
	Another style of usage would simply update the parameter Variant directly
	
	------------
	c.param(0) = 42;
	c.param(1) = "The answer";
	------------
	Params: index = The zero based index
	+/
	//TODO: Move to struct Prepared
	//TODO: Change "ref Variant" to "Nullable!Variant"
	deprecated("Use Prepared.getParam to get and Prepared.setParam to set.")
	ref Variant param(size_t index) pure
	{
		enforceEx!MYX(!_prepared.isReleased, "The statement must be prepared before parameters are bound.");
		enforceEx!MYX(index < _prepared.numParams, "Parameter index out of range.");
		return _prepared._inParams[index];
	}

	/++
	Prepared statement parameter getter.

	Params: index = The zero based index
	+/
	//TODO? Change "ref Variant" to "Nullable!Variant"
	deprecated("Use Prepared.getParam instead.")
	Variant getParam(size_t index)
	{
		enforceEx!MYX(!_prepared.isReleased, "The statement must be prepared before parameters are bound.");
		return _prepared.getParam(index);
	}

	/++
	Sets a prepared statement parameter to NULL.
	
	Params: index = The zero based index
	+/
	deprecated("Use Prepared.setNullParam instead.")
	void setNullParam(size_t index)
	{
		enforceEx!MYX(!_prepared.isReleased, "The statement must be prepared before parameters are bound.");
		_prepared.setNullParam(index);
	}

	/++
	Execute a one-off SQL command.
	
	Use this method when you are not going to be using the same command repeatedly.
	It can be used with commands that don't produce a result set, or those that
	do. If there is a result set its existence will be indicated by the return value.
	
	Any result set can be accessed vis Connection.getNextRow(), but you should really be
	using execSQLResult() or execSQLSequence() for such queries.
	
	Params: ra = An out parameter to receive the number of rows affected.
	Returns: true if there was a (possibly empty) result set.
	+/
	bool execSQL(out ulong ra)
	{
		scope(failure) _con.kill();

		_con.sendCmd(CommandType.QUERY, _sql);
		_con._fieldCount = 0;
		ubyte[] packet = _con.getPacket();
		bool rv;
		if (packet.front == ResultPacketMarker.ok || packet.front == ResultPacketMarker.error)
		{
			_con.resetPacket();
			auto okp = OKErrorPacket(packet);
			enforcePacketOK(okp);
			ra = okp.affected;
			_con._serverStatus = okp.serverStatus;
			_con._insertID = okp.insertID;
			rv = false;
		}
		else
		{
			// There was presumably a result set
			assert(packet.front >= 1 && packet.front <= 250); // ResultSet packet header should have this value
			_con._headersPending = _con._rowsPending = true;
			_con._binaryPending = false;
			auto lcb = packet.consumeIfComplete!LCB();
			assert(!lcb.isNull);
			assert(!lcb.isIncomplete);
			_con._fieldCount = cast(ushort)lcb.value;
			assert(_con._fieldCount == lcb.value);
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
	
	/++
	Execute a one-off SQL command for the case where you expect a result set,
	and want it all at once.
	
	Use this method when you are not going to be using the same command repeatedly.
	This method will throw if the SQL command does not produce a result set.
	
	If there are long data items among the expected result columns you can specify
	that they are to be subject to chunked transfer via a delegate.
	
	Params: csa = An optional array of ColumnSpecialization structs.
	Returns: A (possibly empty) ResultSet.
	+/
	ResultSet execSQLResult(ColumnSpecialization[] csa = null)
	{
		ulong ra;
		enforceEx!MYX(execSQL(ra), "The executed query did not produce a result set.");

		_con._rsh = ResultSetHeaders(_con, _con._fieldCount);
		if (csa !is null)
			_con._rsh.addSpecializations(csa);
		_con._headersPending = false;

		Row[] rows;
		while(true)
		{
			auto packet = _con.getPacket();
			if(packet.isEOFPacket())
				break;
			rows ~= Row(_con, packet, _con._rsh, false);
			// As the row fetches more data while incomplete, it might already have
			// fetched the EOF marker, so we have to check it again
			if(!packet.empty && packet.isEOFPacket())
				break;
		}
		_con._rowsPending = _con._binaryPending = false;

		return ResultSet(rows, _con._rsh.fieldNames);
	}

	/++
	Execute a one-off SQL command for the case where you expect a result set,
	and want to deal with it a row at a time.
	
	Use this method when you are not going to be using the same command repeatedly.
	This method will throw if the SQL command does not produce a result set.
	
	If there are long data items among the expected result columns you can specify
	that they are to be subject to chunked transfer via a delegate.
	
	Params: csa = An optional array of ColumnSpecialization structs.
	Returns: A (possibly empty) ResultSequence.
	+/
	//TODO: This needs unittested
	ResultSequence execSQLSequence(ColumnSpecialization[] csa = null)
	{
		uint alloc = 20;
		Row[] rra;
		rra.length = alloc;
		uint cr = 0;
		ulong ra;
		enforceEx!MYX(execSQL(ra), "The executed query did not produce a result set.");
		_con._rsh = ResultSetHeaders(_con, _con._fieldCount);
		if (csa !is null)
			_con._rsh.addSpecializations(csa);

		_con._headersPending = false;
		return ResultSequence(_con, _con._rsh, _con._rsh.fieldNames);
	}

	/++
	Execute a one-off SQL command to place result values into a set of D variables.
	
	Use this method when you are not going to be using the same command repeatedly.
	It will throw if the specified command does not produce a result set, or if
	any column type is incompatible with the corresponding D variable.
	
	Params: args = A tuple of D variables to receive the results.
	Returns: true if there was a (possibly empty) result set.
	+/
	void execSQLTuple(T...)(ref T args)
	{
		ulong ra;
		enforceEx!MYX(execSQL(ra), "The executed query did not produce a result set.");
		Row rr = _con.getNextRow();
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
		_con.purgeResult();
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
	deprecated("Use Prepared.exec instead")
	bool execPrepared(out ulong ra)
	{
		enforceEx!MYX(!_prepared.isReleased, "The statement must be prepared.");
		return _prepared.execImpl(ra);
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
	deprecated("Use Prepared.queryResult instead")
	ResultSet execPreparedResult(ColumnSpecialization[] csa = null)
	{
		enforceEx!MYX(!_prepared.isReleased, "The statement must be prepared.");
		return _prepared.queryResult(csa);
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
	//TODO: This needs unittested
	deprecated("Use Prepared.querySequence instead")
	ResultSequence execPreparedSequence(ColumnSpecialization[] csa = null)
	{
		enforceEx!MYX(!_prepared.isReleased, "The statement must be prepared.");
		return _prepared.querySequence(csa);
	}

	/++
	Execute a prepared SQL command to place result values into a set of D variables.
	
	Use this method when you will use the same command repeatedly.
	It will throw if the specified command does not produce a result set, or
	if any column type is incompatible with the corresponding D variable
	
	Params: args = A tuple of D variables to receive the results.
	Returns: true if there was a (possibly empty) result set.
	+/
	deprecated("Use Prepared.queryTuple instead")
	void execPreparedTuple(T...)(ref T args)
	{
		enforceEx!MYX(!_prepared.isReleased, "The statement must be prepared.");
		_prepared.queryTuple(args);
	}

	/++
	Get the next Row of a pending result set.
	
	This method can be used after either execSQL() or execPrepared() have returned true
	to retrieve result set rows sequentially.
	
	Similar functionality is available via execSQLSequence() and execPreparedSequence() in
	which case the interface is presented as a forward range of Rows.
	
	This method allows you to deal with very large result sets either a row at a time,
	or by feeding the rows into some suitable container such as a linked list.
	
	Returns: A Row object.
	+/
	deprecated("Use Connection.getNextRow() instead.")
	Row getNextRow()
	{
		return _con.getNextRow();
	}

	/++
	Execute a stored function, with any required input variables, and store the
	return value into a D variable.
	
	For this method, no query string is to be provided. The required one is of
	the form "select foo(?, ? ...)". The method generates it and the appropriate
	bindings - in, and out. Chunked transfers are not supported in either
	direction. If you need them, create the parameters separately, then use
	execPreparedResult() to get a one-row, one-column result set.
	
	If it is not possible to convert the column value to the type of target,
	then execFunction will throw. If the result is NULL, that is indicated
	by a false return value, and target is unchanged.
	
	In the interest of performance, this method assumes that the user has the
	equired information about the number and types of IN parameters and the
	type of the output variable. In the same interest, if the method is called
	repeatedly for the same stored function, prepare() is omitted after the first call.
	
	Params:
	   T = The type of the variable to receive the return result.
	   U = type tuple of arguments
	   name = The name of the stored function.
	   target = the D variable to receive the stored function return result.
	   args = The list of D variables to act as IN arguments to the stored function.
	
	+/
	bool execFunction(T, U...)(string name, ref T target, U args)
	{
		bool repeatCall = (name == _prevFunc);
		enforceEx!MYX(repeatCall || _prepared.isReleased, "You must not prepare the statement before calling execFunction");
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
		Row rr = _con.getNextRow();
		/+enforceEx!MYX(rr._valid, "The result set was empty.");+/
		enforceEx!MYX(rr._values.length == 1, "Result was not a single column.");
		enforceEx!MYX(typeid(target).toString() == rr._values[0].type.toString(),
						"Target type and column type are not compatible.");
		if (!rr.isNull(0))
			target = rr._values[0].get!(T);
		// If there were more rows, flush them away
		// Question: Should I check in purgeResult and throw if there were - it's very inefficient to
		// allow sloppy SQL that does not ensure just one row!
		_con.purgeResult();
		return !rr.isNull(0);
	}

	/++
	Execute a stored procedure, with any required input variables.
	
	For this method, no query string is to be provided. The required one is
	of the form "call proc(?, ? ...)". The method generates it and the
	appropriate in bindings. Chunked transfers are not supported. If you
	need them, create the parameters separately, then use execPrepared() or
	execPreparedResult().
	
	In the interest of performance, this method assumes that the user has
	the required information about the number and types of IN parameters.
	In the same interest, if the method is called repeatedly for the same
	stored function, prepare() and other redundant operations are omitted
	after the first call.
	
	OUT parameters are not currently supported. It should generally be
	possible with MySQL to present them as a result set.
	
	Params:
		T = Type tuple
		name = The name of the stored procedure.
		args = Tuple of args
	Returns: True if the SP created a result set.
	+/
	bool execProcedure(T...)(string name, ref T args)
	{
		bool repeatCall = (name == _prevFunc);
		enforceEx!MYX(repeatCall || _prepared.isReleased, "You must not prepare a statement before calling execProcedure");
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
	deprecated("Use Connection.lastInsertID instead")
	@property ulong lastInsertID() pure const nothrow { return _con.lastInsertID; }

	/// Gets the number of parameters in this Command
	deprecated("Use Prepared.numParams instead")
	@property ushort numParams() pure const nothrow
	{
		return _prepared.numParams;
	}

	/// Gets whether rows are pending
	deprecated("Use Connection.rowsPending instead")
	@property bool rowsPending() pure const nothrow { return _con.rowsPending; }

	/// Gets the result header's field descriptions.
	deprecated("Use Connection.resultFieldDescriptions instead")
	@property FieldDescription[] resultFieldDescriptions() pure { return _con.resultFieldDescriptions; }

	/// Gets the prepared header's field descriptions.
	deprecated("Use Prepared.preparedFieldDescriptions instead")
	@property FieldDescription[] preparedFieldDescriptions() pure { return _prepared._psh.fieldDescriptions; }

	/// Gets the prepared header's param descriptions.
	deprecated("Use Prepared.preparedParamDescriptions instead")
	@property ParamDescription[] preparedParamDescriptions() pure { return _prepared._psh.paramDescriptions; }
}
