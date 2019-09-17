#!/usr/bin/env perl

# git-changelog-smudge.pl -- smudge a ChangeLog file to include tag contents
# Copyright (C) 2017,2019 Kyle J. McKay <mackyle@gmail.com>
# All rights reserved

# License GPL v2

# Version 1.0,1

use 5.008;
use strict;
use warnings;

use File::Basename;
use Getopt::Long qw(:DEFAULT GetOptionsFromString);
use Pod::Usage;
use Encode;
use IPC::Open2;
use POSIX qw(strftime);

close(DATA) if fileno(DATA);
exit(&main(@ARGV));

my $VERSION;
BEGIN {$VERSION = \"1.0.1"}

my $debug;
BEGIN {$debug = 0}

my %truevals;
BEGIN {%truevals = (
	true => 1,
	yes => 1,
	on => 1
)}

my $encoder;
BEGIN {
	$encoder = Encode::find_encoding('Windows-1252') ||
		   Encode::find_encoding('ISO-8859-1')
		or die "failed to load ISO-8859-1 encoder\n";
}

sub to_utf8 {
	my $str = shift;
	return undef unless defined $str;
	my $result;
	if (Encode::is_utf8($str) || utf8::decode($str)) {
		$result = $str;
	} else {
		$result = $encoder->decode($str, Encode::FB_DEFAULT);
	}
	utf8::encode($result);
	return $result;
}

sub git_pipe {
	my $result = open(my $fd, "-|", "git", @_);
	return $result ? $fd : undef;	
}

sub get_git {
	my $result;
	my $fd = git_pipe(@_);
	if (defined($fd)) {
		local $/;
		$result = <$fd>;
		$result =~ s/(?:\r\n|[\r\n])$//;
		close($fd);
	}
	return $result;
}

sub git_pipe2 {
	my ($fdr, $fdw);
	my $pid = open2($fdr, $fdw, "git", @_);
	if (defined($pid)) {
		return ($pid, $fdr, $fdw);
	} else {
		return undef;
	}
}

sub git_close {
	my $pid = shift;
	if (defined($pid)) {
		waitpid($pid, 0);
		return ($? & 0x7f) ? (0x80 | ($? & 0x7f)) : (($? >> 8) & 0x7f);
	} else {
		return undef;
	}
}

sub split_tagger {
	my $g = shift;
	defined($g) or return ();
	my ($n, $t, $o);
	($g, $o) = ($1, $2) if $g =~ /^(.*?)\s*([-+]\d\d\d\d)$/;
	($g, $t) = ($1, 0 + $2) if $g =~ /^(.*?)\s*([-+]?\d+)$/;
	($n, $g) = ($1, $2), $n =~ s/\s+$// if $g =~ /^\s*([^<]*)(.*)$/;
	$g =~ s/\s+$//;
	$g =~ s/^<+//;
	$g =~ s/>+$//;
	return ($n, $g, $t, $o);
}

sub parse_tag {
	my $to = to_utf8(shift);
	defined($to) or return ();
	$to =~ s/\r\n?/\n/gs;
	$to .= "\n\n";
	my $sep = index($to, "\n\n");
	my @hdrs = split(/\n+/, substr($to, 0, $sep));
	my $body = substr($to, $sep + 2);
	my %fields = ();
	while (my ($k, $v) = split(" ", pop(@hdrs)||'', 2)) {
		return () unless defined($k) && defined($v) && $v ne "";
		$fields{lc($k)} = $v;
	}
	exists $fields{object} && exists $fields{type} && exists $fields{tag} or
		return ();
	if (!exists($fields{tagger}) && $fields{type} eq "commit") {
		# Pull up the committer as the tagger
		# This can probably can only happen in the Git repo itself
		my $commit = get_git("cat-file", "commit", $fields{object});
		defined($commit) or return ();
		$commit =~ s/\r\n?/\n/gs;
		$commit .= "\n\n";
		my @chdrs = split(/\n+/, substr($commit, 0, index($commit, "\n\n")));
		while (my ($k, $v) = split(" ", pop(@chdrs)||'', 2)) {
			next unless defined($k) && defined($v) && $v ne "";
			$fields{tagger} = $v, last if lc($k) eq "committer";
		}
	}
	exists $fields{tagger} or return ();
	my ($n, $e, $t, $o) = split_tagger($fields{tagger});
	$fields{name} = $n if defined($n);
	$fields{email} = $e if defined($e);
	$fields{seconds} = $t if defined($t);
	if (defined($o) && $o =~ /^([-+])(\d\d)(\d\d)$/) {
		my $sign = $1 eq "-" ? -1 : 1;
		my $hours = 0 + $2;
		my $mins = 0 + $3;
		if ($hours <= 12 && $mins <= 59) {
			$fields{offset} = $sign * ($hours * 3600 + $mins);
		}
	}
	defined($fields{name}) && defined($fields{email}) &&
		defined($fields{seconds}) && defined($fields{offset}) or
		return ();
	$body =~ s/(?:^|\n)-----BEGIN .*$//s;
	$body =~ s/^\s+//s;
	$body =~ s/\s+$//s;
	$fields{body} = $body;
	return %fields;
}

