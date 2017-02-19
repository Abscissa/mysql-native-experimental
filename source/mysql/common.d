/++
Common functionality, such as exceptions and internal phobos/vibe.d socket wrappers.
+/

module mysql.common;

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

version(Have_vibe_d_core)
{
	static if(__traits(compiles, (){ import vibe.core.net; } ))
		import vibe.core.net;
	else
		static assert(false, "mysql-native can't find Vibe.d's 'vibe.core.net'.");
}

/++
An exception type to distinguish exceptions thrown by this package.
+/
class MySQLException: Exception
{
	this(string msg, string file = __FILE__, size_t line = __LINE__) pure
	{
		super(msg, file, line);
	}
}
alias MYX = MySQLException;

/++
Thrown when attempting to communicate with the server (ex: executing SQL or
creating a new prepared statement) while the server is still sending results
data. Any ResultRange must be consumed or purged before anything else
can be done on the connection.
+/
class MySQLDataPendingException: MySQLException
{
	this(string file = __FILE__, size_t line = __LINE__) pure
	{
		super("Data is pending on the connection. Any existing ResultRange "~
			"must be consumed or purged before performing any other communication "~
			"with the server.", file, line);
	}
}
alias MYXDataPending = MySQLDataPendingException;

/++
Received invalid data from the server which violates the MySQL network protocol.
(Quite possibly mysql-native's fault. Please
$(LINK2 https://github.com/mysql-d/mysql-native/issues, file an issue)
if you receive this.)
+/
class MySQLProtocolException: MySQLException
{
	this(string msg, string file, size_t line) pure
	{
		super(msg, file, line);
	}
}
alias MYXProtocol = MySQLProtocolException;

/++
Thrown when attempting to use a prepared statement which had already been released.
+/
class MySQLNotPreparedException: MySQLException
{
	this(string file = __FILE__, size_t line = __LINE__) pure
	{
		super("The prepared statement has already been released.", file, line);
	}
}
alias MYXNotPrepared = MySQLNotPreparedException;

/++
Common base class of MySQLResultRecievedException and MySQLNoResultRecievedException.

Thrown when making the wrong choice between exec or query.

The query functions (query, querySet, queryRow, etc.) are for SQL statements
such as SELECT that return results (even if the result set has zero elements.)

The exec functions are for SQL statements, such as INSERT, that never return
result sets, but may return rowsAffected.

Using one of those functions, when the other should have been used instead,
results in an exception derived from this.
+/
class MySQLWrongFunctionException: MySQLException
{
	this(string msg, string file = __FILE__, size_t line = __LINE__) pure
	{
		super(msg, file, line);
	}
}
alias MYXWrongFunction = MySQLWrongFunctionException;

/++
Thrown when a result set was returned unexpectedly. Use the query functions
(query, querySet, queryRow, etc.), not exec for commands that return
result sets (such as SELECT), even if the result set has zero elements.
+/
class MySQLResultRecievedException: MySQLWrongFunctionException
{
	this(string file = __FILE__, size_t line = __LINE__) pure
	{
		super(
			"A result set was returned. Use the query functions, not exec, "~
			"for commands that return result sets.",
			file, line
		);
	}
}
alias MYXResultRecieved = MySQLResultRecievedException;

/++
Thrown when the executed query, unexpectedly, did not produce a result set.
Use the exec functions, not query (query, querySet, queryRow, etc.),
for commands that don't produce result sets (such as INSERT).
+/
class MySQLNoResultRecievedException: MySQLWrongFunctionException
{
	this(string msg, string file = __FILE__, size_t line = __LINE__) pure
	{
		super(
			"The executed query did not produce a result set. Use the exec "~
			"functions, not query, for commands that don't produce result sets.",
			file, line
		);
	}
}
alias MYXNoResultRecieved = MySQLNoResultRecievedException;

/++
Thrown when attempting to use a range that's been invalidated.
In particular, when using a ResultRange after a new command
has been issued on the same connection.
+/
class MySQLInvalidatedRangeException: MySQLException
{
	this(string msg, string file = __FILE__, size_t line = __LINE__) pure
	{
		super(msg, file, line);
	}
}
alias MYXInvalidatedRange = MySQLInvalidatedRangeException;

debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	import mysql.commands;
	import mysql.prepared;
	import mysql.test.common : scopedCn, createCn;
	mixin(scopedCn);

	cn.exec("DROP TABLE IF EXISTS `wrongFunctionException`");
	cn.exec("CREATE TABLE `wrongFunctionException` (
		`val` INTEGER
	) ENGINE=InnoDB DEFAULT CHARSET=utf8");

	immutable insertSQL = "INSERT INTO `wrongFunctionException` VALUES (1), (2)";
	immutable selectSQL = "SELECT * FROM `wrongFunctionException`";
	Prepared preparedInsert;
	Prepared preparedSelect;
	int queryTupleResult;
	assertNotThrown!MYXWrongFunction(cn.exec(insertSQL));
	assertNotThrown!MYXWrongFunction(cn.querySet(selectSQL));
	assertNotThrown!MYXWrongFunction(cn.query(selectSQL).each());
	assertNotThrown!MYXWrongFunction(cn.queryRowTuple(selectSQL, queryTupleResult));
	assertNotThrown!MYXWrongFunction(preparedInsert = cn.prepare(insertSQL));
	assertNotThrown!MYXWrongFunction(preparedSelect = cn.prepare(selectSQL));
	assertNotThrown!MYXWrongFunction(preparedInsert.exec());
	assertNotThrown!MYXWrongFunction(preparedSelect.querySet());
	assertNotThrown!MYXWrongFunction(preparedSelect.query().each());
	assertNotThrown!MYXWrongFunction(preparedSelect.queryRowTuple(queryTupleResult));

	assertThrown!MYXResultRecieved(cn.exec(selectSQL));
	assertThrown!MYXNoResultRecieved(cn.querySet(insertSQL));
	assertThrown!MYXNoResultRecieved(cn.query(insertSQL).each());
	assertThrown!MYXNoResultRecieved(cn.queryRowTuple(insertSQL, queryTupleResult));
	assertThrown!MYXResultRecieved(preparedSelect.exec());
	assertThrown!MYXNoResultRecieved(preparedInsert.querySet());
	assertThrown!MYXNoResultRecieved(preparedInsert.query().each());
	assertThrown!MYXNoResultRecieved(preparedInsert.queryRowTuple(queryTupleResult));
}


