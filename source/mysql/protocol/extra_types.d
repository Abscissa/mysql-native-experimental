/// Internal - Protocol-related data types.
module mysql.protocol.extra_types;

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
import mysql.exceptions;
import mysql.protocol.sockets;
import mysql.result;

struct SQLValue
{
	bool isNull;
	bool isIncomplete;
	Variant _value;

	// empty template as a template and non-template won't be added to the same overload set
	@property inout(Variant) value()() inout
	{
		enforceEx!MYX(!isNull, "SQL value is null");
		enforceEx!MYX(!isIncomplete, "SQL value not complete");
		return _value;
	}

	@property void value(T)(T value)
	{
		enforceEx!MYX(!isNull, "SQL value is null");
		enforceEx!MYX(!isIncomplete, "SQL value not complete");
		_value = value;
	}

	pure const nothrow invariant()
	{
		isNull && assert(!isIncomplete);
		isIncomplete && assert(!isNull);
	}
}


/// Length Coded Binary Value
struct LCB
{
	/// True if the LCB contains a null value
	bool isNull;

	/// True if the packet that created this LCB didn't have enough bytes
	/// to store a value of the size specified. More bytes have to be fetched from the server
	bool isIncomplete;

	/// Number of bytes needed to store the value (Extracted from the LCB header. The header byte is not included)
	ubyte numBytes;

	/// Number of bytes total used for this LCB
	@property ubyte totalBytes() pure const nothrow
	{
		return cast(ubyte)(numBytes <= 1 ? 1 : numBytes+1);
	}

	/// The decoded value. This is always 0 if isNull or isIncomplete is set.
	ulong value;

	pure const nothrow invariant()
	{
		if(isIncomplete)
		{
			assert(!isNull);
			assert(value == 0);
			assert(numBytes > 0);
		}
		else if(isNull)
		{
			assert(!isIncomplete);
			assert(value == 0);
			assert(numBytes == 0);
		}
		else
		{
			assert(!isNull);
			assert(!isIncomplete);
			assert(numBytes > 0);
		}
	}
}

/// Length Coded String
struct LCS
{
	// dummy struct just to tell what value we are using
	// we don't need to store anything here as the result is always a string
}

/++
A struct to represent specializations of prepared statement parameters.

If you are executing a query that will include result columns that are large objects
it may be expedient to deal with the data as it is received rather than first buffering
it to some sort of byte array. These two variables allow for this. If both are provided
then the corresponding column will be fed to the stipulated delegate in chunks of
chunkSize, with the possible exception of the last chunk, which may be smaller.
The 'finished' argument will be set to true when the last chunk is set.

Be aware when specifying types for column specializations that for some reason the
field descriptions returned for a resultset have all of the types TINYTEXT, MEDIUMTEXT,
TEXT, LONGTEXT, TINYBLOB, MEDIUMBLOB, BLOB, and LONGBLOB lumped as type 0xfc
contrary to what it says in the protocol documentation.
+/
struct ColumnSpecialization
{
	size_t  cIndex;    // parameter number 0 - number of params-1
	ushort  type;
	uint    chunkSize;
	void delegate(const(ubyte)[] chunk, bool finished) chunkDelegate;
}
alias CSN = ColumnSpecialization;