sub sq {
	my $n = shift;
	$n =~ s/\047/\047\\\047\047/gs;
	$n =~ s/-(-+)/"\047-".("\\-" x length($1))."\047"/gse;
	$n = "'".$n."'";
	$n =~ s/^\047\047//s;
	$n =~ s/\047\047$//s;
	$n ne "" or $n = "''";
	$n = $1 if $n =~ m{^\047([:/A-Za-z_][:/A-Za-z_0-9.-]*)\047$}s;
	return $n;
}

sub main {
	local *ARGV = \@_;
	my $smudging;
	my $name = basename($0);
	my @optlist;
	my $fn;
	my $nsexit = 0;

	Getopt::Long::Configure('bundling');
	@optlist = (
		'smudge' => \$smudging,
		'no-smudge' => sub {$smudging = 0},
	);
	GetOptions(
		'help|h' => sub {pod2usage(-verbose => 2, -exitval => 0)},
		@optlist
	) && $#ARGV == 0 or pod2usage(-exitval => 2);
	$fn = $ARGV[0];
	if (!defined($smudging)) {
		# Check for changelog.smudge setting
		my $auto = get_git(qw(config --get changelog.smudge));
		my $impauto = 1;
		if (defined($auto)) {
			$auto = lc($auto);
			if ($truevals{$auto} || ($auto =~ /^[-+]?\d+$/ && ($auto=0+$auto))) {
				$auto = 1;
				$impauto = 0;
			} else {
				if ($auto ne "bare") {
					$impauto = 0 if $auto eq "0";
					$auto = 0;
				} else {
					$impauto = 0;
					my $bare = get_git(qw(rev-parse --is-bare-repository));
					if (defined($bare) && $bare eq "true") {
						$auto = 1;
					} else {
						$auto = 0;
					}
				}
			}
		}
		$smudging = 1 if $auto;
		if (!defined($smudging)) {
			my $pcmd = qx(ps -o comm=,args= -p @{[getppid]}) || "";
			if ($pcmd =~ /\bgit\b.+\barchive\b/) {
				my $imp = $impauto ? " implicit" : "";
				warn "$name:$imp non-smudging of \"$fn\" under git archive detected!\n";
				$nsexit = 64;
			}
		}
	}
	my $line1;
	binmode(STDIN);
	binmode(STDOUT);
	if ($smudging) {
		# Get the shebang line (or XML comment)
		$line1 = <STDIN>;
		defined($line1) or die "$name: missing first line\n";
		if ($line1 =~ /^<!--/) {
			# Avoid double smudging
			$smudging = 0;
		} else {
			if ($line1 =~ m,^#!\s*/usr/bin/env\s+(?:\w+=\w*\s+)*(?:git-changelog-smudge\.pl)((?:\s.*)?)$, ||
			    $line1 =~ m,^#!\s*(?:/(?:\w+/)*)?(?:git-changelog-smudge\.pl)((?:\s.*)?)$,
			    ) {
				my $sbopts = $1;
				my $features;
				$sbopts =~ s/^\s+//;
				GetOptionsFromString($sbopts, @optlist,
					'features|f=i' => \$features
				) or die "$name: invalid #! options: $sbopts\n";
				# This version only understands --features=0 which means "base"
				!$features or die "$name: invalid --features=$features option\n";
			} else {
				die "$name: missing #! first line\n";
			}
		}
	}
	if (!$smudging) {
		print $line1 if defined($line1);
		my $buf;
		while (read(STDIN, $buf, 32768)) {
			print $buf;
		}
		exit $nsexit;
	}
	my @tags = ();
	while (<STDIN>) {
		s/^\s+//;
		s/\s+$//;
		next if $_ eq "" || /^#/;
		s/\s+?#.*$//;
		my ($t, $d) = split(" ", $_ ,2);
		defined($d) && $d ne "" or $d = $t;
		my $f = 0;
		$f = $1 eq "~" ? 1 : 2 if $d =~ s/^([\~\^])//;
		push(@tags, [$t, $d, $f]);
	}
	my %tags = ();
	my ($cfcmd, $cfr, $cfw) = git_pipe2(qw(cat-file --batch));
	defined($cfcmd) or die "$name: git cat-file --batch failed\n";
	foreach (@tags) {
		my ($t, $d, $f) = @$_;
		!$debug or print STDERR "Processing: $t [$f]$d\n";
		printf $cfw "refs/tags/%s^{tag}\n", $t;
		my (undef, $ot, $os) = split(" ", <$cfr>);
		!$debug or print STDERR "  Type: $ot  Length: $os\n";
		defined($ot) or die "$name: git cat-file --batch failed on tag: $t\n";
		$ot eq "tag" or die "$name: no such annotated/signed tag: $t\n";
		defined($os) && $os =~ /^\d+$/ && $os >= 64 or
			die "$name: bad objectsize for tag \"$t\": $os\n";
		my $tagbuf;
		my $cnt = read($cfr, $tagbuf, $os + 1);
		defined($cnt) && $cnt == $os + 1 or
			die "$name: failed to read tag \"$t\" object body\n";
		$debug < 2 or print STDERR "TAG DATA:\n$tagbuf";
		my %tagfields = parse_tag($tagbuf);
		defined($tagfields{body}) && defined($tagfields{seconds}) && defined($tagfields{offset}) or
			die "$name: corrupt/invalid tag \"$t\" header fields\n";
		BEGIN {!$debug or eval "use Data::Dumper"}
		!$debug or print STDERR Dumper(\%tagfields);
		print STDERR "DATE: ", strftime("%Y-%m-%d %H:%M:%S %z (%a)",
			gmtime($tagfields{seconds} + $tagfields{offset})), "\n"
			if $debug && defined($tagfields{seconds}) && defined($tagfields{offset});
		my $msg = $tagfields{body};
		my $title;
		if ($f >= 2) {
			$title = $d;
		} else {
			# Unwrap a leading "H1"
			$msg =~ s/^(?:=+[ \t]*\n)?[ \t]*([^\n]+?)[ \t]*\n=+[ \t]*\n+/$1\n\n/s or
			$msg =~ s/^#(?=[^#\s]|[ \t]+\S)[ \t]*([^\n]+?)[ \t]*\n+/$1\n\n/s;
			$msg .= "\n\n";
			my $tlen = index($msg, "\n\n");
			if ($f) {
				$title = $d;
			} else {
				$title = substr($msg, 0, $tlen);
				$title =~ s/[ \t]*\n+[ \t]*/ /gs;
				$title =~ s/\s+$//;
				# Add tag prefix if missing
				$title = $d . " - " . $title unless $title =~ /\Q$d\E/i;
				$title =~ s/(?<!\s)[.:;,]$// if length($title) > 1;
			}
			$msg = substr($msg, $tlen + 2);
			$msg =~ s/\s+$//s;
		}
		# Add blank lines after shortlog headers unless ``` is found
		$msg =~ s/(?:(?<=\n)|\A)(\S[^\n]*? \([1-9]\d*\):\n)    /$1\n    /gs unless
			$msg =~ m"(?:(?<=\n)|\A)\`\`\`+[ \t]*(?:[\w.+-]+[ \t]*)?\n"s;
		$msg = "\n" . $msg unless $msg eq "" || $msg =~ /^\n/s;
		$msg .= "\n" unless $msg eq "" || $msg =~ /\n$/s;
		my $td = strftime("%Y-%m-%d", gmtime($tagfields{seconds} + $tagfields{offset}));
		$tags{$t} = $title . "\n" . ("=" x length($title)) . "\n" .
			$td . "\n" . ("-" x length($td)) . "\n" .
			$msg;
		!$debug or print STDERR $tags{$t};
	}
	print "<!-- git-changelog-smudge.pl -\\-smudge -\\- ", sq($fn), " -->\n";
	print "\n" unless !@tags;
	print join("\n", map("\n$tags{$$_[0]}", @tags));
	exit 0;
}

