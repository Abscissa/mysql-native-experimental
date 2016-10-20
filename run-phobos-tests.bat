@echo off

rem GDC doesn't autocreate the dir (and git doesn't beleive in empty dirs)
mkdir bin >NUL 2>NUL

echo Compiling Phobos-socket tests...
rdmd --build-only -g -unittest -debug=MYSQL_INTEGRATION_TESTS -ofbin/mysqln-tests-phobos -Isource source/mysql/package.d && echo Running Phobos-socket tests... && bin/mysqln-tests-phobos
