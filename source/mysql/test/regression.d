/++
This contains regression tests for the issues at:
https://github.com/rejectedsoftware/mysql-native/issues

Regression unittests, like other unittests, are located together with
the units they test.
+/
module mysql.test.regression;

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

import mysql.commands;
import mysql.connection;
import mysql.exceptions;
import mysql.protocol.sockets;
import mysql.result;
import mysql.test.common;

// Issue #40: Decoding LCB value for large feilds
// And likely Issue #18: select varchar - thinks the package is incomplete while it's actually complete
debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	mixin(scopedCn);
	auto cmd = Command(cn);
	ulong rowsAffected;
	cmd.sql = 
		"DROP TABLE IF EXISTS `issue40`";
	cmd.execSQL(rowsAffected);
	cmd.sql = 
		"CREATE TABLE `issue40` (
		`str` varchar(255)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8";
	cmd.execSQL(rowsAffected);
	
	auto longString = repeat('a').take(251).array().idup;
	cmd.sql = "INSERT INTO `issue40` VALUES('"~longString~"')";
	cmd.execSQL(rowsAffected);
	cmd.sql = "SELECT * FROM `issue40`";
	cmd.execSQLResult();

	cmd.sql = "DELETE FROM `issue40`";
	cmd.execSQL(rowsAffected);

	longString = repeat('a').take(255).array().idup;
	cmd.sql = "INSERT INTO `issue40` VALUES('"~longString~"')";
	cmd.execSQL(rowsAffected);
	cmd.sql = "SELECT * FROM `issue40`";
	cmd.execSQLResult();
}

// Issue #24: Driver doesn't like BIT
debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	mixin(scopedCn);
	auto cmd = Command(cn);
	ulong rowsAffected;
	cmd.sql = 
		"DROP TABLE IF EXISTS `issue24`";
	cmd.execSQL(rowsAffected);
	cmd.sql = 
		"CREATE TABLE `issue24` (
		`bit` BIT,
		`date` DATE
		) ENGINE=InnoDB DEFAULT CHARSET=utf8";
	cmd.execSQL(rowsAffected);
	
	cmd.sql = "INSERT INTO `issue24` (`bit`, `date`) VALUES (1, '1970-01-01')";
	cmd.execSQL(rowsAffected);
	cmd.sql = "INSERT INTO `issue24` (`bit`, `date`) VALUES (0, '1950-04-24')";
	cmd.execSQL(rowsAffected);

	cmd = Command(cn, "SELECT `bit`, `date` FROM `issue24` ORDER BY `date` DESC");
	cmd.prepare();
	auto results = cmd.execPreparedResult();
	assert(results.length == 2);
	assert(results[0][0] == true);
	assert(results[0][1] == Date(1970, 1, 1));
	assert(results[1][0] == false);
	assert(results[1][1] == Date(1950, 4, 24));
}

// Issue #33: TINYTEXT, TEXT, MEDIUMTEXT, LONGTEXT types treated as ubyte[]
debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	mixin(scopedCn);
	auto cmd = Command(cn);
	ulong rowsAffected;
	cmd.sql = 
		"DROP TABLE IF EXISTS `issue33`";
	cmd.execSQL(rowsAffected);
	cmd.sql = 
		"CREATE TABLE `issue33` (
		`text` TEXT,
		`blob` BLOB
		) ENGINE=InnoDB DEFAULT CHARSET=utf8";
	cmd.execSQL(rowsAffected);
	
	cmd.sql = "INSERT INTO `issue33` (`text`, `blob`) VALUES ('hello', 'world')";
	cmd.execSQL(rowsAffected);

	cmd = Command(cn, "SELECT `text`, `blob` FROM `issue33`");
	cmd.prepare();
	auto results = cmd.execPreparedResult();
	assert(results.length == 1);
	auto pText = results[0][0].peek!string();
	auto pBlob = results[0][1].peek!(ubyte[])();
	assert(pText);
	assert(pBlob);
	assert(*pText == "hello");
	assert(*pBlob == cast(ubyte[])"world".dup);
}

// Issue #39: Unsupported SQL type NEWDECIMAL
debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	mixin(scopedCn);
	auto cmd = Command(cn);
	cmd.sql = "SELECT SUM(123.456)";
	auto rows = cmd.execSQLResult();
	assert(rows.length == 1);
	assert(rows[0][0] == 123.456);
}

// Issue #56: Result set quantity does not equal MySQL rows quantity
debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	mixin(scopedCn);
	auto cmd = Command(cn);
	ulong rowsAffected;
	cmd.sql = "DROP TABLE IF EXISTS `issue56`";
	cmd.execSQL(rowsAffected);
	cmd.sql = 
		"CREATE TABLE `issue56` (a datetime DEFAULT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8";
	cmd.execSQL(rowsAffected);
	
	cmd.sql = "INSERT INTO `issue56` VALUES
		('2015-03-28 00:00:00')
		,('2015-03-29 00:00:00')
		,('2015-03-31 00:00:00')
		,('2015-03-31 00:00:00')
		,('2015-03-31 00:00:00')
		,('2015-03-31 00:00:00')
		,('2015-04-01 00:00:00')
		,('2015-04-02 00:00:00')
		,('2015-04-03 00:00:00')
		,('2015-04-04 00:00:00')";

	cmd.execSQL(rowsAffected);

	cmd = Command(cn);
	cmd.sql = "SELECT a FROM `issue56`";
	cmd.prepare();

	auto res = cmd.execPreparedResult();
	assert(res.length == 10);
}

// Issue #66: Can't connect when omitting default database
debug(MYSQL_INTEGRATION_TESTS)
unittest
{
	auto a = Connection.parseConnectionString(testConnectionStr);

	{
		// Sanity check:
		auto cn = new Connection(a[0], a[1], a[2], a[3], to!ushort(a[4]));
		scope(exit) cn.close();
	}

	{
		// Ensure it works without a default database
		auto cn = new Connection(a[0], a[1], a[2], "", to!ushort(a[4]));
		scope(exit) cn.close();
	}
}
