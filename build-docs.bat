@echo off
rdmd --build-only -c -Isource -Dddocs_tmp -X -Xfdocs/docs.json --force source/mysql/package.d
rmdir /S /Q docs_tmp > NUL 2> NUL
del source\mysql\package.exe
ddox filter docs/docs.json --min-protection Public
ddox generate-html docs/docs.json docs/public --navigation-type=ModuleTree
