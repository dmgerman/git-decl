#!/usr/bin/perl -w
#
# Copyright (c) 2005 Junio C Hamano
#
# Read .git/FETCH_HEAD and make a human readable merge message
# by grouping branches and tags together to form a single line.

use strict;

my @src;
my %src;
sub andjoin {
	my ($label, $labels, $stuff) = @_;
	my $l = scalar @$stuff;
	my $m = '';
	if ($l == 0) {
		return ();
	}
	if ($l == 1) {
		$m = "$label$stuff->[0]";
	}
	else {
		$m = ("$labels" .
		      join (', ', @{$stuff}[0..$l-2]) .
		      " and $stuff->[-1]");
	}
	return ($m);
}

sub repoconfig {
	my $fh;
	my $val;
	eval {
		open $fh, '-|', 'git-repo-config', '--get', 'merge.summary'
		    or die "$!";
		($val) = <$fh>;
		close $fh;
	};
	return $val;
}

sub current_branch {
	my $fh;
	open $fh, '-|', 'git-symbolic-ref', 'HEAD' or die "$!";
	my ($bra) = <$fh>;
	chomp($bra);
	$bra =~ s|^refs/heads/||;
	if ($bra ne 'master') {
		$bra = " into $bra";
	} else {
		$bra = "";
	}

	return $bra;
}

sub shortlog {
	my ($tip, $limit) = @_;
	my ($fh, @result);
	open $fh, '-|', ('git-log', "--max-count=$limit", '--topo-order',
			 '--pretty=oneline', $tip, '^HEAD')
	    or die "$!";
	while (<$fh>) {
		s/^[0-9a-f]{40}\s+//;
		push @result, $_;
	}
	close $fh or die "$!";
	return @result;
}

my @origin = ();
while (<>) {
	my ($bname, $tname, $gname, $src, $sha1, $origin);
	chomp;
	s/^([0-9a-f]*)	//;
	$sha1 = $1;
	next if (/^not-for-merge/);
	s/^	//;
	if (s/ of (.*)$//) {
		$src = $1;
	} else {
		# Pulling HEAD
		$src = $_;
		$_ = 'HEAD';
	}
	if (! exists $src{$src}) {
		push @src, $src;
		$src{$src} = {
			BRANCH => [],
			TAG => [],
			GENERIC => [],
			# &1 == has HEAD.
			# &2 == has others.
			HEAD_STATUS => 0,
		};
	}
	if (/^branch (.*)$/) {
		$origin = $1;
		push @{$src{$src}{BRANCH}}, $1;
		$src{$src}{HEAD_STATUS} |= 2;
	}
	elsif (/^tag (.*)$/) {
		$origin = $_;
		push @{$src{$src}{TAG}}, $1;
		$src{$src}{HEAD_STATUS} |= 2;
	}
	elsif (/^HEAD$/) {
		$origin = $src;
		$src{$src}{HEAD_STATUS} |= 1;
	}
	else {
		push @{$src{$src}{GENERIC}}, $_;
		$src{$src}{HEAD_STATUS} |= 2;
		$origin = $src;
	}
	if ($src eq '.' || $src eq $origin) {
		$origin =~ s/^'(.*)'$/$1/;
		push @origin, [$sha1, "$origin"];
	}
	else {
		push @origin, [$sha1, "$origin of $src"];
	}
}

my @msg;
for my $src (@src) {
	if ($src{$src}{HEAD_STATUS} == 1) {
		# Only HEAD is fetched, nothing else.
		push @msg, $src;
		next;
	}
	my @this;
	if ($src{$src}{HEAD_STATUS} == 3) {
		# HEAD is fetched among others.
		push @this, andjoin('', '', ['HEAD']);
	}
	push @this, andjoin("branch ", "branches ",
			   $src{$src}{BRANCH});
	push @this, andjoin("tag ", "tags ",
			   $src{$src}{TAG});
	push @this, andjoin("commit ", "commits ",
			    $src{$src}{GENERIC});
	my $this = join(', ', @this);
	if ($src ne '.') {
		$this .= " of $src";
	}
	push @msg, $this;
}

my $into = current_branch();

print "Merge ", join("; ", @msg), $into, "\n";

if (!repoconfig) {
	exit(0);
}

# We limit the merge message to the latst 20 or so per each branch.
my $limit = 20;

for (@origin) {
	my ($sha1, $name) = @$_;
	my @log = shortlog($sha1, $limit + 1);
	if ($limit + 1 <= @log) {
		print "\n* $name: (" . scalar(@log) . " commits)\n";
	}
	else {
		print "\n* $name:\n";
	}
	my $cnt = 0;
	for my $log (@log) {
		if ($limit < ++$cnt) {
			print "  ...\n";
			last;
		}
		print "  $log";
	}
}
