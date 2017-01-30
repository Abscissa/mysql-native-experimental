A [Boost-licensed](http://www.boost.org/LICENSE_1_0.txt) native [D](http://dlang.org)
client driver for MySQL and MariaDB.

This package attempts to provide composite objects and methods that will
allow a wide range of common database operations, but be relatively easy to
use. It has no dependecies on GPL header files or libraries, instead communicating
directly with the server via the
[published client/server protocol](LINK http://dev.mysql.com/doc/internals/en/client-server-protocol.html).

The primary interfaces:
- Connection: Connection to the server, and querying and setting of server parameters.
- exec(): Plain old SQL query, returns number of rows affected
- query(): Execute an SQL statement and handle the rows one at a time, as an input range.
- querySet(): Execute an SQL statement and get a complete result set.
- queryRow(): Execute an SQL statement and get the first row.
- queryRowTuple(): Execute an SQL statement and get the first row into a matching tuple of D variables.
- queryValue(): Execute an SQL statement and get the first value in the first row.
- prepare(): Create a prepared statement
- Prepared: A prepared statement, with principal methods:
	- exec()/query()/querySet()/etc.: Just like above, but using a prepared statement.
	- setArg(): Set one argument to pass into the prepared statement.
	- setArgs(): Set all arguments to pass in.
	- getArg(): Get an argument that's been set.
	- release(): Optional. Prepared is refcounted.
- Row: One "row" of results, used much like an array of Variant.
- ResultSequence: An input range of rows.
- ResultSet: A random access range of rows.

Basic example:
```d
import std.variant;
import mysql;

void main(string[] args)
{
	// Connect
	auto connectionStr = args[1];
	Connection conn = new Connection(connectionStr);
	scope(exit) con.close();

	// Insert
	auto rowsAffected = exec(conn,
		"INSERT INTO `tablename` (`id`, `name`) VALUES (1, `Ann`), (2, `Bob`)");

	// Query
	ResultSequence range = query(conn, "SELECT * FROM `tablename`");
	Row row = range.front;
	Variant id = row[0];
	Variant name = row[1];
	assert(id == 1);
	assert(name == "Ann");

	range.popFront();
	assert(range.front[0] == 2);
	assert(range.front[1] == "Bob");

	// Prepared statements
	Prepared prepared = prepare(conn, "SELECT * FROM `tablename` WHERE `name`=? OR `name`=?");
	prepared.setArgs("Bob", "Bobby");
	ResultSequence bobs = prepared.query();
	bobs.close(); // Skip them
	
	prepared.setArgs("Bob", "Ann");
	ResultSet rs = prepared.querySet();
	assert(rs.length == 1);
	assert(rs[0][0] == 1);
	assert(rs[0][1] == "Ann");
	assert(rs[1][0] == 2);
	assert(rs[1][1] == "Bob");

	// Nulls
	Prepared insert = prepare(conn, "INSERT INTO `tablename` (`id`, `name`) VALUES (?,?)");
	insert.setArgs(null, "Cam"); // Also takes Nullable!T
	insert.exec();
	range = query("SELECT * FROM `tablename` WHERE `name`='Cam'");
	assert( range.front[0][0].type == typeid(typeof(null)) );
}
```

This package supports both Phobos sockets and [Vibe.d](http://vibed.org/)
sockets. Vibe.d support is disabled by default, to avoid unnecessary
depencency on Vibe.d. To enable Vibe.d support, use:
	`-version=Have_vibe_d_core`

If you compile using [DUB](http://code.dlang.org/getting_started),
and your project uses Vibe.d, then the -version flag above will be included
automatically.

This requires MySQL server v4.1.1 or later, or a MariaDB server. Older
versions of MySQL server are obsolete, use known-insecure authentication,
and are not supported by this package.

See [.travis.yml](https://github.com/mysql-d/mysql-native/blob/master/.travis.yml)
for a list of officially supported D compiler versions.

A note on connections: Normally MySQL clients connect to a server on
the same machine via a Unix socket on *nix systems,
and through a named pipe on Windows. Neither of these conventions is
currently supported. TCP is used for all connections.

See also the [old homepage](http://britseyeview.com/software/mysqln/)
for the original release of this project is. Parts of it are out-of-date,
but it still provides a decent overview of the current API. More up-to-date
docs with examples are on the way, and are currently a high priority.

Developers - How to run the test suite
--------------------------------------

This package contains various unittests and integration tests. To run them,
run `dub test`.

The first time you run `dub test`, it will automatically create a
file `testConnectionStr.txt` in project's base diretory and then exit.
This file is deliberately not contained in the source repository
because it's specific to your system.

Open the `testConnectionStr.txt` file and verify the connection settings
inside, modifying them as needed, and if necessary, creating a test user and
blank test schema in your MySQL database.

The tests will completely clobber anything inside the db schema provided,
but they will ONLY modify that one db schema. No other schema will be
modified in any way.

After you've configured the connection string, run `dub test` again
and their tests will be compiled and run, first using Phobos sockets,
then using Vibe sockets.
