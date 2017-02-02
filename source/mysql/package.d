module mysql;

public import mysql.common;
public import mysql.connection;
public import mysql.escape;
public import mysql.pool;
public import mysql.protocol.commands;
public import mysql.protocol.constants;
public import mysql.protocol.extra_types;
public import mysql.protocol.packet_helpers;
public import mysql.protocol.packets;
public import mysql.protocol.prepared;
public import mysql.result;

debug(MYSQL_INTEGRATION_TESTS)
{
	public import mysql.test.common;
	public import mysql.test.integration;
	public import mysql.test.regression;

	void main() {}
}
