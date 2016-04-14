/**
 * A native D driver for the MySQL database system. Source file mysql.d.
 *
 * This module attempts to provide composite objects and methods that will
 * allow a wide range of common database operations, but be relatively easy to
 * use. The design is a first attempt to illustrate the structure of a set of
 * modules to cover popular database systems and ODBC.
 *
 * It has no dependecies on GPL header files or libraries, instead communicating
 * directly with the server via the published client/server protocol.
 *
 * $(LINK http://dev.mysql.com/doc/internals/en/client-server-protocol.html)$(BR)
 *
 * This version is not by any means comprehensive, and there is still a good
 * deal of work to do. As a general design position it avoids providing
 * wrappers for operations that can be accomplished by simple SQL sommands,
 * unless the command produces a result set. There are some instances of the
 * latter category to provide simple meta-data for the database,
 *
 * Its primary objects are:
 * $(UL
 *    $(LI Connection: $(UL $(LI Connection to the server, and querying and setting of server parameters.)))
 *    $(LI Command:  Handling of SQL requests/queries/commands, with principal methods:
 *       $(UL $(LI execSQL() - plain old SQL query.)
 *            $(LI execSQLTuple() - get a set of values from a select or similar query into a matching tuple of D variables.)
 *            $(LI execPrepared() - execute a prepared statement.)
 *            $(LI execSQLResult() - execute a raw SQL statement and get a complete result set.)
 *            $(LI execSQLSequence() - execute a raw SQL statement and handle the rows one at a time.)
 *            $(LI execPreparedResult() - execute a prepared statement and get a complete result set.)
 *            $(LI execPreparedSequence() - execute a prepared statement and handle the rows one at a time.)
 *            $(LI execFunction() - execute a stored function with D variables as input and output.)
 *            $(LI execProcedure() - execute a stored procedure with D variables as input.)
 *        )
 *    )
 *    $(LI ResultSet: $(UL $(LI A random access range of rows, where a Row is basically an array of variant.)))
 *    $(LI ResultSequence: $(UL $(LIAn input range of similar rows.)))
 * )
 *
 * There are numerous examples of usage in the unittest sections.
 *
 * The file mysqld.sql, included with the module source code, can be used to
 * generate the tables required by the unit tests.
 *
 * This module supports both Phobos sockets and $(LINK http://vibed.org/, Vibe.d)
 * sockets. Vibe.d support is disabled by default, to avoid unnecessary
 * depencency on Vibe.d. To enable Vibe.d support, use:
 *   -version=Have_vibe_d
 *
 * If you compile using $(LINK https://github.com/rejectedsoftware/dub, DUB),
 * and your project uses Vibe.d, then the -version flag above will be included
 * automatically.
 *
 * This requires DMD v2.064.2 or later, and a MySQL server v4.1.1 or later. Older
 * versions of MySQL server are obsolete, use known-insecure authentication,
 * and are not supported by this module.
 *
 * There is an outstanding issue with Connections. Normally MySQL clients
 * connect to a server on the same machine via a Unix socket on *nix systems,
 * and through a named pipe on Windows. Neither of these conventions is
 * currently supported. TCP must be used for all connections.
 *
 * Developers - How to run the test suite:
 *
 * This package contains various unittests and integration tests. To run them,
 * first compile mysql-native's connection.d with the following flags:
 *   -g -unittest -debug=MYSQL_INTEGRATION_TESTS -ofmysqln_tests
 * 
 * Then, running 'mysqln_tests' once will automatically create a file
 * 'testConnectionStr.txt' in the same directory as 'mysqln_tests' and then
 * exit. This file is deliberately not contained in the source repository
 * because it's specific to your system.
 * 
 * Open the 'testConnectionStr.txt' file and verify the connection settings
 * inside, modifying them as needed, and if necessary, creating a test user and
 * blank test schema in your MySQL database.
 * 
 * The tests will completely clobber anything inside the db schema provided,
 * but they will ONLY modify that one db schema. No other schema will be
 * modified in any way.
 * 
 * After you've configured the connection string, run 'mysqln_tests' again
 * and their tests will be run.
 *
 * Copyright: Copyright 2011
 * License:   $(LINK www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Steve Teale, James W. Oliphant, simendsjo, Sönke Ludwig, sshamov, Nick Sabalausky
 */
module mysql;

public import mysql.common;
public import mysql.connection;
public import mysql.escape;
public import mysql.db;
public import mysql.result;
public import mysql.protocol.commands;
public import mysql.protocol.constants;
public import mysql.protocol.extra_types;
public import mysql.protocol.packet_helpers;
public import mysql.protocol.packets;

debug(MYSQL_INTEGRATION_TESTS)
{
	public import mysql.test.common;
	public import mysql.test.integration;
	public import mysql.test.regression;
}
