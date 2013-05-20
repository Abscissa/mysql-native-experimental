This is a native D driver for MySQL.

It does not utilize any of the MySQL header files, or the MySQL client
library, being based instead on the published and unencumbered MySQL
client/server protocol description.

This module supports both Phobos sockets and [Vibe.d](http://vibed.org/) sockets.
Vibe.d support is disabled by default, to avoid unnecessary depencency on Vibe.d.
To enable Vibe.d support, use ```-version=Have_vibe_d```.

If you compile using [DUB](https://github.com/rejectedsoftware/dub),
and your project uses Vibe.d, then the -version flag above will be included
automatically.