// Phobos/Vibe.d type aliases
package alias PlainPhobosSocket = std.socket.TcpSocket;
version(Have_vibe_d_core)
{
	package alias PlainVibeDSocket = vibe.core.net.TCPConnection;
}
else
{
	// Dummy types
	package alias PlainVibeDSocket = Object;
}

alias OpenSocketCallbackPhobos = PlainPhobosSocket function(string,ushort);
alias OpenSocketCallbackVibeD = PlainVibeDSocket function(string,ushort);

enum MySQLSocketType { phobos, vibed }

// A minimal socket interface similar to Vibe.d's TCPConnection.
// Used to wrap both Phobos and Vibe.d sockets with a common interface.
package interface MySQLSocket
{
	void close();
	@property bool connected() const;
	void read(ubyte[] dst);
	void write(in ubyte[] bytes);

	void acquire();
	void release();
	bool isOwner();
	bool amOwner();
}

// Wraps a Phobos socket with the common interface
package class MySQLSocketPhobos : MySQLSocket
{
	private PlainPhobosSocket socket;

	// The socket should already be open
	this(PlainPhobosSocket socket)
	{
		enforceEx!MYX(socket, "Tried to use a null Phobos socket - Maybe the 'openSocket' callback returned null?");
		enforceEx!MYX(socket.isAlive, "Tried to use a closed Phobos socket - Maybe the 'openSocket' callback created a socket but forgot to open it?");
		this.socket = socket;
	}

	invariant()
	{
		assert(!!socket);
	}

	void close()
	{
		socket.shutdown(SocketShutdown.BOTH);
		socket.close();
	}

	@property bool connected() const
	{
		return socket.isAlive;
	}

	void read(ubyte[] dst)
	{
		// Note: I'm a little uncomfortable with this line as it doesn't
		// (and can't) update Connection._open. Not sure what can be done,
		// but perhaps Connection._open should be eliminated in favor of
		// querying the socket's opened/closed state directly.
		scope(failure) socket.close();

		for (size_t off, len; off < dst.length; off += len) {
			len = socket.receive(dst[off..$]);
			enforceEx!MYX(len != 0, "Server closed the connection");
			enforceEx!MYX(len != socket.ERROR, "Received std.socket.Socket.ERROR");
		}
	}

	void write(in ubyte[] bytes)
	{
		socket.send(bytes);
	}

	void acquire() { /+ Do nothing +/ }
	void release() { /+ Do nothing +/ }
	bool isOwner() { return true; }
	bool amOwner() { return true; }
}

// Wraps a Vibe.d socket with the common interface
version(Have_vibe_d_core) {
	package class MySQLSocketVibeD : MySQLSocket
	{
		private PlainVibeDSocket socket;

		// The socket should already be open
		this(PlainVibeDSocket socket)
		{
			enforceEx!MYX(socket, "Tried to use a null Vibe.d socket - Maybe the 'openSocket' callback returned null?");
			enforceEx!MYX(socket.connected, "Tried to use a closed Vibe.d socket - Maybe the 'openSocket' callback created a socket but forgot to open it?");
			this.socket = socket;
		}

		invariant()
		{
			assert(!!socket);
		}

		void close()
		{
			socket.close();
		}

		@property bool connected() const
		{
			return socket.connected;
		}

		void read(ubyte[] dst)
		{
			socket.read(dst);
		}

		void write(in ubyte[] bytes)
		{
			socket.write(bytes);
		}

		static if (is(typeof(&TCPConnection.isOwner))) {
			void acquire() { socket.acquire(); }
			void release() { socket.release(); }
			bool isOwner() { return socket.isOwner(); }
			bool amOwner() { return socket.isOwner(); }
		} else {
			void acquire() { /+ Do nothing +/ }
			void release() { /+ Do nothing +/ }
			bool isOwner() { return true; }
			bool amOwner() { return true; }
		}
	}
}
