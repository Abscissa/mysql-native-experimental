/// Imports all of mysql-native.
module mysql;

public import mysql.commands;
public import mysql.connection;
public import mysql.escape;
public import mysql.exceptions;
public import mysql.metadata;
public import mysql.pool;
public import mysql.prepared;
public import mysql.protocol.constants : SvrCapFlags;
public import mysql.result;
public import mysql.types;

debug(MYSQL_INTEGRATION_TESTS)
{
	public import mysql.protocol.constants;
	public import mysql.protocol.extra_types;
	public import mysql.protocol.packet_helpers;
	public import mysql.protocol.packets;
	public import mysql.protocol.sockets;

	public import mysql.test.common;
	public import mysql.test.integration;
	public import mysql.test.regression;

	void main() {}
}
