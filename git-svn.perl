#!/usr/bin/perl
# Copyright (C) 2006, Eric Wong <normalperson@yhbt.net>
# License: GPL v2 or later
use 5.008;
use warnings;
use strict;
use vars qw/	$AUTHOR $VERSION
		$sha1 $sha1_short $_revision $_repository
		$_q $_authors $_authors_prog %users/;
$AUTHOR = 'Eric Wong <normalperson@yhbt.net>';
$VERSION = '@@GIT_VERSION@@';

use Git::SVN;
use Git::SVN::Utils qw(fatal can_compress);

# From which subdir have we been invoked?
my $cmd_dir_prefix = eval {
	command_oneline([qw/rev-parse --show-prefix/], STDERR => 0)
} || '';

my $git_dir_user_set = 1 if defined $ENV{GIT_DIR};
$ENV{GIT_DIR} ||= '.git';
$Git::SVN::default_repo_id = 'svn';
$Git::SVN::default_ref_id = $ENV{GIT_SVN_ID} || 'git-svn';
$Git::SVN::Ra::_log_window_size = 100;
$Git::SVN::_minimize_url = 'unset';

if (! exists $ENV{SVN_SSH} && exists $ENV{GIT_SSH}) {
	$ENV{SVN_SSH} = $ENV{GIT_SSH};
}

if (exists $ENV{SVN_SSH} && $^O eq 'msys') {
	$ENV{SVN_SSH} =~ s/\\/\\\\/g;
	$ENV{SVN_SSH} =~ s/(.*)/"$1"/;
}

$Git::SVN::Log::TZ = $ENV{TZ};
$ENV{TZ} = 'UTC';
$| = 1; # unbuffer STDOUT

# All SVN commands do it.  Otherwise we may die on SIGPIPE when the remote
# repository decides to close the connection which we expect to be kept alive.
$SIG{PIPE} = 'IGNORE';

# Given a dot separated version number, "subtract" it from
# the SVN::Core::VERSION; non-negaitive return means the SVN::Core
# is at least at the version the caller asked for.
sub compare_svn_version {
	my (@ours) = split(/\./, $SVN::Core::VERSION);
	my (@theirs) = split(/\./, $_[0]);
	my ($i, $diff);

	for ($i = 0; $i < @ours && $i < @theirs; $i++) {
		$diff = $ours[$i] - $theirs[$i];
		return $diff if ($diff);
	}
	return 1 if ($i < @ours);
	return -1 if ($i < @theirs);
	return 0;
}

sub _req_svn {
	require SVN::Core; # use()-ing this causes segfaults for me... *shrug*
	require SVN::Ra;
	require SVN::Delta;
	if (::compare_svn_version('1.1.0') < 0) {
		fatal "Need SVN::Core 1.1.0 or better (got $SVN::Core::VERSION)";
	}
}

use Carp qw/croak/;
use Digest::MD5;
use IO::File qw//;
use File::Basename qw/dirname basename/;
use File::Path qw/mkpath/;
use File::Spec;
use File::Find;
use Getopt::Long qw/:config gnu_getopt no_ignore_case auto_abbrev/;
use IPC::Open3;
use Git;
use Git::SVN::Editor qw//;
use Git::SVN::Fetcher qw//;
use Git::SVN::Ra qw//;
use Git::SVN::Prompt qw//;
use Memoize;  # core since 5.8.0, Jul 2002

BEGIN {
	# import functions from Git into our packages, en masse
	no strict 'refs';
	foreach (qw/command command_oneline command_noisy command_output_pipe
	            command_input_pipe command_close_pipe
	            command_bidi_pipe command_close_bidi_pipe/) {
		for my $package ( qw(Git::SVN::Migration Git::SVN::Log),
			__PACKAGE__) {
			*{"${package}::$_"} = \&{"Git::$_"};
		}
	}
	Memoize::memoize 'Git::config';
	Memoize::memoize 'Git::config_bool';
}

my ($SVN);

$sha1 = qr/[a-f\d]{40}/;
$sha1_short = qr/[a-f\d]{4,40}/;
my ($_stdin, $_help, $_edit,
	$_message, $_file, $_branch_dest,
	$_template, $_shared,
	$_version, $_fetch_all, $_no_rebase, $_fetch_parent,
	$_merge, $_strategy, $_preserve_merges, $_dry_run, $_local,
	$_prefix, $_no_checkout, $_url, $_verbose,
	$_git_format, $_commit_url, $_tag, $_merge_info, $_interactive);

# This is a refactoring artifact so Git::SVN can get at this git-svn switch.
sub opt_prefix { return $_prefix || '' }

$Git::SVN::_follow_parent = 1;
$Git::SVN::Fetcher::_placeholder_filename = ".gitignore";
$_q ||= 0;
my %remote_opts = ( 'username=s' => \$Git::SVN::Prompt::_username,
                    'config-dir=s' => \$Git::SVN::Ra::config_dir,
                    'no-auth-cache' => \$Git::SVN::Prompt::_no_auth_cache,
                    'ignore-paths=s' => \$Git::SVN::Fetcher::_ignore_regex,
                    'ignore-refs=s' => \$Git::SVN::Ra::_ignore_refs_regex );
my %fc_opts = ( 'follow-parent|follow!' => \$Git::SVN::_follow_parent,
		'authors-file|A=s' => \$_authors,
		'authors-prog=s' => \$_authors_prog,
		'repack:i' => \$Git::SVN::_repack,
		'noMetadata' => \$Git::SVN::_no_metadata,
		'useSvmProps' => \$Git::SVN::_use_svm_props,
		'useSvnsyncProps' => \$Git::SVN::_use_svnsync_props,
		'log-window-size=i' => \$Git::SVN::Ra::_log_window_size,
		'no-checkout' => \$_no_checkout,
		'quiet|q+' => \$_q,
		'repack-flags|repack-args|repack-opts=s' =>
		   \$Git::SVN::_repack_flags,
		'use-log-author' => \$Git::SVN::_use_log_author,
		'add-author-from' => \$Git::SVN::_add_author_from,
		'localtime' => \$Git::SVN::_localtime,
		%remote_opts );

my ($_trunk, @_tags, @_branches, $_stdlayout);
my %icv;
my %init_opts = ( 'template=s' => \$_template, 'shared:s' => \$_shared,
                  'trunk|T=s' => \$_trunk, 'tags|t=s@' => \@_tags,
                  'branches|b=s@' => \@_branches, 'prefix=s' => \$_prefix,
                  'stdlayout|s' => \$_stdlayout,
                  'minimize-url|m!' => \$Git::SVN::_minimize_url,
		  'no-metadata' => sub { $icv{noMetadata} = 1 },
		  'use-svm-props' => sub { $icv{useSvmProps} = 1 },
		  'use-svnsync-props' => sub { $icv{useSvnsyncProps} = 1 },
		  'rewrite-root=s' => sub { $icv{rewriteRoot} = $_[1] },
		  'rewrite-uuid=s' => sub { $icv{rewriteUUID} = $_[1] },
                  %remote_opts );
my %cmt_opts = ( 'edit|e' => \$_edit,
		'rmdir' => \$Git::SVN::Editor::_rmdir,
		'find-copies-harder' => \$Git::SVN::Editor::_find_copies_harder,
		'l=i' => \$Git::SVN::Editor::_rename_limit,
		'copy-similarity|C=i'=> \$Git::SVN::Editor::_cp_similarity
);

my %cmd = (
	fetch => [ \&cmd_fetch, "Download new revisions from SVN",
			{ 'revision|r=s' => \$_revision,
			  'fetch-all|all' => \$_fetch_all,
			  'parent|p' => \$_fetch_parent,
			   %fc_opts } ],
	clone => [ \&cmd_clone, "Initialize and fetch revisions",
			{ 'revision|r=s' => \$_revision,
			  'preserve-empty-dirs' =>
				\$Git::SVN::Fetcher::_preserve_empty_dirs,
			  'placeholder-filename=s' =>
				\$Git::SVN::Fetcher::_placeholder_filename,
			   %fc_opts, %init_opts } ],
	init => [ \&cmd_init, "Initialize a repo for tracking" .
			  " (requires URL argument)",
			  \%init_opts ],
	'multi-init' => [ \&cmd_multi_init,
	                  "Deprecated alias for ".
			  "'$0 init -T<trunk> -b<branches> -t<tags>'",
			  \%init_opts ],
	dcommit => [ \&cmd_dcommit,
	             'Commit several diffs to merge with upstream',
			{ 'merge|m|M' => \$_merge,
			  'strategy|s=s' => \$_strategy,
			  'verbose|v' => \$_verbose,
			  'dry-run|n' => \$_dry_run,
			  'fetch-all|all' => \$_fetch_all,
			  'commit-url=s' => \$_commit_url,
			  'revision|r=i' => \$_revision,
			  'no-rebase' => \$_no_rebase,
			  'mergeinfo=s' => \$_merge_info,
			  'interactive|i' => \$_interactive,
			%cmt_opts, %fc_opts } ],
	branch => [ \&cmd_branch,
	            'Create a branch in the SVN repository',
	            { 'message|m=s' => \$_message,
	              'destination|d=s' => \$_branch_dest,
	              'dry-run|n' => \$_dry_run,
	              'tag|t' => \$_tag,
	              'username=s' => \$Git::SVN::Prompt::_username,
	              'commit-url=s' => \$_commit_url } ],
	tag => [ sub { $_tag = 1; cmd_branch(@_) },
	         'Create a tag in the SVN repository',
	         { 'message|m=s' => \$_message,
	           'destination|d=s' => \$_branch_dest,
	           'dry-run|n' => \$_dry_run,
	           'username=s' => \$Git::SVN::Prompt::_username,
	           'commit-url=s' => \$_commit_url } ],
	'set-tree' => [ \&cmd_set_tree,
	                "Set an SVN repository to a git tree-ish",
			{ 'stdin' => \$_stdin, %cmt_opts, %fc_opts, } ],
	'create-ignore' => [ \&cmd_create_ignore,
			     'Create a .gitignore per svn:ignore',
			     { 'revision|r=i' => \$_revision
			     } ],
	'mkdirs' => [ \&cmd_mkdirs ,
	              "recreate empty directories after a checkout",
	              { 'revision|r=i' => \$_revision } ],
        'propget' => [ \&cmd_propget,
		       'Print the value of a property on a file or directory',
		       { 'revision|r=i' => \$_revision } ],
        'proplist' => [ \&cmd_proplist,
		       'List all properties of a file or directory',
		       { 'revision|r=i' => \$_revision } ],
	'show-ignore' => [ \&cmd_show_ignore, "Show svn:ignore listings",
			{ 'revision|r=i' => \$_revision
			} ],
	'show-externals' => [ \&cmd_show_externals, "Show svn:externals listings",
			{ 'revision|r=i' => \$_revision
			} ],
	'multi-fetch' => [ \&cmd_multi_fetch,
	                   "Deprecated alias for $0 fetch --all",
			   { 'revision|r=s' => \$_revision, %fc_opts } ],
	'migrate' => [ sub { },
	               # no-op, we automatically run this anyways,
	               'Migrate configuration/metadata/layout from
		        previous versions of git-svn',
                       { 'minimize' => \$Git::SVN::Migration::_minimize,
			 %remote_opts } ],
	'log' => [ \&Git::SVN::Log::cmd_show_log, 'Show commit logs',
			{ 'limit=i' => \$Git::SVN::Log::limit,
			  'revision|r=s' => \$_revision,
			  'verbose|v' => \$Git::SVN::Log::verbose,
			  'incremental' => \$Git::SVN::Log::incremental,
			  'oneline' => \$Git::SVN::Log::oneline,
			  'show-commit' => \$Git::SVN::Log::show_commit,
			  'non-recursive' => \$Git::SVN::Log::non_recursive,
			  'authors-file|A=s' => \$_authors,
			  'color' => \$Git::SVN::Log::color,
			  'pager=s' => \$Git::SVN::Log::pager
			} ],
	'find-rev' => [ \&cmd_find_rev,
	                "Translate between SVN revision numbers and tree-ish",
			{} ],
	'rebase' => [ \&cmd_rebase, "Fetch and rebase your working directory",
			{ 'merge|m|M' => \$_merge,
			  'verbose|v' => \$_verbose,
			  'strategy|s=s' => \$_strategy,
			  'local|l' => \$_local,
			  'fetch-all|all' => \$_fetch_all,
			  'dry-run|n' => \$_dry_run,
			  'preserve-merges|p' => \$_preserve_merges,
			  %fc_opts } ],
	'commit-diff' => [ \&cmd_commit_diff,
	                   'Commit a diff between two trees',
			{ 'message|m=s' => \$_message,
			  'file|F=s' => \$_file,
			  'revision|r=s' => \$_revision,
			%cmt_opts } ],
	'info' => [ \&cmd_info,
		    "Show info about the latest SVN revision
		     on the current branch",
		    { 'url' => \$_url, } ],
	'blame' => [ \&Git::SVN::Log::cmd_blame,
	            "Show what revision and author last modified each line of a file",
		    { 'git-format' => \$_git_format } ],
	'reset' => [ \&cmd_reset,
		     "Undo fetches back to the specified SVN revision",
		     { 'revision|r=s' => \$_revision,
		       'parent|p' => \$_fetch_parent } ],
	'gc' => [ \&cmd_gc,
		  "Compress unhandled.log files in .git/svn and remove " .
		  "index files in .git/svn",
		{} ],
);

