#!/bin/sh
#
# Copyright (c) 2005 Jon Seymour
#
test_description='Tests git-rev-list --bisect functionality'

. ./test-lib.sh
. ../t6000lib.sh # t6xxx specific functions

bc_expr()
{
bc <<EOF
scale=1
define abs(x) {
	if (x>=0) { return (x); } else { return (-x); }
}
define floor(x) {
	save=scale; scale=0; result=x/1; scale=save; return (result);
}
$*
EOF
}

# usage: test_bisection max-diff bisect-option head ^prune...
#
# e.g. test_bisection 1 --bisect l1 ^l0
#
test_bisection_diff()
{
	_max_diff=$1
	_bisect_option=$2
	shift 2
	_bisection=$(git-rev-list $_bisect_option "$@")
	_list_size=$(git-rev-list "$@" | wc -l)
        _head=$1
	shift 1
	_bisection_size=$(git-rev-list $_bisection "$@" | wc -l)
	[ -n "$_list_size" -a -n "$_bisection_size" ] || error "test_bisection_diff failed"
	test_expect_success "bisection diff $_bisect_option $_head $* <= $_max_diff" "[ $(bc_expr "floor(abs($_list_size/2)-$_bisection_size)") -le $_max_diff ]"
}

date >path0
git-update-cache --add path0
save_tag tree git-write-tree
on_committer_date "1971-08-16 00:00:00" hide_error save_tag root unique_commit root tree
on_committer_date "1971-08-16 00:00:01" save_tag l0 unique_commit l0 tree -p root
on_committer_date "1971-08-16 00:00:02" save_tag l1 unique_commit l1 tree -p l0
on_committer_date "1971-08-16 00:00:03" save_tag l2 unique_commit l2 tree -p l1
on_committer_date "1971-08-16 00:00:04" save_tag a0 unique_commit a0 tree -p l2
on_committer_date "1971-08-16 00:00:05" save_tag a1 unique_commit a1 tree -p a0
on_committer_date "1971-08-16 00:00:06" save_tag b1 unique_commit b1 tree -p a0
on_committer_date "1971-08-16 00:00:07" save_tag c1 unique_commit c1 tree -p b1
on_committer_date "1971-08-16 00:00:08" save_tag b2 unique_commit b2 tree -p b1
on_committer_date "1971-08-16 00:00:09" save_tag b3 unique_commit b2 tree -p b2
on_committer_date "1971-08-16 00:00:10" save_tag c2 unique_commit c2 tree -p c1 -p b2
on_committer_date "1971-08-16 00:00:11" save_tag c3 unique_commit c3 tree -p c2
on_committer_date "1971-08-16 00:00:12" save_tag a2 unique_commit a2 tree -p a1
on_committer_date "1971-08-16 00:00:13" save_tag a3 unique_commit a3 tree -p a2
on_committer_date "1971-08-16 00:00:14" save_tag b4 unique_commit b4 tree -p b3 -p a3
on_committer_date "1971-08-16 00:00:15" save_tag a4 unique_commit a4 tree -p a3 -p b4 -p c3
on_committer_date "1971-08-16 00:00:16" save_tag l3 unique_commit l3 tree -p a4
on_committer_date "1971-08-16 00:00:17" save_tag l4 unique_commit l4 tree -p l3
on_committer_date "1971-08-16 00:00:18" save_tag l5 unique_commit l5 tree -p l4
tag l5 > .git/HEAD


#     E
#    / \
#   e1  |
#   |   |
#   e2  |
#   |   |
#   e3  |
#   |   |
#   e4  |
#   |   |
#   |   f1
#   |   |
#   |   f2
#   |   |
#   |   f3
#   |   |
#   |   f4
#   |   |
#   e5  |
#   |   |
#   e6  |
#   |   |
#   e7  |
#   |   |
#   e8  |
#    \ /
#     F


on_committer_date "1971-08-16 00:00:00" hide_error save_tag F unique_commit F tree
on_committer_date "1971-08-16 00:00:01" save_tag e8 unique_commit e8 tree -p F
on_committer_date "1971-08-16 00:00:02" save_tag e7 unique_commit e7 tree -p e8
on_committer_date "1971-08-16 00:00:03" save_tag e6 unique_commit e6 tree -p e7
on_committer_date "1971-08-16 00:00:04" save_tag e5 unique_commit e5 tree -p e6
on_committer_date "1971-08-16 00:00:05" save_tag f4 unique_commit f4 tree -p F
on_committer_date "1971-08-16 00:00:06" save_tag f3 unique_commit f3 tree -p f4
on_committer_date "1971-08-16 00:00:07" save_tag f2 unique_commit f2 tree -p f3
on_committer_date "1971-08-16 00:00:08" save_tag f1 unique_commit f1 tree -p f2
on_committer_date "1971-08-16 00:00:09" save_tag e4 unique_commit e4 tree -p e5
on_committer_date "1971-08-16 00:00:10" save_tag e3 unique_commit e3 tree -p e4
on_committer_date "1971-08-16 00:00:11" save_tag e2 unique_commit e2 tree -p e3
on_committer_date "1971-08-16 00:00:12" save_tag e1 unique_commit e1 tree -p e2
on_committer_date "1971-08-16 00:00:13" save_tag E unique_commit E tree -p e1 -p f1

