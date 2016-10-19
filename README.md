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

The old, original homepage for the project is
[here](http://britseyeview.com/software/mysqln/). Parts of it are out-of-date,
but it still provides a decent overview of the API. More up-to-date docs with
examples are on the way, and are currently a top priority.
