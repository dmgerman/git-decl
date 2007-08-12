#!/bin/sh
#
# Copyright (c) 2006 Junio C Hamano
#

test_description='quoted output'

. ./test-lib.sh

P1='pathname	with HT'
: >"$P1" 2>&1 && test -f "$P1" && rm -f "$P1" || {
	echo >&2 'Filesystem does not support HT in names'
	test_done
}

FN='濱野'
GN='純'
HT='	'
LF='
'
DQ='"'

for_each_name () {
	for name in \
	    Name "Name and a${LF}LF" "Name and an${HT}HT" "Name${DQ}" \
	    "$FN$HT$GN" "$FN$LF$GN" "$FN $GN" "$FN$GN" "$FN$DQ$GN" \
	    "With SP in it"
	do
		eval "$1"
	done
}

test_expect_success setup '

	for_each_name "echo initial >\"\$name\""
	git add . &&
	git commit -q -m Initial &&

	for_each_name "echo second >\"\$name\"" &&
	git commit -a -m Second

	for_each_name "echo modified >\"\$name\""

'

cat >expect.quoted <<\EOF
Name
"Name and a\nLF"
"Name and an\tHT"
"Name\""
With SP in it
"\346\277\261\351\207\216\t\347\264\224"
"\346\277\261\351\207\216\n\347\264\224"
"\346\277\261\351\207\216 \347\264\224"
"\346\277\261\351\207\216\"\347\264\224"
"\346\277\261\351\207\216\347\264\224"
EOF

cat >expect.raw <<\EOF
Name
"Name and a\nLF"
"Name and an\tHT"
"Name\""
With SP in it
"濱野\t純"
"濱野\n純"
濱野 純
"濱野\"純"
濱野純
EOF

test_expect_success 'check fully quoted output from ls-files' '

	git ls-files >current && diff -u expect.quoted current

'

test_expect_success 'check fully quoted output from diff-files' '

	git diff --name-only >current &&
	diff -u expect.quoted current

'

test_expect_success 'check fully quoted output from diff-index' '

	git diff --name-only HEAD >current &&
	diff -u expect.quoted current

'

test_expect_success 'check fully quoted output from diff-tree' '

	git diff --name-only HEAD^ HEAD >current &&
	diff -u expect.quoted current

'

test_expect_success 'setting core.quotepath' '

	git config --bool core.quotepath false

'

test_expect_success 'check fully quoted output from ls-files' '

	git ls-files >current && diff -u expect.raw current

'

test_expect_success 'check fully quoted output from diff-files' '

	git diff --name-only >current &&
	diff -u expect.raw current

'

test_expect_success 'check fully quoted output from diff-index' '

	git diff --name-only HEAD >current &&
	diff -u expect.raw current

'

test_expect_success 'check fully quoted output from diff-tree' '

	git diff --name-only HEAD^ HEAD >current &&
	diff -u expect.raw current

'

test_done