use Term::ReadLine;
package FakeTerm;
sub new {
	my ($class, $reason) = @_;
	return bless \$reason, shift;
}
sub readline {
	my $self = shift;
	die "Cannot use readline on FakeTerm: $$self";
}
package main;

my $term = eval {
	$ENV{"GIT_SVN_NOTTY"}
		? new Term::ReadLine 'git-svn', \*STDIN, \*STDOUT
		: new Term::ReadLine 'git-svn';
};
if ($@) {
	$term = new FakeTerm "$@: going non-interactive";
}

my $cmd;
for (my $i = 0; $i < @ARGV; $i++) {
	if (defined $cmd{$ARGV[$i]}) {
		$cmd = $ARGV[$i];
		splice @ARGV, $i, 1;
		last;
	} elsif ($ARGV[$i] eq 'help') {
		$cmd = $ARGV[$i+1];
		usage(0);
	}
};

# make sure we're always running at the top-level working directory
unless ($cmd && $cmd =~ /(?:clone|init|multi-init)$/) {
	unless (-d $ENV{GIT_DIR}) {
		if ($git_dir_user_set) {
			die "GIT_DIR=$ENV{GIT_DIR} explicitly set, ",
			    "but it is not a directory\n";
		}
		my $git_dir = delete $ENV{GIT_DIR};
		my $cdup = undef;
		git_cmd_try {
			$cdup = command_oneline(qw/rev-parse --show-cdup/);
			$git_dir = '.' unless ($cdup);
			chomp $cdup if ($cdup);
			$cdup = "." unless ($cdup && length $cdup);
		} "Already at toplevel, but $git_dir not found\n";
		chdir $cdup or die "Unable to chdir up to '$cdup'\n";
		unless (-d $git_dir) {
			die "$git_dir still not found after going to ",
			    "'$cdup'\n";
		}
		$ENV{GIT_DIR} = $git_dir;
	}
	$_repository = Git->repository(Repository => $ENV{GIT_DIR});
}

my %opts = %{$cmd{$cmd}->[2]} if (defined $cmd);

read_git_config(\%opts);
if ($cmd && ($cmd eq 'log' || $cmd eq 'blame')) {
	Getopt::Long::Configure('pass_through');
}
my $rv = GetOptions(%opts, 'h|H' => \$_help, 'version|V' => \$_version,
                    'minimize-connections' => \$Git::SVN::Migration::_minimize,
                    'id|i=s' => \$Git::SVN::default_ref_id,
                    'svn-remote|remote|R=s' => sub {
                       $Git::SVN::no_reuse_existing = 1;
                       $Git::SVN::default_repo_id = $_[1] });
exit 1 if (!$rv && $cmd && $cmd ne 'log');

usage(0) if $_help;
version() if $_version;
usage(1) unless defined $cmd;
load_authors() if $_authors;
if (defined $_authors_prog) {
	$_authors_prog = "'" . File::Spec->rel2abs($_authors_prog) . "'";
}

unless ($cmd =~ /^(?:clone|init|multi-init|commit-diff)$/) {
	Git::SVN::Migration::migration_check();
}
Git::SVN::init_vars();
eval {
	Git::SVN::verify_remotes_sanity();
	$cmd{$cmd}->[0]->(@ARGV);
	post_fetch_checkout();
};
fatal $@ if $@;
exit 0;

####################### primary functions ######################
sub usage {
	my $exit = shift || 0;
	my $fd = $exit ? \*STDERR : \*STDOUT;
	print $fd <<"";
git-svn - bidirectional operations between a single Subversion tree and git
Usage: git svn <command> [options] [arguments]\n

	print $fd "Available commands:\n" unless $cmd;

	foreach (sort keys %cmd) {
		next if $cmd && $cmd ne $_;
		next if /^multi-/; # don't show deprecated commands
		print $fd '  ',pack('A17',$_),$cmd{$_}->[1],"\n";
		foreach (sort keys %{$cmd{$_}->[2]}) {
			# mixed-case options are for .git/config only
			next if /[A-Z]/ && /^[a-z]+$/i;
			# prints out arguments as they should be passed:
			my $x = s#[:=]s$## ? '<arg>' : s#[:=]i$## ? '<num>' : '';
			print $fd ' ' x 21, join(', ', map { length $_ > 1 ?
							"--$_" : "-$_" }
						split /\|/,$_)," $x\n";
		}
	}
	print $fd <<"";
\nGIT_SVN_ID may be set in the environment or via the --id/-i switch to an
arbitrary identifier if you're tracking multiple SVN branches/repositories in
one git repository and want to keep them separate.  See git-svn(1) for more
information.

	exit $exit;
}

sub version {
	::_req_svn();
	print "git-svn version $VERSION (svn $SVN::Core::VERSION)\n";
	exit 0;
}

sub ask {
	my ($prompt, %arg) = @_;
	my $valid_re = $arg{valid_re};
	my $default = $arg{default};
	my $resp;
	my $i = 0;

	if ( !( defined($term->IN)
            && defined( fileno($term->IN) )
            && defined( $term->OUT )
            && defined( fileno($term->OUT) ) ) ){
		return defined($default) ? $default : undef;
	}

	while ($i++ < 10) {
		$resp = $term->readline($prompt);
		if (!defined $resp) { # EOF
			print "\n";
			return defined $default ? $default : undef;
		}
		if ($resp eq '' and defined $default) {
			return $default;
		}
		if (!defined $valid_re or $resp =~ /$valid_re/) {
			return $resp;
		}
	}
	return undef;
}

sub do_git_init_db {
	unless (-d $ENV{GIT_DIR}) {
		my @init_db = ('init');
		push @init_db, "--template=$_template" if defined $_template;
		if (defined $_shared) {
			if ($_shared =~ /[a-z]/) {
				push @init_db, "--shared=$_shared";
			} else {
				push @init_db, "--shared";
			}
		}
		command_noisy(@init_db);
		$_repository = Git->repository(Repository => ".git");
	}
	my $set;
	my $pfx = "svn-remote.$Git::SVN::default_repo_id";
	foreach my $i (keys %icv) {
		die "'$set' and '$i' cannot both be set\n" if $set;
		next unless defined $icv{$i};
		command_noisy('config', "$pfx.$i", $icv{$i});
		$set = $i;
	}
	my $ignore_paths_regex = \$Git::SVN::Fetcher::_ignore_regex;
	command_noisy('config', "$pfx.ignore-paths", $$ignore_paths_regex)
		if defined $$ignore_paths_regex;
	my $ignore_refs_regex = \$Git::SVN::Ra::_ignore_refs_regex;
	command_noisy('config', "$pfx.ignore-refs", $$ignore_refs_regex)
		if defined $$ignore_refs_regex;

	if (defined $Git::SVN::Fetcher::_preserve_empty_dirs) {
		my $fname = \$Git::SVN::Fetcher::_placeholder_filename;
		command_noisy('config', "$pfx.preserve-empty-dirs", 'true');
		command_noisy('config', "$pfx.placeholder-filename", $$fname);
	}
}

sub init_subdir {
	my $repo_path = shift or return;
	mkpath([$repo_path]) unless -d $repo_path;
	chdir $repo_path or die "Couldn't chdir to $repo_path: $!\n";
	$ENV{GIT_DIR} = '.git';
	$_repository = Git->repository(Repository => $ENV{GIT_DIR});
}

sub cmd_clone {
	my ($url, $path) = @_;
	if (!defined $path &&
	    (defined $_trunk || @_branches || @_tags ||
	     defined $_stdlayout) &&
	    $url !~ m#^[a-z\+]+://#) {
		$path = $url;
	}
	$path = basename($url) if !defined $path || !length $path;
	my $authors_absolute = $_authors ? File::Spec->rel2abs($_authors) : "";
	cmd_init($url, $path);
	command_oneline('config', 'svn.authorsfile', $authors_absolute)
	    if $_authors;
	Git::SVN::fetch_all($Git::SVN::default_repo_id);
}

sub cmd_init {
	if (defined $_stdlayout) {
		$_trunk = 'trunk' if (!defined $_trunk);
		@_tags = 'tags' if (! @_tags);
		@_branches = 'branches' if (! @_branches);
	}
	if (defined $_trunk || @_branches || @_tags) {
		return cmd_multi_init(@_);
	}
	my $url = shift or die "SVN repository location required ",
	                       "as a command-line argument\n";
	$url = canonicalize_url($url);
	init_subdir(@_);
	do_git_init_db();

	if ($Git::SVN::_minimize_url eq 'unset') {
		$Git::SVN::_minimize_url = 0;
	}

	Git::SVN->init($url);
}

sub cmd_fetch {
	if (grep /^\d+=./, @_) {
		die "'<rev>=<commit>' fetch arguments are ",
		    "no longer supported.\n";
	}
	my ($remote) = @_;
	if (@_ > 1) {
		die "Usage: $0 fetch [--all] [--parent] [svn-remote]\n";
	}
	$Git::SVN::no_reuse_existing = undef;
	if ($_fetch_parent) {
		my ($url, $rev, $uuid, $gs) = working_head_info('HEAD');
		unless ($gs) {
			die "Unable to determine upstream SVN information from ",
			    "working tree history\n";
		}
	        # just fetch, don't checkout.
		$_no_checkout = 'true';
		$_fetch_all ? $gs->fetch_all : $gs->fetch;
	} elsif ($_fetch_all) {
		cmd_multi_fetch();
	} else {
		$remote ||= $Git::SVN::default_repo_id;
		Git::SVN::fetch_all($remote, Git::SVN::read_all_remotes());
	}
}

sub cmd_set_tree {
	my (@commits) = @_;
	if ($_stdin || !@commits) {
		print "Reading from stdin...\n";
		@commits = ();
		while (<STDIN>) {
			if (/\b($sha1_short)\b/o) {
				unshift @commits, $1;
			}
		}
	}
	my @revs;
	foreach my $c (@commits) {
		my @tmp = command('rev-parse',$c);
		if (scalar @tmp == 1) {
			push @revs, $tmp[0];
		} elsif (scalar @tmp > 1) {
			push @revs, reverse(command('rev-list',@tmp));
		} else {
			fatal "Failed to rev-parse $c";
		}
	}
	my $gs = Git::SVN->new;
	my ($r_last, $cmt_last) = $gs->last_rev_commit;
	$gs->fetch;
	if (defined $gs->{last_rev} && $r_last != $gs->{last_rev}) {
		fatal "There are new revisions that were fetched ",
		      "and need to be merged (or acknowledged) ",
		      "before committing.\nlast rev: $r_last\n",
		      " current: $gs->{last_rev}";
	}
	$gs->set_tree($_) foreach @revs;
	print "Done committing ",scalar @revs," revisions to SVN\n";
	unlink $gs->{index};
}

sub split_merge_info_range {
	my ($range) = @_;
	if ($range =~ /(\d+)-(\d+)/) {
		return (int($1), int($2));
	} else {
		return (int($range), int($range));
	}
}

