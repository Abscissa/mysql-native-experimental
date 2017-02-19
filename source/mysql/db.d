/++
Deprecated. This module is now named `mysql.pool`.
Module `mysql.db` will be removed in a later release.
+/
module mysql.db;

public import mysql.connection;
public import mysql.pool;

version(Have_vibe_d_core)
{
	/// For clarity, this has been renamed from `mysql.db.MysqlDB` to `mysql.pool.MySQLPool`
	deprecated("Use mysql.pool.MySQLPool instead.")
	alias MysqlDB = MySQLPool;
}