__END__

=head1 NAME

git-changelog-smudge.pl - Smudge a ChangeLog file to include tag contents

=head1 SYNOPSIS

git-changelog-smudge.pl [options] <name-of-smudgee>

 Options:
   -h | --help                           detailed instructions
   --smudge                              perform a smudge instead of a cat
   --no-smudge                           perform a cat (default)

 Git Config:
   changelog.smudge                      "true" enables --smudge by default

=head1 OPTIONS

=over 8

=item B<--help>

Print the full description of git-changelog-smudge.pl's options.

=item B<--smudge>

Actually perform the ChangeLog smudge operation on the input.  See the
L</CHANGELOG SMUDGING> section below.  Without this option the input is simply
copied to the output without change.  Overrides a previous --no-smudge option.

=item B<--no-smudge>

Disable any smudge operation and always copy the input to the output.
Overrides a previous --smudge option.

=back

=head1 GIT CONFIG

=over 8

=item B<changelog.smudge>

If the git config option C<changelog.smudge> is set to a "true" boolean value
then the default if neither --smudge nor --no-smudge is given is to do a
--smudge instead of --no-smudge.  If it's set to the special value "bare" then
--smudge will only become the default in a bare repository (provided,
of course, no explicit --smudge or --no-smudge options are present).

=back

