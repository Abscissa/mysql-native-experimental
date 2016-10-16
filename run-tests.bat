@echo off
echo Doing Phobos-socket tests... && run-phobos-tests && echo Doing Vibe-socket tests... && dub test -c unittest-vibe
