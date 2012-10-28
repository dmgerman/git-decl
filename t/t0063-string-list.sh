#!/bin/sh
#
# Copyright (c) 2012 Michael Haggerty
#

test_description='Test string list functionality'

. ./test-lib.sh

test_split () {
	cat >expected &&
	test_expect_success "split $1 at $2, max $3" "
		test-string-list split '$1' '$2' '$3' >actual &&
		test_cmp expected actual &&
		test-string-list split_in_place '$1' '$2' '$3' >actual &&
		test_cmp expected actual
	"
}

test_split "foo:bar:baz" ":" "-1" <<EOF
3
[0]: "foo"
[1]: "bar"
[2]: "baz"
EOF

test_split "foo:bar:baz" ":" "0" <<EOF
1
[0]: "foo:bar:baz"
EOF

test_split "foo:bar:baz" ":" "1" <<EOF
2
[0]: "foo"
[1]: "bar:baz"
EOF

test_split "foo:bar:baz" ":" "2" <<EOF
3
[0]: "foo"
[1]: "bar"
[2]: "baz"
EOF

test_split "foo:bar:" ":" "-1" <<EOF
3
[0]: "foo"
[1]: "bar"
[2]: ""
EOF

test_split "" ":" "-1" <<EOF
1
[0]: ""
EOF

test_split ":" ":" "-1" <<EOF
2
[0]: ""
[1]: ""
EOF

test_expect_success "test filter_string_list" '
	test "x-" = "x$(test-string-list filter - y)" &&
	test "x-" = "x$(test-string-list filter no y)" &&
	test yes = "$(test-string-list filter yes y)" &&
	test yes = "$(test-string-list filter no:yes y)" &&
	test yes = "$(test-string-list filter yes:no y)" &&
	test y1:y2 = "$(test-string-list filter y1:y2 y)" &&
	test y2:y1 = "$(test-string-list filter y2:y1 y)" &&
	test "x-" = "x$(test-string-list filter x1:x2 y)"
'

test_expect_success "test remove_duplicates" '
	test "x-" = "x$(test-string-list remove_duplicates -)" &&
	test "x" = "x$(test-string-list remove_duplicates "")" &&
	test a = "$(test-string-list remove_duplicates a)" &&
	test a = "$(test-string-list remove_duplicates a:a)" &&
	test a = "$(test-string-list remove_duplicates a:a:a:a:a)" &&
	test a:b = "$(test-string-list remove_duplicates a:b)" &&
	test a:b = "$(test-string-list remove_duplicates a:a:b)" &&
	test a:b = "$(test-string-list remove_duplicates a:b:b)" &&
	test a:b:c = "$(test-string-list remove_duplicates a:b:c)" &&
	test a:b:c = "$(test-string-list remove_duplicates a:a:b:c)" &&
	test a:b:c = "$(test-string-list remove_duplicates a:b:b:c)" &&
	test a:b:c = "$(test-string-list remove_duplicates a:b:c:c)" &&
	test a:b:c = "$(test-string-list remove_duplicates a:a:b:b:c:c)" &&
	test a:b:c = "$(test-string-list remove_duplicates a:a:a:b:b:b:c:c:c)"
'

test_done