=head1 DESCRIPTION

git-changelog-smudge.pl provides a mechanism to translate a simple format
"ChangeLog" file into one containing the contents of zero or more Git tag
comment bodies.

An attempt is made to make the output Markdown compatible so that it can
be formatted very nicely as an HTML document for viewing.

The intent is that this "smudge" filter can be activated when creating an
archive (via C<git archive>) to expand the "ChangeLog" at that time so it's
included fully-expanded in the resulting archive while being maintained in
the working tree and repository in a non-expanded format.

=head1 CHANGELOG SMUDGING

The git-changelog-smudge.pl utility should be used as a Git "smudge" filter
to replace the contents of a "ChangeLog" file that contains only blank lines,
comments and Git tag names with a Markdown-compatible result that expands each
of the tag names to their entire, possibly multiline, tag message.

The expansion occurs as a replacement so that final output will be ordered in
the same order as the tag names are listed in the original "ChangeLog"
document.

Since "git shortlog" output may commonly be included, an attempt is made to
detect such usage and insert the needed blank line after each author name
and count so that the description line(s) end up being recognized as
preformatted text by Markdown.  Note that if any 3-backticks-delimiter lines
are found at all this automagical blank line insertion will be disabled.

Signature data (if present) gets stripped from the end of the message.

A Markdown-style "H1" line will be added unless the beginning of the
message already contains one in which case it will have the tagname
(or display tag name if present) prefixed to it unless it already contains
(case-insensitively) the tag name (display tag name if given).

However, if a display tag name starting with "^" is used it will always become
its own separate leading "H1" line.

If a display tag name starting with "~" is used it will I<entirely replace>
whatever line would have become the "H1" line.

B<Syntax>

The first line of the file must be a shebang style comment line in this form:

	#!/usr/bin/env git-changelog-smudge.pl <optional> <options>

Or alternatively this form:

	#!/any/path/to/git-changelog-smudge.pl <optional> <options>

Or even this form (which is really just a special case of the previous one):

	#!git-changelog-smudge.pl <optional> <options>

where optional whitespace may also be included immediately following the "!" if
desired.