sub combine_ranges {
	my ($in) = @_;

	my @fnums = ();
	my @arr = split(/,/, $in);
	for my $element (@arr) {
		my ($start, $end) = split_merge_info_range($element);
		push @fnums, $start;
	}

	my @sorted = @arr [ sort {
		$fnums[$a] <=> $fnums[$b]
	} 0..$#arr ];

	my @return = ();
	my $last = -1;
	my $first = -1;
	for my $element (@sorted) {
		my ($start, $end) = split_merge_info_range($element);

		if ($last == -1) {
			$first = $start;
			$last = $end;
			next;
		}
		if ($start <= $last+1) {
			if ($end > $last) {
				$last = $end;
			}
			next;
		}
		if ($first == $last) {
			push @return, "$first";
		} else {
			push @return, "$first-$last";
		}
		$first = $start;
		$last = $end;
	}

	if ($first != -1) {
		if ($first == $last) {
			push @return, "$first";
		} else {
			push @return, "$first-$last";
		}
	}

	return join(',', @return);
}

sub merge_revs_into_hash {
	my ($hash, $minfo) = @_;
	my @lines = split(' ', $minfo);

	for my $line (@lines) {
		my ($branchpath, $revs) = split(/:/, $line);

		if (exists($hash->{$branchpath})) {
			# Merge the two revision sets
			my $combined = "$hash->{$branchpath},$revs";
			$hash->{$branchpath} = combine_ranges($combined);
		} else {
			# Just do range combining for consolidation
			$hash->{$branchpath} = combine_ranges($revs);
		}
	}
}

sub merge_merge_info {
	my ($mergeinfo_one, $mergeinfo_two) = @_;
	my %result_hash = ();

	merge_revs_into_hash(\%result_hash, $mergeinfo_one);
	merge_revs_into_hash(\%result_hash, $mergeinfo_two);

	my $result = '';
	# Sort below is for consistency's sake
	for my $branchname (sort keys(%result_hash)) {
		my $revlist = $result_hash{$branchname};
		$result .= "$branchname:$revlist\n"
	}
	return $result;
}

sub populate_merge_info {
	my ($d, $gs, $uuid, $linear_refs, $rewritten_parent) = @_;

	my %parentshash;
	read_commit_parents(\%parentshash, $d);
	my @parents = @{$parentshash{$d}};
	if ($#parents > 0) {
		# Merge commit
		my $all_parents_ok = 1;
		my $aggregate_mergeinfo = '';
		my $rooturl = $gs->repos_root;

		if (defined($rewritten_parent)) {
			# Replace first parent with newly-rewritten version
			shift @parents;
			unshift @parents, $rewritten_parent;
		}

		foreach my $parent (@parents) {
			my ($branchurl, $svnrev, $paruuid) =
				cmt_metadata($parent);

			unless (defined($svnrev)) {
				# Should have been caught be preflight check
				fatal "merge commit $d has ancestor $parent, but that change "
                     ."does not have git-svn metadata!";
			}
			unless ($branchurl =~ /^\Q$rooturl\E(.*)/) {
				fatal "commit $parent git-svn metadata changed mid-run!";
			}
			my $branchpath = $1;

			my $ra = Git::SVN::Ra->new($branchurl);
			my (undef, undef, $props) =
				$ra->get_dir(canonicalize_path("."), $svnrev);
			my $par_mergeinfo = $props->{'svn:mergeinfo'};
			unless (defined $par_mergeinfo) {
				$par_mergeinfo = '';
			}
			# Merge previous mergeinfo values
			$aggregate_mergeinfo =
				merge_merge_info($aggregate_mergeinfo,
								 $par_mergeinfo, 0);

			next if $parent eq $parents[0]; # Skip first parent
			# Add new changes being placed in tree by merge
			my @cmd = (qw/rev-list --reverse/,
					   $parent, qw/--not/);
			foreach my $par (@parents) {
				unless ($par eq $parent) {
					push @cmd, $par;
				}
			}
			my @revsin = ();
			my ($revlist, $ctx) = command_output_pipe(@cmd);
			while (<$revlist>) {
				my $irev = $_;
				chomp $irev;
				my (undef, $csvnrev, undef) =
					cmt_metadata($irev);
				unless (defined $csvnrev) {
					# A child is missing SVN annotations...
					# this might be OK, or might not be.
					warn "W:child $irev is merged into revision "
						 ."$d but does not have git-svn metadata. "
						 ."This means git-svn cannot determine the "
						 ."svn revision numbers to place into the "
						 ."svn:mergeinfo property. You must ensure "
						 ."a branch is entirely committed to "
						 ."SVN before merging it in order for "
						 ."svn:mergeinfo population to function "
						 ."properly";
				}
				push @revsin, $csvnrev;
			}
			command_close_pipe($revlist, $ctx);

			last unless $all_parents_ok;

			# We now have a list of all SVN revnos which are
			# merged by this particular parent. Integrate them.
			next if $#revsin == -1;
			my $newmergeinfo = "$branchpath:" . join(',', @revsin);
			$aggregate_mergeinfo =
				merge_merge_info($aggregate_mergeinfo,
								 $newmergeinfo, 1);
		}
		if ($all_parents_ok and $aggregate_mergeinfo) {
			return $aggregate_mergeinfo;
		}
	}

	return undef;
}

sub cmd_dcommit {
	my $head = shift;
	command_noisy(qw/update-index --refresh/);
	git_cmd_try { command_oneline(qw/diff-index --quiet HEAD/) }
		'Cannot dcommit with a dirty index.  Commit your changes first, '
		. "or stash them with `git stash'.\n";
	$head ||= 'HEAD';

	my $old_head;
	if ($head ne 'HEAD') {
		$old_head = eval {
			command_oneline([qw/symbolic-ref -q HEAD/])
		};
		if ($old_head) {
			$old_head =~ s{^refs/heads/}{};
		} else {
			$old_head = eval { command_oneline(qw/rev-parse HEAD/) };
		}
		command(['checkout', $head], STDERR => 0);
	}

	my @refs;
	my ($url, $rev, $uuid, $gs) = working_head_info('HEAD', \@refs);
	unless ($gs) {
		die "Unable to determine upstream SVN information from ",
		    "$head history.\nPerhaps the repository is empty.";
	}

	if (defined $_commit_url) {
		$url = $_commit_url;
	} else {
		$url = eval { command_oneline('config', '--get',
			      "svn-remote.$gs->{repo_id}.commiturl") };
		if (!$url) {
			$url = $gs->full_pushurl
		}
	}

	my $last_rev = $_revision if defined $_revision;
	if ($url) {
		print "Committing to $url ...\n";
	}
	my ($linear_refs, $parents) = linearize_history($gs, \@refs);
	if ($_no_rebase && scalar(@$linear_refs) > 1) {
		warn "Attempting to commit more than one change while ",
		     "--no-rebase is enabled.\n",
		     "If these changes depend on each other, re-running ",
		     "without --no-rebase may be required."
	}

	if (defined $_interactive){
		my $ask_default = "y";
		foreach my $d (@$linear_refs){
			my ($fh, $ctx) = command_output_pipe(qw(show --summary), "$d");
			while (<$fh>){
				print $_;
			}
			command_close_pipe($fh, $ctx);
			$_ = ask("Commit this patch to SVN? ([y]es (default)|[n]o|[q]uit|[a]ll): ",
			         valid_re => qr/^(?:yes|y|no|n|quit|q|all|a)/i,
			         default => $ask_default);
			die "Commit this patch reply required" unless defined $_;
			if (/^[nq]/i) {
				exit(0);
			} elsif (/^a/i) {
				last;
			}
		}
	}

	my $expect_url = $url;

	my $push_merge_info = eval {
		command_oneline(qw/config --get svn.pushmergeinfo/)
		};
	if (not defined($push_merge_info)
			or $push_merge_info eq "false"
			or $push_merge_info eq "no"
			or $push_merge_info eq "never") {
		$push_merge_info = 0;
	}

	unless (defined($_merge_info) || ! $push_merge_info) {
		# Preflight check of changes to ensure no issues with mergeinfo
		# This includes check for uncommitted-to-SVN parents
		# (other than the first parent, which we will handle),
		# information from different SVN repos, and paths
		# which are not underneath this repository root.
		my $rooturl = $gs->repos_root;
		foreach my $d (@$linear_refs) {
			my %parentshash;
			read_commit_parents(\%parentshash, $d);
			my @realparents = @{$parentshash{$d}};
			if ($#realparents > 0) {
				# Merge commit
				shift @realparents; # Remove/ignore first parent
				foreach my $parent (@realparents) {
					my ($branchurl, $svnrev, $paruuid) = cmt_metadata($parent);
					unless (defined $paruuid) {
						# A parent is missing SVN annotations...
						# abort the whole operation.
						fatal "$parent is merged into revision $d, "
							 ."but does not have git-svn metadata. "
							 ."Either dcommit the branch or use a "
							 ."local cherry-pick, FF merge, or rebase "
							 ."instead of an explicit merge commit.";
					}

					unless ($paruuid eq $uuid) {
						# Parent has SVN metadata from different repository
						fatal "merge parent $parent for change $d has "
							 ."git-svn uuid $paruuid, while current change "
							 ."has uuid $uuid!";
					}

					unless ($branchurl =~ /^\Q$rooturl\E(.*)/) {
						# This branch is very strange indeed.
						fatal "merge parent $parent for $d is on branch "
							 ."$branchurl, which is not under the "
							 ."git-svn root $rooturl!";
					}
				}
			}
		}
	}

	my $rewritten_parent;
	Git::SVN::remove_username($expect_url);
	if (defined($_merge_info)) {
		$_merge_info =~ tr{ }{\n};
	}
	while (1) {
		my $d = shift @$linear_refs or last;
		unless (defined $last_rev) {
			(undef, $last_rev, undef) = cmt_metadata("$d~1");
			unless (defined $last_rev) {
				fatal "Unable to extract revision information ",
				      "from commit $d~1";
			}
		}
		if ($_dry_run) {
			print "diff-tree $d~1 $d\n";
		} else {
			my $cmt_rev;

			unless (defined($_merge_info) || ! $push_merge_info) {
				$_merge_info = populate_merge_info($d, $gs,
				                             $uuid,
				                             $linear_refs,
				                             $rewritten_parent);
			}

			my %ed_opts = ( r => $last_rev,
			                log => get_commit_entry($d)->{log},
			                ra => Git::SVN::Ra->new($url),
			                config => SVN::Core::config_get_config(
			                        $Git::SVN::Ra::config_dir
			                ),
			                tree_a => "$d~1",
			                tree_b => $d,
			                editor_cb => sub {
			                       print "Committed r$_[0]\n";
			                       $cmt_rev = $_[0];
			                },
					mergeinfo => $_merge_info,
			                svn_path => '');
			if (!Git::SVN::Editor->new(\%ed_opts)->apply_diff) {
				print "No changes\n$d~1 == $d\n";
			} elsif ($parents->{$d} && @{$parents->{$d}}) {
				$gs->{inject_parents_dcommit}->{$cmt_rev} =
				                               $parents->{$d};
			}
			$_fetch_all ? $gs->fetch_all : $gs->fetch;
			$last_rev = $cmt_rev;
			next if $_no_rebase;

			# we always want to rebase against the current HEAD,
			# not any head that was passed to us
			my @diff = command('diff-tree', $d,
			                   $gs->refname, '--');
			my @finish;
			if (@diff) {
				@finish = rebase_cmd();
				print STDERR "W: $d and ", $gs->refname,
				             " differ, using @finish:\n",
				             join("\n", @diff), "\n";
			} else {
				print "No changes between current HEAD and ",
				      $gs->refname,
				      "\nResetting to the latest ",
				      $gs->refname, "\n";
				@finish = qw/reset --mixed/;
			}
			command_noisy(@finish, $gs->refname);

			$rewritten_parent = command_oneline(qw/rev-parse HEAD/);

			if (@diff) {
				@refs = ();
				my ($url_, $rev_, $uuid_, $gs_) =
				              working_head_info('HEAD', \@refs);
				my ($linear_refs_, $parents_) =
				              linearize_history($gs_, \@refs);
				if (scalar(@$linear_refs) !=
				    scalar(@$linear_refs_)) {
					fatal "# of revisions changed ",
					  "\nbefore:\n",
					  join("\n", @$linear_refs),
					  "\n\nafter:\n",
					  join("\n", @$linear_refs_), "\n",
					  'If you are attempting to commit ',
					  "merges, try running:\n\t",
					  'git rebase --interactive',
					  '--preserve-merges ',
					  $gs->refname,
					  "\nBefore dcommitting";
				}
				if ($url_ ne $expect_url) {
					if ($url_ eq $gs->metadata_url) {
						print
						  "Accepting rewritten URL:",
						  " $url_\n";
					} else {
						fatal
						  "URL mismatch after rebase:",
						  " $url_ != $expect_url";
					}
				}
				if ($uuid_ ne $uuid) {
					fatal "uuid mismatch after rebase: ",
					      "$uuid_ != $uuid";
				}
				# remap parents
				my (%p, @l, $i);
				for ($i = 0; $i < scalar @$linear_refs; $i++) {
					my $new = $linear_refs_->[$i] or next;
					$p{$new} =
						$parents->{$linear_refs->[$i]};
					push @l, $new;
				}
				$parents = \%p;
				$linear_refs = \@l;
			}
		}
	}

	if ($old_head) {
		my $new_head = command_oneline(qw/rev-parse HEAD/);
		my $new_is_symbolic = eval {
			command_oneline(qw/symbolic-ref -q HEAD/);
		};
		if ($new_is_symbolic) {
			print "dcommitted the branch ", $head, "\n";
		} else {
			print "dcommitted on a detached HEAD because you gave ",
			      "a revision argument.\n",
			      "The rewritten commit is: ", $new_head, "\n";
		}
		command(['checkout', $old_head], STDERR => 0);
	}

	unlink $gs->{index};
}

sub cmd_branch {
	my ($branch_name, $head) = @_;

	unless (defined $branch_name && length $branch_name) {
		die(($_tag ? "tag" : "branch") . " name required\n");
	}
	$head ||= 'HEAD';

	my (undef, $rev, undef, $gs) = working_head_info($head);
	my $src = $gs->full_pushurl;

	my $remote = Git::SVN::read_all_remotes()->{$gs->{repo_id}};
	my $allglobs = $remote->{ $_tag ? 'tags' : 'branches' };
	my $glob;
	if ($#{$allglobs} == 0) {
		$glob = $allglobs->[0];
	} else {
		unless(defined $_branch_dest) {
			die "Multiple ",
			    $_tag ? "tag" : "branch",
			    " paths defined for Subversion repository.\n",
		            "You must specify where you want to create the ",
		            $_tag ? "tag" : "branch",
		            " with the --destination argument.\n";
		}
		foreach my $g (@{$allglobs}) {
			my $re = Git::SVN::Editor::glob2pat($g->{path}->{left});
			if ($_branch_dest =~ /$re/) {
				$glob = $g;
				last;
			}
		}
		unless (defined $glob) {
			my $dest_re = qr/\b\Q$_branch_dest\E\b/;
			foreach my $g (@{$allglobs}) {
				$g->{path}->{left} =~ /$dest_re/ or next;
				if (defined $glob) {
					die "Ambiguous destination: ",
					    $_branch_dest, "\nmatches both '",
					    $glob->{path}->{left}, "' and '",
					    $g->{path}->{left}, "'\n";
				}
				$glob = $g;
			}
			unless (defined $glob) {
				die "Unknown ",
				    $_tag ? "tag" : "branch",
				    " destination $_branch_dest\n";
			}
		}
	}
	my ($lft, $rgt) = @{ $glob->{path} }{qw/left right/};
	my $url;
	if (defined $_commit_url) {
		$url = $_commit_url;
	} else {
		$url = eval { command_oneline('config', '--get',
			"svn-remote.$gs->{repo_id}.commiturl") };
		if (!$url) {
			$url = $remote->{pushurl} || $remote->{url};
		}
	}
	my $dst = join '/', $url, $lft, $branch_name, ($rgt || ());

	if ($dst =~ /^https:/ && $src =~ /^http:/) {
		$src=~s/^http:/https:/;
	}

	::_req_svn();

	my $ctx = SVN::Client->new(
		auth    => Git::SVN::Ra::_auth_providers(),
		log_msg => sub {
			${ $_[0] } = defined $_message
				? $_message
				: 'Create ' . ($_tag ? 'tag ' : 'branch ' )
				. $branch_name;
		},
	);

	eval {
		$ctx->ls($dst, 'HEAD', 0);
	} and die "branch ${branch_name} already exists\n";

	print "Copying ${src} at r${rev} to ${dst}...\n";
	$ctx->copy($src, $rev, $dst)
		unless $_dry_run;

	$gs->fetch_all;
}

sub cmd_find_rev {
	my $revision_or_hash = shift or die "SVN or git revision required ",
	                                    "as a command-line argument\n";
	my $result;
	if ($revision_or_hash =~ /^r\d+$/) {
		my $head = shift;
		$head ||= 'HEAD';
		my @refs;
		my (undef, undef, $uuid, $gs) = working_head_info($head, \@refs);
		unless ($gs) {
			die "Unable to determine upstream SVN information from ",
			    "$head history\n";
		}
		my $desired_revision = substr($revision_or_hash, 1);
		$result = $gs->rev_map_get($desired_revision, $uuid);
	} else {
		my (undef, $rev, undef) = cmt_metadata($revision_or_hash);
		$result = $rev;
	}
	print "$result\n" if $result;
}

sub auto_create_empty_directories {
	my ($gs) = @_;
	my $var = eval { command_oneline('config', '--get', '--bool',
					 "svn-remote.$gs->{repo_id}.automkdirs") };
	# By default, create empty directories by consulting the unhandled log,
	# but allow setting it to 'false' to skip it.
	return !($var && $var eq 'false');
}

sub cmd_rebase {
	command_noisy(qw/update-index --refresh/);
	my ($url, $rev, $uuid, $gs) = working_head_info('HEAD');
	unless ($gs) {
		die "Unable to determine upstream SVN information from ",
		    "working tree history\n";
	}
	if ($_dry_run) {
		print "Remote Branch: " . $gs->refname . "\n";
		print "SVN URL: " . $url . "\n";
		return;
	}
	if (command(qw/diff-index HEAD --/)) {
		print STDERR "Cannot rebase with uncommited changes:\n";
		command_noisy('status');
		exit 1;
	}
	unless ($_local) {
		# rebase will checkout for us, so no need to do it explicitly
		$_no_checkout = 'true';
		$_fetch_all ? $gs->fetch_all : $gs->fetch;
	}
	command_noisy(rebase_cmd(), $gs->refname);
	if (auto_create_empty_directories($gs)) {
		$gs->mkemptydirs;
	}
}

sub cmd_show_ignore {
	my ($url, $rev, $uuid, $gs) = working_head_info('HEAD');
	$gs ||= Git::SVN->new;
	my $r = (defined $_revision ? $_revision : $gs->ra->get_latest_revnum);
	$gs->prop_walk($gs->{path}, $r, sub {
		my ($gs, $path, $props) = @_;
		print STDOUT "\n# $path\n";
		my $s = $props->{'svn:ignore'} or return;
		$s =~ s/[\r\n]+/\n/g;
		$s =~ s/^\n+//;
		chomp $s;
		$s =~ s#^#$path#gm;
		print STDOUT "$s\n";
	});
}

sub cmd_show_externals {
	my ($url, $rev, $uuid, $gs) = working_head_info('HEAD');
	$gs ||= Git::SVN->new;
	my $r = (defined $_revision ? $_revision : $gs->ra->get_latest_revnum);
	$gs->prop_walk($gs->{path}, $r, sub {
		my ($gs, $path, $props) = @_;
		print STDOUT "\n# $path\n";
		my $s = $props->{'svn:externals'} or return;
		$s =~ s/[\r\n]+/\n/g;
		chomp $s;
		$s =~ s#^#$path#gm;
		print STDOUT "$s\n";
	});
}

sub cmd_create_ignore {
	my ($url, $rev, $uuid, $gs) = working_head_info('HEAD');
	$gs ||= Git::SVN->new;
	my $r = (defined $_revision ? $_revision : $gs->ra->get_latest_revnum);
	$gs->prop_walk($gs->{path}, $r, sub {
		my ($gs, $path, $props) = @_;
		# $path is of the form /path/to/dir/
		$path = '.' . $path;
		# SVN can have attributes on empty directories,
		# which git won't track
		mkpath([$path]) unless -d $path;
		my $ignore = $path . '.gitignore';
		my $s = $props->{'svn:ignore'} or return;
		open(GITIGNORE, '>', $ignore)
		  or fatal("Failed to open `$ignore' for writing: $!");
		$s =~ s/[\r\n]+/\n/g;
		$s =~ s/^\n+//;
		chomp $s;
		# Prefix all patterns so that the ignore doesn't apply
		# to sub-directories.
		$s =~ s#^#/#gm;
		print GITIGNORE "$s\n";
		close(GITIGNORE)
		  or fatal("Failed to close `$ignore': $!");
		command_noisy('add', '-f', $ignore);
	});
}

sub cmd_mkdirs {
	my ($url, $rev, $uuid, $gs) = working_head_info('HEAD');
	$gs ||= Git::SVN->new;
	$gs->mkemptydirs($_revision);
}

sub canonicalize_path {
	my ($path) = @_;
	my $dot_slash_added = 0;
	if (substr($path, 0, 1) ne "/") {
		$path = "./" . $path;
		$dot_slash_added = 1;
	}
	# File::Spec->canonpath doesn't collapse x/../y into y (for a
	# good reason), so let's do this manually.
	$path =~ s#/+#/#g;
	$path =~ s#/\.(?:/|$)#/#g;
	$path =~ s#/[^/]+/\.\.##g;
	$path =~ s#/$##g;
	$path =~ s#^\./## if $dot_slash_added;
	$path =~ s#^/##;
	$path =~ s#^\.$##;
	return $path;
}

sub canonicalize_url {
	my ($url) = @_;
	$url =~ s#^([^:]+://[^/]*/)(.*)$#$1 . canonicalize_path($2)#e;
	return $url;
}

# get_svnprops(PATH)
# ------------------
# Helper for cmd_propget and cmd_proplist below.
sub get_svnprops {
	my $path = shift;
	my ($url, $rev, $uuid, $gs) = working_head_info('HEAD');
	$gs ||= Git::SVN->new;

	# prefix THE PATH by the sub-directory from which the user
	# invoked us.
	$path = $cmd_dir_prefix . $path;
	fatal("No such file or directory: $path") unless -e $path;
	my $is_dir = -d $path ? 1 : 0;
	$path = $gs->{path} . '/' . $path;

	# canonicalize the path (otherwise libsvn will abort or fail to
	# find the file)
	$path = canonicalize_path($path);

	my $r = (defined $_revision ? $_revision : $gs->ra->get_latest_revnum);
	my $props;
	if ($is_dir) {
		(undef, undef, $props) = $gs->ra->get_dir($path, $r);
	}
	else {
		(undef, $props) = $gs->ra->get_file($path, $r, undef);
	}
	return $props;
}

# cmd_propget (PROP, PATH)
# ------------------------
# Print the SVN property PROP for PATH.
sub cmd_propget {
	my ($prop, $path) = @_;
	$path = '.' if not defined $path;
	usage(1) if not defined $prop;
	my $props = get_svnprops($path);
	if (not defined $props->{$prop}) {
		fatal("`$path' does not have a `$prop' SVN property.");
	}
	print $props->{$prop} . "\n";
}

# cmd_proplist (PATH)
# -------------------
# Print the list of SVN properties for PATH.
sub cmd_proplist {
	my $path = shift;
	$path = '.' if not defined $path;
	my $props = get_svnprops($path);
	print "Properties on '$path':\n";
	foreach (sort keys %{$props}) {
		print "  $_\n";
	}
}

sub cmd_multi_init {
	my $url = shift;
	unless (defined $_trunk || @_branches || @_tags) {
		usage(1);
	}

	$_prefix = '' unless defined $_prefix;
	if (defined $url) {
		$url = canonicalize_url($url);
		init_subdir(@_);
	}
	do_git_init_db();
	if (defined $_trunk) {
		$_trunk =~ s#^/+##;
		my $trunk_ref = 'refs/remotes/' . $_prefix . 'trunk';
		# try both old-style and new-style lookups:
		my $gs_trunk = eval { Git::SVN->new($trunk_ref) };
		unless ($gs_trunk) {
			my ($trunk_url, $trunk_path) =
			                      complete_svn_url($url, $_trunk);
			$gs_trunk = Git::SVN->init($trunk_url, $trunk_path,
						   undef, $trunk_ref);
		}
	}
	return unless @_branches || @_tags;
	my $ra = $url ? Git::SVN::Ra->new($url) : undef;
	foreach my $path (@_branches) {
		complete_url_ls_init($ra, $path, '--branches/-b', $_prefix);
	}
	foreach my $path (@_tags) {
		complete_url_ls_init($ra, $path, '--tags/-t', $_prefix.'tags/');
	}
}

sub cmd_multi_fetch {
	$Git::SVN::no_reuse_existing = undef;
	my $remotes = Git::SVN::read_all_remotes();
	foreach my $repo_id (sort keys %$remotes) {
		if ($remotes->{$repo_id}->{url}) {
			Git::SVN::fetch_all($repo_id, $remotes);
		}
	}
}

# this command is special because it requires no metadata
sub cmd_commit_diff {
	my ($ta, $tb, $url) = @_;
	my $usage = "Usage: $0 commit-diff -r<revision> ".
	            "<tree-ish> <tree-ish> [<URL>]";
	fatal($usage) if (!defined $ta || !defined $tb);
	my $svn_path = '';
	if (!defined $url) {
		my $gs = eval { Git::SVN->new };
		if (!$gs) {
			fatal("Needed URL or usable git-svn --id in ",
			      "the command-line\n", $usage);
		}
		$url = $gs->{url};
		$svn_path = $gs->{path};
	}
	unless (defined $_revision) {
		fatal("-r|--revision is a required argument\n", $usage);
	}
	if (defined $_message && defined $_file) {
		fatal("Both --message/-m and --file/-F specified ",
		      "for the commit message.\n",
		      "I have no idea what you mean");
	}
	if (defined $_file) {
		$_message = file_to_s($_file);
	} else {
		$_message ||= get_commit_entry($tb)->{log};
	}
	my $ra ||= Git::SVN::Ra->new($url);
	my $r = $_revision;
	if ($r eq 'HEAD') {
		$r = $ra->get_latest_revnum;
	} elsif ($r !~ /^\d+$/) {
		die "revision argument: $r not understood by git-svn\n";
	}
	my %ed_opts = ( r => $r,
	                log => $_message,
	                ra => $ra,
	                tree_a => $ta,
	                tree_b => $tb,
	                editor_cb => sub { print "Committed r$_[0]\n" },
	                svn_path => $svn_path );
	if (!Git::SVN::Editor->new(\%ed_opts)->apply_diff) {
		print "No changes\n$ta == $tb\n";
	}
}

sub escape_uri_only {
	my ($uri) = @_;
	my @tmp;
	foreach (split m{/}, $uri) {
		s/([^~\w.%+-]|%(?![a-fA-F0-9]{2}))/sprintf("%%%02X",ord($1))/eg;
		push @tmp, $_;
	}
	join('/', @tmp);
}

sub escape_url {
	my ($url) = @_;
	if ($url =~ m#^([^:]+)://([^/]*)(.*)$#) {
		my ($scheme, $domain, $uri) = ($1, $2, escape_uri_only($3));
		$url = "$scheme://$domain$uri";
	}
	$url;
}

sub cmd_info {
	my $path = canonicalize_path(defined($_[0]) ? $_[0] : ".");
	my $fullpath = canonicalize_path($cmd_dir_prefix . $path);
	if (exists $_[1]) {
		die "Too many arguments specified\n";
	}

	my ($file_type, $diff_status) = find_file_type_and_diff_status($path);

	if (!$file_type && !$diff_status) {
		print STDERR "svn: '$path' is not under version control\n";
		exit 1;
	}

	my ($url, $rev, $uuid, $gs) = working_head_info('HEAD');
	unless ($gs) {
		die "Unable to determine upstream SVN information from ",
		    "working tree history\n";
	}

	# canonicalize_path() will return "" to make libsvn 1.5.x happy,
	$path = "." if $path eq "";

	my $full_url = $url . ($fullpath eq "" ? "" : "/$fullpath");

	if ($_url) {
		print escape_url($full_url), "\n";
		return;
	}

	my $result = "Path: $path\n";
	$result .= "Name: " . basename($path) . "\n" if $file_type ne "dir";
	$result .= "URL: " . escape_url($full_url) . "\n";

	eval {
		my $repos_root = $gs->repos_root;
		Git::SVN::remove_username($repos_root);
		$result .= "Repository Root: " . escape_url($repos_root) . "\n";
	};
	if ($@) {
		$result .= "Repository Root: (offline)\n";
	}
	::_req_svn();
	$result .= "Repository UUID: $uuid\n" unless $diff_status eq "A" &&
		(::compare_svn_version('1.5.4') <= 0 || $file_type ne "dir");
	$result .= "Revision: " . ($diff_status eq "A" ? 0 : $rev) . "\n";

	$result .= "Node Kind: " .
		   ($file_type eq "dir" ? "directory" : "file") . "\n";

	my $schedule = $diff_status eq "A"
		       ? "add"
		       : ($diff_status eq "D" ? "delete" : "normal");
	$result .= "Schedule: $schedule\n";

	if ($diff_status eq "A") {
		print $result, "\n";
		return;
	}

	my ($lc_author, $lc_rev, $lc_date_utc);
	my @args = Git::SVN::Log::git_svn_log_cmd($rev, $rev, "--", $fullpath);
	my $log = command_output_pipe(@args);
	my $esc_color = qr/(?:\033\[(?:(?:\d+;)*\d*)?m)*/;
	while (<$log>) {
		if (/^${esc_color}author (.+) <[^>]+> (\d+) ([\-\+]?\d+)$/o) {
			$lc_author = $1;
			$lc_date_utc = Git::SVN::Log::parse_git_date($2, $3);
		} elsif (/^${esc_color}    (git-svn-id:.+)$/o) {
			(undef, $lc_rev, undef) = ::extract_metadata($1);
		}
	}
	close $log;

	Git::SVN::Log::set_local_timezone();

	$result .= "Last Changed Author: $lc_author\n";
	$result .= "Last Changed Rev: $lc_rev\n";
	$result .= "Last Changed Date: " .
		   Git::SVN::Log::format_svn_date($lc_date_utc) . "\n";

	if ($file_type ne "dir") {
		my $text_last_updated_date =
		    ($diff_status eq "D" ? $lc_date_utc : (stat $path)[9]);
		$result .=
		    "Text Last Updated: " .
		    Git::SVN::Log::format_svn_date($text_last_updated_date) .
		    "\n";
		my $checksum;
		if ($diff_status eq "D") {
			my ($fh, $ctx) =
			    command_output_pipe(qw(cat-file blob), "HEAD:$path");
			if ($file_type eq "link") {
				my $file_name = <$fh>;
				$checksum = md5sum("link $file_name");
			} else {
				$checksum = md5sum($fh);
			}
			command_close_pipe($fh, $ctx);
		} elsif ($file_type eq "link") {
			my $file_name =
			    command(qw(cat-file blob), "HEAD:$path");
			$checksum =
			    md5sum("link " . $file_name);
		} else {
			open FILE, "<", $path or die $!;
			$checksum = md5sum(\*FILE);
			close FILE or die $!;
		}
		$result .= "Checksum: " . $checksum . "\n";
	}

	print $result, "\n";
}

sub cmd_reset {
	my $target = shift || $_revision or die "SVN revision required\n";
	$target = $1 if $target =~ /^r(\d+)$/;
	$target =~ /^\d+$/ or die "Numeric SVN revision expected\n";
	my ($url, $rev, $uuid, $gs) = working_head_info('HEAD');
	unless ($gs) {
		die "Unable to determine upstream SVN information from ".
		    "history\n";
	}
	my ($r, $c) = $gs->find_rev_before($target, not $_fetch_parent);
	die "Cannot find SVN revision $target\n" unless defined($c);
	$gs->rev_map_set($r, $c, 'reset', $uuid);
	print "r$r = $c ($gs->{ref_id})\n";
}

sub cmd_gc {
	if (!can_compress()) {
		warn "Compress::Zlib could not be found; unhandled.log " .
		     "files will not be compressed.\n";
	}
	find({ wanted => \&gc_directory, no_chdir => 1}, "$ENV{GIT_DIR}/svn");
}

########################### utility functions #########################

sub rebase_cmd {
	my @cmd = qw/rebase/;
	push @cmd, '-v' if $_verbose;
	push @cmd, qw/--merge/ if $_merge;
	push @cmd, "--strategy=$_strategy" if $_strategy;
	push @cmd, "--preserve-merges" if $_preserve_merges;
	@cmd;
}

sub post_fetch_checkout {
	return if $_no_checkout;
	return if verify_ref('HEAD^0');
	my $gs = $Git::SVN::_head or return;

	# look for "trunk" ref if it exists
	my $remote = Git::SVN::read_all_remotes()->{$gs->{repo_id}};
	my $fetch = $remote->{fetch};
	if ($fetch) {
		foreach my $p (keys %$fetch) {
			basename($fetch->{$p}) eq 'trunk' or next;
			$gs = Git::SVN->new($fetch->{$p}, $gs->{repo_id}, $p);
			last;
		}
	}

	command_noisy(qw(update-ref HEAD), $gs->refname);
	return unless verify_ref('HEAD^0');

	return if $ENV{GIT_DIR} !~ m#^(?:.*/)?\.git$#;
	my $index = $ENV{GIT_INDEX_FILE} || "$ENV{GIT_DIR}/index";
	return if -f $index;

	return if command_oneline(qw/rev-parse --is-inside-work-tree/) eq 'false';
	return if command_oneline(qw/rev-parse --is-inside-git-dir/) eq 'true';
	command_noisy(qw/read-tree -m -u -v HEAD HEAD/);
	print STDERR "Checked out HEAD:\n  ",
	             $gs->full_url, " r", $gs->last_rev, "\n";
	if (auto_create_empty_directories($gs)) {
		$gs->mkemptydirs($gs->last_rev);
	}
}

sub complete_svn_url {
	my ($url, $path) = @_;
	$path =~ s#/+$##;
	if ($path !~ m#^[a-z\+]+://#) {
		if (!defined $url || $url !~ m#^[a-z\+]+://#) {
			fatal("E: '$path' is not a complete URL ",
			      "and a separate URL is not specified");
		}
		return ($url, $path);
	}
	return ($path, '');
}

sub complete_url_ls_init {
	my ($ra, $repo_path, $switch, $pfx) = @_;
	unless ($repo_path) {
		print STDERR "W: $switch not specified\n";
		return;
	}
	$repo_path =~ s#/+$##;
	if ($repo_path =~ m#^[a-z\+]+://#) {
		$ra = Git::SVN::Ra->new($repo_path);
		$repo_path = '';
	} else {
		$repo_path =~ s#^/+##;
		unless ($ra) {
			fatal("E: '$repo_path' is not a complete URL ",
			      "and a separate URL is not specified");
		}
	}
	my $url = $ra->{url};
	my $gs = Git::SVN->init($url, undef, undef, undef, 1);
	my $k = "svn-remote.$gs->{repo_id}.url";
	my $orig_url = eval { command_oneline(qw/config --get/, $k) };
	if ($orig_url && ($orig_url ne $gs->{url})) {
		die "$k already set: $orig_url\n",
		    "wanted to set to: $gs->{url}\n";
	}
	command_oneline('config', $k, $gs->{url}) unless $orig_url;
	my $remote_path = "$gs->{path}/$repo_path";
	$remote_path =~ s{%([0-9A-F]{2})}{chr hex($1)}ieg;
	$remote_path =~ s#/+#/#g;
	$remote_path =~ s#^/##g;
	$remote_path .= "/*" if $remote_path !~ /\*/;
	my ($n) = ($switch =~ /^--(\w+)/);
	if (length $pfx && $pfx !~ m#/$#) {
		die "--prefix='$pfx' must have a trailing slash '/'\n";
	}
	command_noisy('config',
		      '--add',
	              "svn-remote.$gs->{repo_id}.$n",
	              "$remote_path:refs/remotes/$pfx*" .
	                ('/*' x (($remote_path =~ tr/*/*/) - 1)) );
}

sub verify_ref {
	my ($ref) = @_;
	eval { command_oneline([ 'rev-parse', '--verify', $ref ],
	                       { STDERR => 0 }); };
}

sub get_tree_from_treeish {
	my ($treeish) = @_;
	# $treeish can be a symbolic ref, too:
	my $type = command_oneline(qw/cat-file -t/, $treeish);
	my $expected;
	while ($type eq 'tag') {
		($treeish, $type) = command(qw/cat-file tag/, $treeish);
	}
	if ($type eq 'commit') {
		$expected = (grep /^tree /, command(qw/cat-file commit/,
		                                    $treeish))[0];
		($expected) = ($expected =~ /^tree ($sha1)$/o);
		die "Unable to get tree from $treeish\n" unless $expected;
	} elsif ($type eq 'tree') {
		$expected = $treeish;
	} else {
		die "$treeish is a $type, expected tree, tag or commit\n";
	}
	return $expected;
}

sub get_commit_entry {
	my ($treeish) = shift;
	my %log_entry = ( log => '', tree => get_tree_from_treeish($treeish) );
	my $commit_editmsg = "$ENV{GIT_DIR}/COMMIT_EDITMSG";
	my $commit_msg = "$ENV{GIT_DIR}/COMMIT_MSG";
	open my $log_fh, '>', $commit_editmsg or croak $!;

	my $type = command_oneline(qw/cat-file -t/, $treeish);
	if ($type eq 'commit' || $type eq 'tag') {
		my ($msg_fh, $ctx) = command_output_pipe('cat-file',
		                                         $type, $treeish);
		my $in_msg = 0;
		my $author;
		my $saw_from = 0;
		my $msgbuf = "";
		while (<$msg_fh>) {
			if (!$in_msg) {
				$in_msg = 1 if (/^\s*$/);
				$author = $1 if (/^author (.*>)/);
			} elsif (/^git-svn-id: /) {
				# skip this for now, we regenerate the
				# correct one on re-fetch anyways
				# TODO: set *:merge properties or like...
			} else {
				if (/^From:/ || /^Signed-off-by:/) {
					$saw_from = 1;
				}
				$msgbuf .= $_;
			}
		}
		$msgbuf =~ s/\s+$//s;
		if ($Git::SVN::_add_author_from && defined($author)
		    && !$saw_from) {
			$msgbuf .= "\n\nFrom: $author";
		}
		print $log_fh $msgbuf or croak $!;
		command_close_pipe($msg_fh, $ctx);
	}
	close $log_fh or croak $!;

	if ($_edit || ($type eq 'tree')) {
		chomp(my $editor = command_oneline(qw(var GIT_EDITOR)));
		system('sh', '-c', $editor.' "$@"', $editor, $commit_editmsg);
	}
	rename $commit_editmsg, $commit_msg or croak $!;
	{
		require Encode;
		# SVN requires messages to be UTF-8 when entering the repo
		local $/;
		open $log_fh, '<', $commit_msg or croak $!;
		binmode $log_fh;
		chomp($log_entry{log} = <$log_fh>);

		my $enc = Git::config('i18n.commitencoding') || 'UTF-8';
		my $msg = $log_entry{log};

		eval { $msg = Encode::decode($enc, $msg, 1) };
		if ($@) {
			die "Could not decode as $enc:\n", $msg,
			    "\nPerhaps you need to set i18n.commitencoding\n";
		}

		eval { $msg = Encode::encode('UTF-8', $msg, 1) };
		die "Could not encode as UTF-8:\n$msg\n" if $@;

		$log_entry{log} = $msg;

		close $log_fh or croak $!;
	}
	unlink $commit_msg;
	\%log_entry;
}

sub s_to_file {
	my ($str, $file, $mode) = @_;
	open my $fd,'>',$file or croak $!;
	print $fd $str,"\n" or croak $!;
	close $fd or croak $!;
	chmod ($mode &~ umask, $file) if (defined $mode);
}

sub file_to_s {
	my $file = shift;
	open my $fd,'<',$file or croak "$!: file: $file\n";
	local $/;
	my $ret = <$fd>;
	close $fd or croak $!;
	$ret =~ s/\s*$//s;
	return $ret;
}

# '<svn username> = real-name <email address>' mapping based on git-svnimport:
sub load_authors {
	open my $authors, '<', $_authors or die "Can't open $_authors $!\n";
	my $log = $cmd eq 'log';
	while (<$authors>) {
		chomp;
		next unless /^(.+?|\(no author\))\s*=\s*(.+?)\s*<(.+)>\s*$/;
		my ($user, $name, $email) = ($1, $2, $3);
		if ($log) {
			$Git::SVN::Log::rusers{"$name <$email>"} = $user;
		} else {
			$users{$user} = [$name, $email];
		}
	}
	close $authors or croak $!;
}

# convert GetOpt::Long specs for use by git-config
sub read_git_config {
	my $opts = shift;
	my @config_only;
	foreach my $o (keys %$opts) {
		# if we have mixedCase and a long option-only, then
		# it's a config-only variable that we don't need for
		# the command-line.
		push @config_only, $o if ($o =~ /[A-Z]/ && $o =~ /^[a-z]+$/i);
		my $v = $opts->{$o};
		my ($key) = ($o =~ /^([a-zA-Z\-]+)/);
		$key =~ s/-//g;
		my $arg = 'git config';
		$arg .= ' --int' if ($o =~ /[:=]i$/);
		$arg .= ' --bool' if ($o !~ /[:=][sfi]$/);
		if (ref $v eq 'ARRAY') {
			chomp(my @tmp = `$arg --get-all svn.$key`);
			@$v = @tmp if @tmp;
		} else {
			chomp(my $tmp = `$arg --get svn.$key`);
			if ($tmp && !($arg =~ / --bool/ && $tmp eq 'false')) {
				$$v = $tmp;
			}
		}
	}
	delete @$opts{@config_only} if @config_only;
}

sub extract_metadata {
	my $id = shift or return (undef, undef, undef);
	my ($url, $rev, $uuid) = ($id =~ /^\s*git-svn-id:\s+(.*)\@(\d+)
							\s([a-f\d\-]+)$/ix);
	if (!defined $rev || !$uuid || !$url) {
		# some of the original repositories I made had
		# identifiers like this:
		($rev, $uuid) = ($id =~/^\s*git-svn-id:\s(\d+)\@([a-f\d\-]+)/i);
	}
	return ($url, $rev, $uuid);
}

sub cmt_metadata {
	return extract_metadata((grep(/^git-svn-id: /,
		command(qw/cat-file commit/, shift)))[-1]);
}

sub cmt_sha2rev_batch {
	my %s2r;
	my ($pid, $in, $out, $ctx) = command_bidi_pipe(qw/cat-file --batch/);
	my $list = shift;

	foreach my $sha (@{$list}) {
		my $first = 1;
		my $size = 0;
		print $out $sha, "\n";

		while (my $line = <$in>) {
			if ($first && $line =~ /^[[:xdigit:]]{40}\smissing$/) {
				last;
			} elsif ($first &&
			       $line =~ /^[[:xdigit:]]{40}\scommit\s(\d+)$/) {
				$first = 0;
				$size = $1;
				next;
			} elsif ($line =~ /^(git-svn-id: )/) {
				my (undef, $rev, undef) =
				                      extract_metadata($line);
				$s2r{$sha} = $rev;
			}

			$size -= length($line);
			last if ($size == 0);
		}
	}

	command_close_bidi_pipe($pid, $in, $out, $ctx);

	return \%s2r;
}

sub working_head_info {
	my ($head, $refs) = @_;
	my @args = qw/rev-list --first-parent --pretty=medium/;
	my ($fh, $ctx) = command_output_pipe(@args, $head);
	my $hash;
	my %max;
	while (<$fh>) {
		if ( m{^commit ($::sha1)$} ) {
			unshift @$refs, $hash if $hash and $refs;
			$hash = $1;
			next;
		}
		next unless s{^\s*(git-svn-id:)}{$1};
		my ($url, $rev, $uuid) = extract_metadata($_);
		if (defined $url && defined $rev) {
			next if $max{$url} and $max{$url} < $rev;
			if (my $gs = Git::SVN->find_by_url($url)) {
				my $c = $gs->rev_map_get($rev, $uuid);
				if ($c && $c eq $hash) {
					close $fh; # break the pipe
					return ($url, $rev, $uuid, $gs);
				} else {
					$max{$url} ||= $gs->rev_map_max;
				}
			}
		}
	}
	command_close_pipe($fh, $ctx);
	(undef, undef, undef, undef);
}

sub read_commit_parents {
	my ($parents, $c) = @_;
	chomp(my $p = command_oneline(qw/rev-list --parents -1/, $c));
	$p =~ s/^($c)\s*// or die "rev-list --parents -1 $c failed!\n";
	@{$parents->{$c}} = split(/ /, $p);
}

sub linearize_history {
	my ($gs, $refs) = @_;
	my %parents;
	foreach my $c (@$refs) {
		read_commit_parents(\%parents, $c);
	}

	my @linear_refs;
	my %skip = ();
	my $last_svn_commit = $gs->last_commit;
	foreach my $c (reverse @$refs) {
		next if $c eq $last_svn_commit;
		last if $skip{$c};

		unshift @linear_refs, $c;
		$skip{$c} = 1;

		# we only want the first parent to diff against for linear
		# history, we save the rest to inject when we finalize the
		# svn commit
		my $fp_a = verify_ref("$c~1");
		my $fp_b = shift @{$parents{$c}} if $parents{$c};
		if (!$fp_a || !$fp_b) {
			die "Commit $c\n",
			    "has no parent commit, and therefore ",
			    "nothing to diff against.\n",
			    "You should be working from a repository ",
			    "originally created by git-svn\n";
		}
		if ($fp_a ne $fp_b) {
			die "$c~1 = $fp_a, however parsing commit $c ",
			    "revealed that:\n$c~1 = $fp_b\nBUG!\n";
		}

		foreach my $p (@{$parents{$c}}) {
			$skip{$p} = 1;
		}
	}
	(\@linear_refs, \%parents);
}

sub find_file_type_and_diff_status {
	my ($path) = @_;
	return ('dir', '') if $path eq '';

	my $diff_output =
	    command_oneline(qw(diff --cached --name-status --), $path) || "";
	my $diff_status = (split(' ', $diff_output))[0] || "";

	my $ls_tree = command_oneline(qw(ls-tree HEAD), $path) || "";

	return (undef, undef) if !$diff_status && !$ls_tree;

	if ($diff_status eq "A") {
		return ("link", $diff_status) if -l $path;
		return ("dir", $diff_status) if -d $path;
		return ("file", $diff_status);
	}

	my $mode = (split(' ', $ls_tree))[0] || "";

	return ("link", $diff_status) if $mode eq "120000";
	return ("dir", $diff_status) if $mode eq "040000";
	return ("file", $diff_status);
}

sub md5sum {
	my $arg = shift;
	my $ref = ref $arg;
	my $md5 = Digest::MD5->new();
        if ($ref eq 'GLOB' || $ref eq 'IO::File' || $ref eq 'File::Temp') {
		$md5->addfile($arg) or croak $!;
	} elsif ($ref eq 'SCALAR') {
		$md5->add($$arg) or croak $!;
	} elsif (!$ref) {
		$md5->add($arg) or croak $!;
	} else {
		fatal "Can't provide MD5 hash for unknown ref type: '", $ref, "'";
	}
	return $md5->hexdigest();
}

sub gc_directory {
	if (can_compress() && -f $_ && basename($_) eq "unhandled.log") {
		my $out_filename = $_ . ".gz";
		open my $in_fh, "<", $_ or die "Unable to open $_: $!\n";
		binmode $in_fh;
		my $gz = Compress::Zlib::gzopen($out_filename, "ab") or
				die "Unable to open $out_filename: $!\n";

		my $res;
		while ($res = sysread($in_fh, my $str, 1024)) {
			$gz->gzwrite($str) or
				die "Unable to write: ".$gz->gzerror()."!\n";
		}
		unlink $_ or die "unlink $File::Find::name: $!\n";
	} elsif (-f $_ && basename($_) eq "index") {
		unlink $_ or die "unlink $_: $!\n";
	}
}


package Git::SVN::Log;
use strict;
use warnings;
use Git::SVN::Utils qw(fatal);
use POSIX qw/strftime/;
use constant commit_log_separator => ('-' x 72) . "\n";
use vars qw/$TZ $limit $color $pager $non_recursive $verbose $oneline
            %rusers $show_commit $incremental/;
my $l_fmt;

sub cmt_showable {
	my ($c) = @_;
	return 1 if defined $c->{r};

	# big commit message got truncated by the 16k pretty buffer in rev-list
	if ($c->{l} && $c->{l}->[-1] eq "...\n" &&
				$c->{a_raw} =~ /\@([a-f\d\-]+)>$/) {
		@{$c->{l}} = ();
		my @log = command(qw/cat-file commit/, $c->{c});

		# shift off the headers
		shift @log while ($log[0] ne '');
		shift @log;

		# TODO: make $c->{l} not have a trailing newline in the future
		@{$c->{l}} = map { "$_\n" } grep !/^git-svn-id: /, @log;

		(undef, $c->{r}, undef) = ::extract_metadata(
				(grep(/^git-svn-id: /, @log))[-1]);
	}
	return defined $c->{r};
}

sub log_use_color {
	return $color || Git->repository->get_colorbool('color.diff');
}

sub git_svn_log_cmd {
	my ($r_min, $r_max, @args) = @_;
	my $head = 'HEAD';
	my (@files, @log_opts);
	foreach my $x (@args) {
		if ($x eq '--' || @files) {
			push @files, $x;
		} else {
			if (::verify_ref("$x^0")) {
				$head = $x;
			} else {
				push @log_opts, $x;
			}
		}
	}

	my ($url, $rev, $uuid, $gs) = ::working_head_info($head);
	$gs ||= Git::SVN->_new;
	my @cmd = (qw/log --abbrev-commit --pretty=raw --default/,
	           $gs->refname);
	push @cmd, '-r' unless $non_recursive;
	push @cmd, qw/--raw --name-status/ if $verbose;
	push @cmd, '--color' if log_use_color();
	push @cmd, @log_opts;
	if (defined $r_max && $r_max == $r_min) {
		push @cmd, '--max-count=1';
		if (my $c = $gs->rev_map_get($r_max)) {
			push @cmd, $c;
		}
	} elsif (defined $r_max) {
		if ($r_max < $r_min) {
			($r_min, $r_max) = ($r_max, $r_min);
		}
		my (undef, $c_max) = $gs->find_rev_before($r_max, 1, $r_min);
		my (undef, $c_min) = $gs->find_rev_after($r_min, 1, $r_max);
		# If there are no commits in the range, both $c_max and $c_min
		# will be undefined.  If there is at least 1 commit in the
		# range, both will be defined.
		return () if !defined $c_min || !defined $c_max;
		if ($c_min eq $c_max) {
			push @cmd, '--max-count=1', $c_min;
		} else {
			push @cmd, '--boundary', "$c_min..$c_max";
		}
	}
	return (@cmd, @files);
}

# adapted from pager.c
sub config_pager {
	if (! -t *STDOUT) {
		$ENV{GIT_PAGER_IN_USE} = 'false';
		$pager = undef;
		return;
	}
	chomp($pager = command_oneline(qw(var GIT_PAGER)));
	if ($pager eq 'cat') {
		$pager = undef;
	}
	$ENV{GIT_PAGER_IN_USE} = defined($pager);
}

sub run_pager {
	return unless defined $pager;
	pipe my ($rfd, $wfd) or return;
	defined(my $pid = fork) or fatal "Can't fork: $!";
	if (!$pid) {
		open STDOUT, '>&', $wfd or
		                     fatal "Can't redirect to stdout: $!";
		return;
	}
	open STDIN, '<&', $rfd or fatal "Can't redirect stdin: $!";
	$ENV{LESS} ||= 'FRSX';
	exec $pager or fatal "Can't run pager: $! ($pager)";
}

sub format_svn_date {
	my $t = shift || time;
	my $gmoff = Git::SVN::get_tz($t);
	return strftime("%Y-%m-%d %H:%M:%S $gmoff (%a, %d %b %Y)", localtime($t));
}

sub parse_git_date {
	my ($t, $tz) = @_;
	# Date::Parse isn't in the standard Perl distro :(
	if ($tz =~ s/^\+//) {
		$t += tz_to_s_offset($tz);
	} elsif ($tz =~ s/^\-//) {
		$t -= tz_to_s_offset($tz);
	}
	return $t;
}

sub set_local_timezone {
	if (defined $TZ) {
		$ENV{TZ} = $TZ;
	} else {
		delete $ENV{TZ};
	}
}

sub tz_to_s_offset {
	my ($tz) = @_;
	$tz =~ s/(\d\d)$//;
	return ($1 * 60) + ($tz * 3600);
}

sub get_author_info {
	my ($dest, $author, $t, $tz) = @_;
	$author =~ s/(?:^\s*|\s*$)//g;
	$dest->{a_raw} = $author;
	my $au;
	if ($::_authors) {
		$au = $rusers{$author} || undef;
	}
	if (!$au) {
		($au) = ($author =~ /<([^>]+)\@[^>]+>$/);
	}
	$dest->{t} = $t;
	$dest->{tz} = $tz;
	$dest->{a} = $au;
	$dest->{t_utc} = parse_git_date($t, $tz);
}

sub process_commit {
	my ($c, $r_min, $r_max, $defer) = @_;
	if (defined $r_min && defined $r_max) {
		if ($r_min == $c->{r} && $r_min == $r_max) {
			show_commit($c);
			return 0;
		}
		return 1 if $r_min == $r_max;
		if ($r_min < $r_max) {
			# we need to reverse the print order
			return 0 if (defined $limit && --$limit < 0);
			push @$defer, $c;
			return 1;
		}
		if ($r_min != $r_max) {
			return 1 if ($r_min < $c->{r});
			return 1 if ($r_max > $c->{r});
		}
	}
	return 0 if (defined $limit && --$limit < 0);
	show_commit($c);
	return 1;
}

sub show_commit {
	my $c = shift;
	if ($oneline) {
		my $x = "\n";
		if (my $l = $c->{l}) {
			while ($l->[0] =~ /^\s*$/) { shift @$l }
			$x = $l->[0];
		}
		$l_fmt ||= 'A' . length($c->{r});
		print 'r',pack($l_fmt, $c->{r}),' | ';
		print "$c->{c} | " if $show_commit;
		print $x;
	} else {
		show_commit_normal($c);
	}
}

sub show_commit_changed_paths {
	my ($c) = @_;
	return unless $c->{changed};
	print "Changed paths:\n", @{$c->{changed}};
}

sub show_commit_normal {
	my ($c) = @_;
	print commit_log_separator, "r$c->{r} | ";
	print "$c->{c} | " if $show_commit;
	print "$c->{a} | ", format_svn_date($c->{t_utc}), ' | ';
	my $nr_line = 0;

	if (my $l = $c->{l}) {
		while ($l->[$#$l] eq "\n" && $#$l > 0
		                          && $l->[($#$l - 1)] eq "\n") {
			pop @$l;
		}
		$nr_line = scalar @$l;
		if (!$nr_line) {
			print "1 line\n\n\n";
		} else {
			if ($nr_line == 1) {
				$nr_line = '1 line';
			} else {
				$nr_line .= ' lines';
			}
			print $nr_line, "\n";
			show_commit_changed_paths($c);
			print "\n";
			print $_ foreach @$l;
		}
	} else {
		print "1 line\n";
		show_commit_changed_paths($c);
		print "\n";

	}
	foreach my $x (qw/raw stat diff/) {
		if ($c->{$x}) {
			print "\n";
			print $_ foreach @{$c->{$x}}
		}
	}
}

sub cmd_show_log {
	my (@args) = @_;
	my ($r_min, $r_max);
	my $r_last = -1; # prevent dupes
	set_local_timezone();
	if (defined $::_revision) {
		if ($::_revision =~ /^(\d+):(\d+)$/) {
			($r_min, $r_max) = ($1, $2);
		} elsif ($::_revision =~ /^\d+$/) {
			$r_min = $r_max = $::_revision;
		} else {
			fatal "-r$::_revision is not supported, use ",
				"standard 'git log' arguments instead";
		}
	}

	config_pager();
	@args = git_svn_log_cmd($r_min, $r_max, @args);
	if (!@args) {
		print commit_log_separator unless $incremental || $oneline;
		return;
	}
	my $log = command_output_pipe(@args);
	run_pager();
	my (@k, $c, $d, $stat);
	my $esc_color = qr/(?:\033\[(?:(?:\d+;)*\d*)?m)*/;
	while (<$log>) {
		if (/^${esc_color}commit (?:- )?($::sha1_short)/o) {
			my $cmt = $1;
			if ($c && cmt_showable($c) && $c->{r} != $r_last) {
				$r_last = $c->{r};
				process_commit($c, $r_min, $r_max, \@k) or
								goto out;
			}
			$d = undef;
			$c = { c => $cmt };
		} elsif (/^${esc_color}author (.+) (\d+) ([\-\+]?\d+)$/o) {
			get_author_info($c, $1, $2, $3);
		} elsif (/^${esc_color}(?:tree|parent|committer) /o) {
			# ignore
		} elsif (/^${esc_color}:\d{6} \d{6} $::sha1_short/o) {
			push @{$c->{raw}}, $_;
		} elsif (/^${esc_color}[ACRMDT]\t/) {
			# we could add $SVN->{svn_path} here, but that requires
			# remote access at the moment (repo_path_split)...
			s#^(${esc_color})([ACRMDT])\t#$1   $2 #o;
			push @{$c->{changed}}, $_;
		} elsif (/^${esc_color}diff /o) {
			$d = 1;
			push @{$c->{diff}}, $_;
		} elsif ($d) {
			push @{$c->{diff}}, $_;
		} elsif (/^\ .+\ \|\s*\d+\ $esc_color[\+\-]*
		          $esc_color*[\+\-]*$esc_color$/x) {
			$stat = 1;
			push @{$c->{stat}}, $_;
		} elsif ($stat && /^ \d+ files changed, \d+ insertions/) {
			push @{$c->{stat}}, $_;
			$stat = undef;
		} elsif (/^${esc_color}    (git-svn-id:.+)$/o) {
			($c->{url}, $c->{r}, undef) = ::extract_metadata($1);
		} elsif (s/^${esc_color}    //o) {
			push @{$c->{l}}, $_;
		}
	}
	if ($c && defined $c->{r} && $c->{r} != $r_last) {
		$r_last = $c->{r};
		process_commit($c, $r_min, $r_max, \@k);
	}
	if (@k) {
		($r_min, $r_max) = ($r_max, $r_min);
		process_commit($_, $r_min, $r_max) foreach reverse @k;
	}
out:
	close $log;
	print commit_log_separator unless $incremental || $oneline;
}

sub cmd_blame {
	my $path = pop;

	config_pager();
	run_pager();

	my ($fh, $ctx, $rev);

	if ($_git_format) {
		($fh, $ctx) = command_output_pipe('blame', @_, $path);
		while (my $line = <$fh>) {
			if ($line =~ /^\^?([[:xdigit:]]+)\s/) {
				# Uncommitted edits show up as a rev ID of
				# all zeros, which we can't look up with
				# cmt_metadata
				if ($1 !~ /^0+$/) {
					(undef, $rev, undef) =
						::cmt_metadata($1);
					$rev = '0' if (!$rev);
				} else {
					$rev = '0';
				}
				$rev = sprintf('%-10s', $rev);
				$line =~ s/^\^?[[:xdigit:]]+(\s)/$rev$1/;
			}
			print $line;
		}
	} else {
		($fh, $ctx) = command_output_pipe('blame', '-p', @_, 'HEAD',
						  '--', $path);
		my ($sha1);
		my %authors;
		my @buffer;
		my %dsha; #distinct sha keys

		while (my $line = <$fh>) {
			push @buffer, $line;
			if ($line =~ /^([[:xdigit:]]{40})\s\d+\s\d+/) {
				$dsha{$1} = 1;
			}
		}

		my $s2r = ::cmt_sha2rev_batch([keys %dsha]);

		foreach my $line (@buffer) {
			if ($line =~ /^([[:xdigit:]]{40})\s\d+\s\d+/) {
				$rev = $s2r->{$1};
				$rev = '0' if (!$rev)
			}
			elsif ($line =~ /^author (.*)/) {
				$authors{$rev} = $1;
				$authors{$rev} =~ s/\s/_/g;
			}
			elsif ($line =~ /^\t(.*)$/) {
				printf("%6s %10s %s\n", $rev, $authors{$rev}, $1);
			}
		}
	}
	command_close_pipe($fh, $ctx);
}

package Git::SVN::Migration;
# these version numbers do NOT correspond to actual version numbers
# of git nor git-svn.  They are just relative.
#
# v0 layout: .git/$id/info/url, refs/heads/$id-HEAD
#
# v1 layout: .git/$id/info/url, refs/remotes/$id
#
# v2 layout: .git/svn/$id/info/url, refs/remotes/$id
#
# v3 layout: .git/svn/$id, refs/remotes/$id
#            - info/url may remain for backwards compatibility
#            - this is what we migrate up to this layout automatically,
#            - this will be used by git svn init on single branches
# v3.1 layout (auto migrated):
#            - .rev_db => .rev_db.$UUID, .rev_db will remain as a symlink
#              for backwards compatibility
#
# v4 layout: .git/svn/$repo_id/$id, refs/remotes/$repo_id/$id
#            - this is only created for newly multi-init-ed
#              repositories.  Similar in spirit to the
#              --use-separate-remotes option in git-clone (now default)
#            - we do not automatically migrate to this (following
#              the example set by core git)
#
# v5 layout: .rev_db.$UUID => .rev_map.$UUID
#            - newer, more-efficient format that uses 24-bytes per record
#              with no filler space.
#            - use xxd -c24 < .rev_map.$UUID to view and debug
#            - This is a one-way migration, repositories updated to the
#              new format will not be able to use old git-svn without
#              rebuilding the .rev_db.  Rebuilding the rev_db is not
#              possible if noMetadata or useSvmProps are set; but should
#              be no problem for users that use the (sensible) defaults.
use strict;
use warnings;
use Carp qw/croak/;
use File::Path qw/mkpath/;
use File::Basename qw/dirname basename/;
use vars qw/$_minimize/;

sub migrate_from_v0 {
	my $git_dir = $ENV{GIT_DIR};
	return undef unless -d $git_dir;
	my ($fh, $ctx) = command_output_pipe(qw/rev-parse --symbolic --all/);
	my $migrated = 0;
	while (<$fh>) {
		chomp;
		my ($id, $orig_ref) = ($_, $_);
		next unless $id =~ s#^refs/heads/(.+)-HEAD$#$1#;
		next unless -f "$git_dir/$id/info/url";
		my $new_ref = "refs/remotes/$id";
		if (::verify_ref("$new_ref^0")) {
			print STDERR "W: $orig_ref is probably an old ",
			             "branch used by an ancient version of ",
				     "git-svn.\n",
				     "However, $new_ref also exists.\n",
				     "We will not be able ",
				     "to use this branch until this ",
				     "ambiguity is resolved.\n";
			next;
		}
		print STDERR "Migrating from v0 layout...\n" if !$migrated;
		print STDERR "Renaming ref: $orig_ref => $new_ref\n";
		command_noisy('update-ref', $new_ref, $orig_ref);
		command_noisy('update-ref', '-d', $orig_ref, $orig_ref);
		$migrated++;
	}
	command_close_pipe($fh, $ctx);
	print STDERR "Done migrating from v0 layout...\n" if $migrated;
	$migrated;
}

sub migrate_from_v1 {
	my $git_dir = $ENV{GIT_DIR};
	my $migrated = 0;
	return $migrated unless -d $git_dir;
	my $svn_dir = "$git_dir/svn";

	# just in case somebody used 'svn' as their $id at some point...
	return $migrated if -d $svn_dir && ! -f "$svn_dir/info/url";

	print STDERR "Migrating from a git-svn v1 layout...\n";
	mkpath([$svn_dir]);
	print STDERR "Data from a previous version of git-svn exists, but\n\t",
	             "$svn_dir\n\t(required for this version ",
	             "($::VERSION) of git-svn) does not exist.\n";
	my ($fh, $ctx) = command_output_pipe(qw/rev-parse --symbolic --all/);
	while (<$fh>) {
		my $x = $_;
		next unless $x =~ s#^refs/remotes/##;
		chomp $x;
		next unless -f "$git_dir/$x/info/url";
		my $u = eval { ::file_to_s("$git_dir/$x/info/url") };
		next unless $u;
		my $dn = dirname("$git_dir/svn/$x");
		mkpath([$dn]) unless -d $dn;
		if ($x eq 'svn') { # they used 'svn' as GIT_SVN_ID:
			mkpath(["$git_dir/svn/svn"]);
			print STDERR " - $git_dir/$x/info => ",
			                "$git_dir/svn/$x/info\n";
			rename "$git_dir/$x/info", "$git_dir/svn/$x/info" or
			       croak "$!: $x";
			# don't worry too much about these, they probably
			# don't exist with repos this old (save for index,
			# and we can easily regenerate that)
			foreach my $f (qw/unhandled.log index .rev_db/) {
				rename "$git_dir/$x/$f", "$git_dir/svn/$x/$f";
			}
		} else {
			print STDERR " - $git_dir/$x => $git_dir/svn/$x\n";
			rename "$git_dir/$x", "$git_dir/svn/$x" or
			       croak "$!: $x";
		}
		$migrated++;
	}
	command_close_pipe($fh, $ctx);
	print STDERR "Done migrating from a git-svn v1 layout\n";
	$migrated;
}

sub read_old_urls {
	my ($l_map, $pfx, $path) = @_;
	my @dir;
	foreach (<$path/*>) {
		if (-r "$_/info/url") {
			$pfx .= '/' if $pfx && $pfx !~ m!/$!;
			my $ref_id = $pfx . basename $_;
			my $url = ::file_to_s("$_/info/url");
			$l_map->{$ref_id} = $url;
		} elsif (-d $_) {
			push @dir, $_;
		}
	}
	foreach (@dir) {
		my $x = $_;
		$x =~ s!^\Q$ENV{GIT_DIR}\E/svn/!!o;
		read_old_urls($l_map, $x, $_);
	}
}

sub migrate_from_v2 {
	my @cfg = command(qw/config -l/);
	return if grep /^svn-remote\..+\.url=/, @cfg;
	my %l_map;
	read_old_urls(\%l_map, '', "$ENV{GIT_DIR}/svn");
	my $migrated = 0;

	foreach my $ref_id (sort keys %l_map) {
		eval { Git::SVN->init($l_map{$ref_id}, '', undef, $ref_id) };
		if ($@) {
			Git::SVN->init($l_map{$ref_id}, '', $ref_id, $ref_id);
		}
		$migrated++;
	}
	$migrated;
}

sub minimize_connections {
	my $r = Git::SVN::read_all_remotes();
	my $new_urls = {};
	my $root_repos = {};
	foreach my $repo_id (keys %$r) {
		my $url = $r->{$repo_id}->{url} or next;
		my $fetch = $r->{$repo_id}->{fetch} or next;
		my $ra = Git::SVN::Ra->new($url);

		# skip existing cases where we already connect to the root
		if (($ra->{url} eq $ra->{repos_root}) ||
		    ($ra->{repos_root} eq $repo_id)) {
			$root_repos->{$ra->{url}} = $repo_id;
			next;
		}

		my $root_ra = Git::SVN::Ra->new($ra->{repos_root});
		my $root_path = $ra->{url};
		$root_path =~ s#^\Q$ra->{repos_root}\E(/|$)##;
		foreach my $path (keys %$fetch) {
			my $ref_id = $fetch->{$path};
			my $gs = Git::SVN->new($ref_id, $repo_id, $path);

			# make sure we can read when connecting to
			# a higher level of a repository
			my ($last_rev, undef) = $gs->last_rev_commit;
			if (!defined $last_rev) {
				$last_rev = eval {
					$root_ra->get_latest_revnum;
				};
				next if $@;
			}
			my $new = $root_path;
			$new .= length $path ? "/$path" : '';
			eval {
				$root_ra->get_log([$new], $last_rev, $last_rev,
			                          0, 0, 1, sub { });
			};
			next if $@;
			$new_urls->{$ra->{repos_root}}->{$new} =
			        { ref_id => $ref_id,
				  old_repo_id => $repo_id,
				  old_path => $path };
		}
	}

	my @emptied;
	foreach my $url (keys %$new_urls) {
		# see if we can re-use an existing [svn-remote "repo_id"]
		# instead of creating a(n ugly) new section:
		my $repo_id = $root_repos->{$url} || $url;

		my $fetch = $new_urls->{$url};
		foreach my $path (keys %$fetch) {
			my $x = $fetch->{$path};
			Git::SVN->init($url, $path, $repo_id, $x->{ref_id});
			my $pfx = "svn-remote.$x->{old_repo_id}";

			my $old_fetch = quotemeta("$x->{old_path}:".
			                          "$x->{ref_id}");
			command_noisy(qw/config --unset/,
			              "$pfx.fetch", '^'. $old_fetch . '$');
			delete $r->{$x->{old_repo_id}}->
			       {fetch}->{$x->{old_path}};
			if (!keys %{$r->{$x->{old_repo_id}}->{fetch}}) {
				command_noisy(qw/config --unset/,
				              "$pfx.url");
				push @emptied, $x->{old_repo_id}
			}
		}
	}
	if (@emptied) {
		my $file = $ENV{GIT_CONFIG} || "$ENV{GIT_DIR}/config";
		print STDERR <<EOF;
The following [svn-remote] sections in your config file ($file) are empty
and can be safely removed:
EOF
		print STDERR "[svn-remote \"$_\"]\n" foreach @emptied;
	}
}

sub migration_check {
	migrate_from_v0();
	migrate_from_v1();
	migrate_from_v2();
	minimize_connections() if $_minimize;
}

package Git::IndexInfo;
use strict;
use warnings;
use Git qw/command_input_pipe command_close_pipe/;

sub new {
	my ($class) = @_;
	my ($gui, $ctx) = command_input_pipe(qw/update-index -z --index-info/);
	bless { gui => $gui, ctx => $ctx, nr => 0}, $class;
}

sub remove {
	my ($self, $path) = @_;
	if (print { $self->{gui} } '0 ', 0 x 40, "\t", $path, "\0") {
		return ++$self->{nr};
	}
	undef;
}

sub update {
	my ($self, $mode, $hash, $path) = @_;
	if (print { $self->{gui} } $mode, ' ', $hash, "\t", $path, "\0") {
		return ++$self->{nr};
	}
	undef;
}

sub DESTROY {
	my ($self) = @_;
	command_close_pipe($self->{gui}, $self->{ctx});
}

package Git::SVN::GlobSpec;
use strict;
use warnings;

sub new {
	my ($class, $glob, $pattern_ok) = @_;
	my $re = $glob;
	$re =~ s!/+$!!g; # no need for trailing slashes
	my (@left, @right, @patterns);
	my $state = "left";
	my $die_msg = "Only one set of wildcard directories " .
				"(e.g. '*' or '*/*/*') is supported: '$glob'\n";
	for my $part (split(m|/|, $glob)) {
		if ($part =~ /\*/ && $part ne "*") {
			die "Invalid pattern in '$glob': $part\n";
		} elsif ($pattern_ok && $part =~ /[{}]/ &&
			 $part !~ /^\{[^{}]+\}/) {
			die "Invalid pattern in '$glob': $part\n";
		}
		if ($part eq "*") {
			die $die_msg if $state eq "right";
			$state = "pattern";
			push(@patterns, "[^/]*");
		} elsif ($pattern_ok && $part =~ /^\{(.*)\}$/) {
			die $die_msg if $state eq "right";
			$state = "pattern";
			my $p = quotemeta($1);
			$p =~ s/\\,/|/g;
			push(@patterns, "(?:$p)");
		} else {
			if ($state eq "left") {
				push(@left, $part);
			} else {
				push(@right, $part);
				$state = "right";
			}
		}
	}
	my $depth = @patterns;
	if ($depth == 0) {
		die "One '*' is needed in glob: '$glob'\n";
	}
	my $left = join('/', @left);
	my $right = join('/', @right);
	$re = join('/', @patterns);
	$re = join('\/',
		   grep(length, quotemeta($left), "($re)", quotemeta($right)));
	my $left_re = qr/^\/\Q$left\E(\/|$)/;
	bless { left => $left, right => $right, left_regex => $left_re,
	        regex => qr/$re/, glob => $glob, depth => $depth }, $class;
}

sub full_path {
	my ($self, $path) = @_;
	return (length $self->{left} ? "$self->{left}/" : '') .
	       $path . (length $self->{right} ? "/$self->{right}" : '');
}

__END__

Data structures:


$remotes = { # returned by read_all_remotes()
	'svn' => {
		# svn-remote.svn.url=https://svn.musicpd.org
		url => 'https://svn.musicpd.org',
		# svn-remote.svn.fetch=mpd/trunk:trunk
		fetch => {
			'mpd/trunk' => 'trunk',
		},
		# svn-remote.svn.tags=mpd/tags/*:tags/*
		tags => {
			path => {
				left => 'mpd/tags',
				right => '',
				regex => qr!mpd/tags/([^/]+)$!,
				glob => 'tags/*',
			},
			ref => {
				left => 'tags',
				right => '',
				regex => qr!tags/([^/]+)$!,
				glob => 'tags/*',
			},
		}
	}
};

$log_entry hashref as returned by libsvn_log_entry()
{
	log => 'whitespace-formatted log entry
',						# trailing newline is preserved
	revision => '8',			# integer
	date => '2004-02-24T17:01:44.108345Z',	# commit date
	author => 'committer name'
};


# this is generated by generate_diff();
@mods = array of diff-index line hashes, each element represents one line
	of diff-index output

diff-index line ($m hash)
{
	mode_a => first column of diff-index output, no leading ':',
	mode_b => second column of diff-index output,
	sha1_b => sha1sum of the final blob,
	chg => change type [MCRADT],
	file_a => original file name of a file (iff chg is 'C' or 'R')
	file_b => new/current file name of a file (any chg)
}
;

# retval of read_url_paths{,_all}();
$l_map = {
	# repository root url
	'https://svn.musicpd.org' => {
		# repository path 		# GIT_SVN_ID
		'mpd/trunk'		=>	'trunk',
		'mpd/tags/0.11.5'	=>	'tags/0.11.5',
	},
}

Notes:
	I don't trust the each() function on unless I created %hash myself
	because the internal iterator may not have started at base.
