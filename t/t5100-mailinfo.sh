#!/bin/sh
#
# Copyright (c) 2005 Junio C Hamano
#

test_description='git mailinfo and git mailsplit test'

. ./test-lib.sh

test_expect_success 'split sample box' \
	'git mailsplit -o. ../t5100/sample.mbox >last &&
	last=`cat last` &&
	echo total is $last &&
	test `cat last` = 9'

for mail in `echo 00*`
do
	test_expect_success "mailinfo $mail" \
		"git mailinfo -u msg$mail patch$mail <$mail >info$mail &&
		echo msg &&
		diff ../t5100/msg$mail msg$mail &&
		echo patch &&
		diff ../t5100/patch$mail patch$mail &&
		echo info &&
		diff ../t5100/info$mail info$mail"
done

test_expect_success 'respect NULs' '

	git mailsplit -d3 -o. ../t5100/nul &&
	cmp ../t5100/nul 001 &&
	(cat 001 | git mailinfo msg patch) &&
	test 4 = $(wc -l < patch)

'

test_expect_success 'Preserve NULs out of MIME encoded message' '

	git mailsplit -d5 -o. ../t5100/nul-b64.in &&
	cmp ../t5100/nul-b64.in 00001 &&
	git mailinfo msg patch <00001 &&
	cmp ../t5100/nul-b64.expect patch

'

test_done