All <optional> <options> will be automatically picked up and appended to the
list of command line options when smudging.  This means they can override
command line options.  If unrecognized options are present an error will
result.  This provides a means to guarantee that archives generated using
"git-changelog-smudge.pl" smudging produce identical results even when
additional formatting options (if there ever are any) are used.  Note that
adding an explicit "--no-smudge" option to the shebang line will always prevent
smudging from taking place!

Each following line of the input file is either a blank line (zero or more
whitespace characters), a comment line (first non-whitespace character is C<#>)
or a tag name line.

Tag name lines consist of optional leading whitespace, a valid, case-sensitive,
Git tag name optionally followed by a display name followed by optional
whitespace and comment (the whitespace is required if a comment is present)
like this:

	tagname[ [^|~]display name][ #comment]

Here is an example "ChangeLog" file:

	# ChangeLog for project foo

	# More recent releases
	v2.2.0 ~Version 2.2
	v2.1.0 ~Version 2.1
	v2.0.2 ~Version 2.0.2
	v2.0.1 ~Version 2.0.1
	v2.0.0 ~Version 2.0 # new world order

	# only include last release of each older series
	v1.9.3 # last of the old world
	v1.8.7
	v1.7.3
	v1.6.1
	v1.5.3 ^Broken 1.5.3 -- do not use # yikes!

In this example there are ten tag names that will be expanded.  They just all
happen to start with "v".  Six of them have alternate display names.  Two of
them have comments on the tag name line and the last one has an exclusive
display name (as well as a comment) and the first five have alternate display
names.  See the above L</CHANGELOG SMUDGING> section for processing details.

Here's another valid example "ChangeLog" file:

	123 funny name
	funny-name-tag # yup
	    #comments can be here too
	    # more comments
	with-#char gotcha

This example contains four tag names, "123", "funny-name-tag" and "with-#char".
Yup, "#" is a valid tag name character as far as Git is concerned.  The astute
reader will have noticed that the third and fourth lines were taken as comment
lines rather than tag lines.  Currently C<git-changelog-smudge.pl> does not
support tag names beginning with "#" as there is no way to "escape" such names
from being treated as comment lines.  Internal "#" characters in tag names work
just fine (as the example demonstrates).

If any invalid or nonexistent tags are detected during "ChangeLog" smudging,
an error message will be spit out to STDERR and a non-zero status code will
result.  Setting the "required" filter option to "true" will cause any Git
smudge operations to fail in that case (the error is reported either way).

B<Testing>

To test the output simply feed the "ChangeLog" to C<git-changelog-smudge.pl> on
its STDIN with the C<--smudge> option like so:

	git-changelog-smudge.pl --smudge ChangeLog < ChangeLog

(Adjust the filename if the "ChangeLog" is not actually stored in "ChangeLog".)

B<Git Configuration>

Two configuration items are required to use "git-changelog-smudge.pl" as a
"smudge" filter:

=over 8

=over 8

=item 1. A "ChangeLog" filter configuration

=item 2. An "attributes" filter assignment

=back

=back

The filter configuration portion may be added to the repository-local config,
the global config or even the system config.

The lines should look something like this:

	[filter "changelog"]
	smudge = git-changelog-smudge.pl %f
	clean = cat
	required

The following Git commands will set up the repository's local config:

	git config filter.changelog.smudge "git-changelog-smudge.pl %f"
	git config filter.changelog.clean cat
	git config filter.changelog.required true

This variation will set up the global config:

	git config --global filter.changelog.smudge "git-changelog-smudge.pl %f"
	git config --global filter.changelog.clean cat
	git config --global filter.changelog.required true

You don't need the repository-local version if you have the global config
version (but it's harmless to have both).  The global makes sense if the
"ChangeLog" filter will be used in multiple repositories, the local config
if its use will be limited to one (or just a handful).

Once the "changelog" filter has been defined, the following line (or similar)
needs to be added to one of the "gitattributes" files:

	/ChangeLog.md	filter=changelog

See the C<git help attributes> information for more details on attributes file
formats.  Of note here is that by starting the pattern with "/" the specified
file name ("ChangeLog.md" in this case) will only match at the top-level.

Here the extension C<.md> is used to reflect the fact that the smudged output
is intended to be Markdown compatible.  Since the source file to be "smudged"
must always be named exactly as shown (if no wildcards are being used) it must
be named exactly "ChangeLog.md" in this case; multiple files can have the
"changelog" filter attribute set on them; wildcard patterns can even be used to
match multiple files (simply omitting the leading "/" will match the specified
filename in any subdirectory as well).

What's important is that the name given with the "filter=" attribute (in this
case "changelog") matches I<exactly> (it I<is> case sensitive) the name used in
the git config file section.  The actual name used does not matter as long as
it's the same in both places.

Note that yes, Virginia, there I<are> big bad global attributes!

This fact may not be immediately apparent from the Git attributes
documentation, but the following will display the full pathname of the default
"global" Git attributes file (which may not actually exist):

	sh -c 'echo "${XDG_CONFIG_HOME:-$HOME/.config}/git/attributes"'

There's also a C<core.attributesfile> setting that may be used to I<replace>
the default location of the global attributes file.  In other words, if the
C<core.attributesfile> value is set, the pathname shown by the above line of
shell code will be I<ignored> (unless, of course, C<core.attributesfile> just
happens to be set to the same value it outputs).

Since the C<core.attributesfile> value can be set in a local repository
configuration file or even using the command line
S<C<-c core.attributesfile=pathname>> option, the actual location of the
"global" attributes file can vary on a repository-by-repository (or even
command-to-command) basis.

The repository-local attributes configuration is available either checked
in to the repository as a C<.gitattributes> file or local to a specific copy
of the repository in its C<$GIT_DIR/info/attributes> file.

For smudging purposes, it does not matter which "attributes" file location is
chosen, but at least one of them must assign the "ChangeLog" filter to at
least one file in order to make use of it.

There are pros and cons to each choice of location, but if others are expected
to be using the "ChangeLog" smudger on one or more files in the repository it
makes sense for the filter assignment to be listed in a C<.gitattributes> file
checked in to the repository.  If use by others is not a concern then using a
global attributes configuration only makes sense if more than one repository
will be "smudging" and they will all have their "ChangeLog" files in the same
relative location using the same name(s).  Otherwise a repository-local
attributes configuration (C<$GIT_DIR/info/attributes>) makes the most sense.

B<Activating the Smudger>

The above configuration will not actually smudge anything!

That is intentional because "git-changelog-smudge.pl" only knows how to
"smudge," it doesn't know how to "clean" (but it will try to notice if it's
already "smudged" and then just copy that to the output in case Git gets
carried away and tries to double-smudge something).

As the "git-changelog-smudge.pl" filter's primary purpose is to be used with
the "git archive" command, the recommended way to activate the "smudger" (once
the required configuration mentioned above has been completed) is like this:

	git -c changelog.smudge=true archive <other> <arguments>

If the "upload-archive" facility has been enabled there's no simple way to
enable "git-changelog-smudge.pl" smudging for remote client archive generation
without also enabling it for local archive generation.

However, it is possible to automatically enable it for only bare repositories
by setting the "changelog.smudge" config variable to "bare" instead of a
boolean.  If remote clients are always served from "bare" repositories (and
with the advent of the "git worktree" command in Git 2.5 that's really no added
space burden anymore) that should suffice.  Provided, of course, that allowing
a remote client to cause "git-changelog-smudge.pl" to run at all is acceptable
in the first place.

=head1 LICENSE

=over

=item git-changelog-smudge.pl version 1.0.0

=item Copyright (C) 2017 Kyle J. McKay.

=item All rights reserved.

=item License GPLv2: GNU GPL version 2 only.

=item L<https://www.gnu.org/licenses/gpl-2.0.html>

=item This is free software: you are free to change and redistribute it.

=item There is NO WARRANTY, to the extent permitted by law.

=back

=head1 SEE ALSO

=over 8

=item B<Markdown>

A suitable formatter for Markdown (along with syntax descriptions etc.) can
be found at:

=over 8

L<https://repo.or.cz/markdown.git>

=back

=back

=head1 AUTHOR

Kyle J. McKay

=cut
