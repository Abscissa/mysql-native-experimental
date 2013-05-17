This is a native D driver for MySQL.

It does not utilize any of the MySQL header files, or the MySQL client
library, being based instead on the published and unencumbered MySQL
client/server protocol description.

This can be used with ordinary Phobos sockets, or with [Vibe.d's](http://vibed.org)
sockets. You can optionally eliminate this module's dependency on Vibe.d, if
you don't intend to use it, by passing ```-version=MySQLN_NoVibeD``` to the
compiler. Then, this won't rely on anything besides Phobos.
