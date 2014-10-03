/** 
 * This contains regression tests for the issues at:
 * https://github.com/rejectedsoftware/mysql-native/issues
 * 
 * Regression unittests, like other unittests, are located together with
 * the units they test.
 */
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

import mysql.common;
import mysql.connection;
import mysql.result;
import mysql.test.common;

// Issue #40 (and likely #18)
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

// Issue #39
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