on_committer_date "1971-08-16 00:00:00" hide_error save_tag U unique_commit U tree
on_committer_date "1971-08-16 00:00:01" save_tag u0 unique_commit u0 tree -p U
on_committer_date "1971-08-16 00:00:01" save_tag u1 unique_commit u1 tree -p u0
on_committer_date "1971-08-16 00:00:02" save_tag u2 unique_commit u2 tree -p u0
on_committer_date "1971-08-16 00:00:03" save_tag u3 unique_commit u3 tree -p u0
on_committer_date "1971-08-16 00:00:04" save_tag u4 unique_commit u4 tree -p u0
on_committer_date "1971-08-16 00:00:05" save_tag u5 unique_commit u5 tree -p u0
on_committer_date "1971-08-16 00:00:06" save_tag V unique_commit V tree -p u1 -p u2 -p u3 -p u4 -p u5

test_sequence()
{
	_bisect_option=$1	
	
	test_bisection_diff 0 $_bisect_option l0 ^root
	test_bisection_diff 0 $_bisect_option l1 ^root
	test_bisection_diff 0 $_bisect_option l2 ^root
	test_bisection_diff 0 $_bisect_option a0 ^root
	test_bisection_diff 0 $_bisect_option a1 ^root
	test_bisection_diff 0 $_bisect_option a2 ^root
	test_bisection_diff 0 $_bisect_option a3 ^root
	test_bisection_diff 0 $_bisect_option b1 ^root
	test_bisection_diff 0 $_bisect_option b2 ^root
	test_bisection_diff 0 $_bisect_option b3 ^root
	test_bisection_diff 0 $_bisect_option c1 ^root
	test_bisection_diff 0 $_bisect_option c2 ^root
	test_bisection_diff 0 $_bisect_option c3 ^root
	test_bisection_diff 0 $_bisect_option E ^F
	test_bisection_diff 0 $_bisect_option e1 ^F
	test_bisection_diff 0 $_bisect_option e2 ^F
	test_bisection_diff 0 $_bisect_option e3 ^F
	test_bisection_diff 0 $_bisect_option e4 ^F
	test_bisection_diff 0 $_bisect_option e5 ^F
	test_bisection_diff 0 $_bisect_option e6 ^F
	test_bisection_diff 0 $_bisect_option e7 ^F
	test_bisection_diff 0 $_bisect_option f1 ^F
	test_bisection_diff 0 $_bisect_option f2 ^F
	test_bisection_diff 0 $_bisect_option f3 ^F
	test_bisection_diff 0 $_bisect_option f4 ^F
	test_bisection_diff 0 $_bisect_option E ^F

	test_bisection_diff 1 $_bisect_option V ^U
	test_bisection_diff 0 $_bisect_option V ^U ^u1 ^u2 ^u3
	test_bisection_diff 0 $_bisect_option u1 ^U
	test_bisection_diff 0 $_bisect_option u2 ^U
	test_bisection_diff 0 $_bisect_option u3 ^U
	test_bisection_diff 0 $_bisect_option u4 ^U
	test_bisection_diff 0 $_bisect_option u5 ^U
	
#
# the following illustrate's Linus' binary bug blatt idea. 
#
# assume the bug is actually at l3, but you don't know that - all you know is that l3 is broken
# and it wasn't broken before
#
# keep bisecting the list, advancing the "bad" head and accumulating "good" heads until
# the bisection point is the head - this is the bad point.
#

test_output_expect_success "--bisect l5 ^root" 'git-rev-list $_bisect_option l5 ^root' <<EOF
c3
EOF

test_output_expect_success "$_bisect_option l5 ^root ^c3" 'git-rev-list $_bisect_option l5 ^root ^c3' <<EOF
b4
EOF

test_output_expect_success "$_bisect_option l5 ^root ^c3 ^b4" 'git-rev-list $_bisect_option l5 ^c3 ^b4' <<EOF
l3
EOF

test_output_expect_success "$_bisect_option l3 ^root ^c3 ^b4" 'git-rev-list $_bisect_option l3 ^root ^c3 ^b4' <<EOF
a4
EOF

test_output_expect_success "$_bisect_option l5 ^b3 ^a3 ^b4 ^a4" 'git-rev-list $_bisect_option l3 ^b3 ^a3 ^a4' <<EOF
l3
EOF

#
# if l3 is bad, then l4 is bad too - so advance the bad pointer by making b4 the known bad head
#

test_output_expect_success "$_bisect_option l4 ^a2 ^a3 ^b ^a4" 'git-rev-list $_bisect_option l4 ^a2 ^a3 ^a4' <<EOF
l3
EOF

test_output_expect_success "$_bisect_option l3 ^a2 ^a3 ^b ^a4" 'git-rev-list $_bisect_option l3 ^a2 ^a3 ^a4' <<EOF
l3
EOF

# found!

#
# as another example, let's consider a4 to be the bad head, in which case
#

test_output_expect_success "$_bisect_option a4 ^a2 ^a3 ^b4" 'git-rev-list $_bisect_option a4 ^a2 ^a3 ^b4' <<EOF
c2
EOF

test_output_expect_success "$_bisect_option a4 ^a2 ^a3 ^b4 ^c2" 'git-rev-list $_bisect_option a4 ^a2 ^a3 ^b4 ^c2' <<EOF
c3
EOF

test_output_expect_success "$_bisect_option a4 ^a2 ^a3 ^b4 ^c2 ^c3" 'git-rev-list $_bisect_option a4 ^a2 ^a3 ^b4 ^c2 ^c3' <<EOF
a4
EOF

# found!

#
# or consider c3 to be the bad head
#

test_output_expect_success "$_bisect_option a4 ^a2 ^a3 ^b4" 'git-rev-list $_bisect_option a4 ^a2 ^a3 ^b4' <<EOF
c2
EOF

test_output_expect_success "$_bisect_option c3 ^a2 ^a3 ^b4 ^c2" 'git-rev-list $_bisect_option c3 ^a2 ^a3 ^b4 ^c2' <<EOF
c3
EOF

# found!

}

test_sequence "--bisect"

#
#
test_done
