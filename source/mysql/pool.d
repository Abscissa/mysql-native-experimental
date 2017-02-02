/++
A lightweight interface to a MySQL/MariaDB  database using vibe.d's ConnectionPool.

You have to include vibe.d in your project to be able to use this class.
If you don't want to, refer to mysql.connection.
+/
module mysql.pool;

import std.conv;
import mysql.connection;
import mysql.protocol.constants;

version(Have_vibe_d_core)
{
	import vibe.core.connectionpool;

	/++
	A lightweight interface to a MySQL/MariaDB  database using vibe.d's ConnectionPool.

	You have to include vibe.d in your project to be able to use this class.
	If you don't want to, refer to mysql.connection.
	+/
	class MySqlPool {
		private {
			string m_host;
			string m_user;
			string m_password;
			string m_database;
			ushort m_port;
			SvrCapFlags m_capFlags;
			ConnectionPool!Connection m_pool;
		}

		this(string host, string user, string password, string database, ushort port = 3306, SvrCapFlags capFlags = defaultClientFlags)
		{
			m_host = host;
			m_user = user;
			m_password = password;
			m_database = database;
			m_port = port;
			m_capFlags = capFlags;
			m_pool = new ConnectionPool!Connection(&createConnection);
		}

		this(string connStr, SvrCapFlags capFlags = defaultClientFlags)
		{
			auto parts = Connection.parseConnectionString(connStr);
			this(parts[0], parts[1], parts[2], parts[3], to!ushort(parts[4]), capFlags);
		}

		/// Obtain a connection. If one isn't available, a new one will be created.
		auto lockConnection() { return m_pool.lockConnection(); }

		private Connection createConnection()
		{
			return new Connection(m_host, m_user, m_password, m_database, m_port, m_capFlags);
		}
	}
}
