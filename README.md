A [Boost-licensed](www.boost.org/LICENSE_1_0.txt) native D client driver
for MySQL and MariaDB.

This package attempts to provide composite objects and methods that will
allow a wide range of common database operations, but be relatively easy to
use. The design is a first attempt to illustrate the structure of a set of
modules to cover popular database systems and ODBC.

It has no dependecies on GPL header files or libraries, instead communicating
directly with the server via the
[published client/server protocol](LINK http://dev.mysql.com/doc/internals/en/client-server-protocol.html).

This version is not by any means comprehensive, and there is still a good
deal of work to do. As a general design position it avoids providing
wrappers for operations that can be accomplished by simple SQL sommands,
unless the command produces a result set. There are some instances of the
latter category to provide simple meta-data for the database.

Its primary objects are:
- Connection: Connection to the server, and querying and setting of server parameters.
- Command: Handling of SQL requests/queries/commands, with principal methods:
	- execSQL() - plain old SQL query.
	- execSQLTuple() - get a set of values from a select or similar query into a matching tuple of D variables.
	- execPrepared() - execute a prepared statement.
	- execSQLResult() - execute a raw SQL statement and get a complete result set.
	- execSQLSequence() - execute a raw SQL statement and handle the rows one at a time.
	- execPreparedResult() - execute a prepared statement and get a complete result set.
	- execPreparedSequence() - execute a prepared statement and handle the rows one at a time.
	- execFunction() - execute a stored function with D variables as input and output.
	- execProcedure() - execute a stored procedure with D variables as input.
- ResultSet: $(UL $(LI A random access range of rows, where a Row is basically an array of variant.
- ResultSequence: $(UL $(LIAn input range of similar rows.

There are numerous examples of usage in the unittest sections.

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

The old homepage for the original release of this project is
[here](http://britseyeview.com/software/mysqln/). Parts of it are out-of-date,
but it still provides a decent overview of the API. More up-to-date docs with
examples are on the way, and are currently a high priority.

Developers - How to run the test suite
--------------------------------------

This package contains various unittests and integration tests. To run them,
run `dub test`.

The first time you run `dub test`, it will automatically create a
file 'testConnectionStr.txt' in project's base diretory and then exit.
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
