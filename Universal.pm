package Syntax::Highlight::Universal;

use strict;
use vars qw($VERSION @ISA);

@ISA = qw(DynaLoader);
$VERSION = '0.3';

my $load = 1;

my $defaultConfig = 1;
my @configQueue;
my $precompiledConfig;
my $type = 0;

my $cacheDir;
my $cachePrefixLen = 2;

my $result;
my $curRegions;
my @schemeStack;
my $curLine;
my $curLineNum;
my $pos;
my $curCacheDir;
my $curCacheFile;

sub initParsing
{
	my ($lines, $type) = @_;

	if (defined $cacheDir)
	{
		my $text = join("\n", $type, @$lines);

		require Digest::MD5;
		$curCacheFile = Digest::MD5::md5_hex($text);
		$curCacheDir = $cacheDir;
		if ($cachePrefixLen > 0 && $cachePrefixLen < 32)
		{
			$curCacheDir .= '/' . substr($curCacheFile, 0, $cachePrefixLen);
			substr($curCacheFile, 0, $cachePrefixLen) = '';
		}
		if (open(local *FILE, "$curCacheDir/$curCacheFile"))
		{
			binmode(FILE);
			local $/;
			return <FILE>;
		}
	}
	else
	{
		undef $curCacheDir;
		undef $curCacheFile;
	}

	$result = '';
	$curRegions = [];
	@schemeStack = ();
	$curLineNum = 0;
	return;
}

sub addRegion
{
	my ($lines, $lineNum, $sx, $ex, $regions) = @_;

	return if $sx == $ex || $#$regions < 0;

	_setCurLineNum($lines, $lineNum) unless $lineNum == $curLineNum;

	my $class = join(' ', @$regions);
	$class =~ s/:/_/g;

	_insertRegion({
		sx => $sx,
		ex => $ex,
		start => qq(<span class="$class">),
		end => qq(</span>),
	});
}

sub enterScheme
{
	my ($lines, $lineNum, $sx, $ex, $scheme, $regions) = @_;

	return if $#$regions < 0;
	
	_setCurLineNum($lines, $lineNum) unless $lineNum == $curLineNum;

	my $class = join(' ', @$regions);
	$class =~ s/:/_/g;

	my $region = {
		sx => $sx,
		ex => length($lines->[$lineNum]),
		start => qq(<span class="$class">),
		end => '',
	};

	_insertRegion($region);
	push @schemeStack, $region;
}

sub leaveScheme
{
	my ($lines, $lineNum, $sx, $ex, $scheme, $regions) = @_;

	return if $#$regions < 0;

	_setCurLineNum($lines, $lineNum) unless $lineNum == $curLineNum;

	if ($#schemeStack >= 0 && defined $schemeStack[-1])
	{
		$schemeStack[-1]{ex} = $ex;
		$schemeStack[-1]{end} = qq(</span>);
	}
	else
	{
		_insertRegion({
			sx => 0,
			ex => $ex,
			start => '',
			end => qq(</span>),
		});
	}

	pop @schemeStack;
}

sub finalizeParsing
{
	my ($lines, $type) = @_;

	_setCurLineNum($lines, $#$lines + 1);
	$result .= '</span>' x ($#schemeStack + 1);

	if (defined $curCacheDir)
	{
		mkdir($curCacheDir, 0700) unless -d $curCacheDir;
		if (open(local* FILE, ">$curCacheDir/$curCacheFile"))
		{
			binmode(FILE);
			print FILE $result;
		}
	}

	return $result;
}

sub _setCurLineNum
{
	my($lines, $lineNum) = @_;

	for (; $curLineNum < $lineNum; $curLineNum++)
	{
		$curLine = $lines->[$curLineNum];
		_finalizeLine();
		$result .= "\n";
		$curRegions = [];
		undef $_ foreach @schemeStack;
	}
}

sub _insertRegion
{
	my($region) = @_;
	$region->{children} = [];

	my $list = $curRegions;
	my $found = 0;
	for (my $i = 0; $i <= $#$list; $i++)
	{
		my $cmp = $list->[$i];

		if ($cmp->{sx} >= $region->{ex})
		{
			splice(@$list, $i, 0, $region);
			$found = 1;
			last;
		}
		elsif ($cmp->{sx} <= $region->{sx} && $cmp->{ex} >= $region->{ex})
		{
			$list = $cmp->{children};
			$i = -1;
		}
		elsif ($cmp->{sx} >= $region->{sx} && $cmp->{ex} <= $region->{ex})
		{
			my $j = 1;
			$j++ while $i+$j <= $#$list && $list->[$i+$j]{sx} >= $region->{sx} && $list->[$i+$j]{ex} <= $region->{ex};
			push @{$region->{children}}, splice(@$list, $i, $j, $region);
			$found = 1;
			last;
		}
		elsif (($cmp->{sx} < $region->{sx} && $cmp->{ex} > $region->{sx}) || ($cmp->{sx} < $region->{ex} && $cmp->{ex} > $region->{ex}))
		{
			# We don't allow intersecting regions yet
			return;
		}
	}
	push @$list, $region unless $found;
}

sub _finalizeLine
{
	my($pos, $ex, $list) = @_;
	$pos = 0 unless defined $pos;
	$ex = length($curLine) unless defined $ex;
	$list = $curRegions unless defined $list;

	foreach my $region (@$list)
	{
		$result .= _toHTML(substr($curLine, $pos, $region->{sx} - $pos)) if $region->{sx} > $pos;
		$result .= $region->{start};
		_finalizeLine($region->{sx}, $region->{ex}, $region->{children}) if $region->{sx} < $region->{ex};
		$result .= $region->{end};
		$pos = $region->{ex};
	}
	$result .= _toHTML(substr($curLine, $pos, $ex - $pos)) if $ex > $pos;
}

sub _toHTML
{
	my $text = shift;

	my %translate = ('&' => '&amp;', '<' => '&lt;', '>' => '&gt;', '"' => '&quot;');
	$text =~ s/([&<>\"])/$translate{$1}/g;
	return $text;
}

sub new
{
	my $class = shift;

	return bless({}, $class);
}

sub setPrecompiledConfig
{
	shift;
	my $file = shift;
	$file = 'precompiled.hrcc' unless defined $file;

	die "Can't load precompiled config file after a plain config file has been loaded" if $type == 2;
	die "Can't load more than one precompiled config file" if $type == 1;

	$defaultConfig = 0;
	$type = 1;

	my @dirs = ('');
	push @dirs, map {"$_/Syntax/Highlight/Universal/"} @INC;

	my $found = 0;
	foreach my $dir (@dirs)
	{
		if (-f "$dir$file")
		{
			$precompiledConfig = "$dir$file";
			$found = 1;
			last;
		}
	}
	die "Could not find config file $file" unless $found;
}

sub addConfig
{
	shift;
	die "Can't load plain config files after a precompiled config file has been loaded" if $type == 1;

	$defaultConfig = 0;
	$type = 2;

	my @dirs = ('');
	push @dirs, map {"$_/Syntax/Highlight/Universal/"} @INC;

	foreach my $file (@_)
	{
		my $found = 0;
		foreach my $dir (@dirs)
		{
			if (-f "$dir$file")
			{
				push @configQueue, "$dir$file";
				$found = 1;
				last;
			}
		}
		die "Could not find config file $file" unless $found;
	}
}

sub setCacheDir
{
	shift;
	$cacheDir = shift;
}

sub setCachePrefixLen
{
	shift;
	$cachePrefixLen = int(shift);
}

sub _init
{
	if ($load)
	{
		require DynaLoader;
		__PACKAGE__->bootstrap;
		$load = 0;
	}

	addConfig('hrc/proto.hrc') if $defaultConfig;
	if (defined $precompiledConfig)
	{
		_deserialize($precompiledConfig);
		undef $precompiledConfig;
	}
	else
	{
		_addConfig($_) foreach @configQueue;
		@configQueue = ();
	}
}

sub highlight
{
	shift;
	my ($type, $text, $callbacks) = @_;

	unless (defined($callbacks) && UNIVERSAL::isa($callbacks, 'HASH'))
	{
		$callbacks = {
			initParsing => \&initParsing,
			addRegion => \&addRegion,
			enterScheme => \&enterScheme,
			leaveScheme => \&leaveScheme,
			finalizeParsing => \&finalizeParsing,
		};
	}
	$text = [split(/\r?\n/, $text)] unless UNIVERSAL::isa($text, 'ARRAY');

	my $result;
	$result = $callbacks->{initParsing}->($text, $type) if exists($callbacks->{initParsing});
	return $result if defined $result;

	_init;
	_highlight($type, $text, $callbacks);

	$result = $callbacks->{finalizeParsing}->($text, $type) if exists($callbacks->{finalizeParsing});
	return $result;
}

sub precompile
{
	shift;
	my $file = shift;

	_init;
	_serialize($file);
}

1;
__END__

=head1 NAME

Syntax::Highlight::Universal - Syntax highlighting module based on the Colorer library

=head1 SYNOPSIS

	use Syntax::Highlight::Universal;
	my $highlighter = Syntax::Highlight::Universal->new;

	$highlighter->addConfig("hrc/proto.hrc");
	$highlighter->setPrecompiledConfig("precompiled.hrcc");
	$highlighter->setCacheDir("/tmp/highlighter");
	$highlighter->setCachePrefixLen(2);

	my $result = $highlighter->highlight("perl", "printf 'Hello, World!'");

	my $callbacks = {
		initParsing => \&myInitHandler,
		addRegion => \&myRegionHandler,
		enterScheme => \&mySchemeStartHandler,
		leaveScheme => \&mySchemeEndHandler,
		finalizeParsing => \&myFinalizeHandler,
	};
	$highlighter->highlight("perl", "printf 'Hello, World!'", $callbacks);

	$highlighter->precompile("precompiled.hrcc");

=head1 ABSTRACT

This module can process text of any format and produce a syntax
highlighted version of it. The default output format is (X)HTML,
custom formats are also possible. It uses parts of the Colorer library
and supports its HRC configuration files. Configuration files for about
100 file formats are included.

=head1 DESCRIPTION

Syntax::Highlight::Universal doesn't export any functions. You can call
its methods either statically or through an object. The result will be the
same but we will use the latter here as it is the more convenient of the
two.

=head2 Creating a new object

	my $highlighter = Syntax::Highlight::Universal->new;

This will create a new object and bind it to the
C<Syntax::Highlight::Universal> namespace. It can be used to call the methods
of this module in a more convenient way. However, this object has no other
meaning, any configuration changes performed through it will have global
effect.

=head2 Processing text

	my $result = $highlighter->highlight(FORMAT, TEXT, [CALLBACKS]);

This will process the text and produce its syntax highlighted variant, by
default in (X)HTML format.

=over 4

=item FORMAT

This must be one of the formats defined in the configuration file. Usually
it will be one of the following:

	c, cpp, asm, perl, java, idl, pascal, csharp, jsnet,
	vbnet, forth, fortran, vbasic, html, css, html-css,
	svg-css, jsp, php, php-body, xhtml-trans, xhtml-strict,
	xhtml-frameset, asp.vb, asp.js, asp.ps, svg, coldfusion,
	jScript, actionscript, vbScript, xml, dtd, xslt,
	xmlschema, relaxng, xlink, clarion, Clipper, foxpro,
	sqlj, paradox, sql, mysql, Batch, shell, apache, config,
	hrc, hrd, delphiform, javacc, javaProperties, lex, yacc,
	makefile, regedit, resources, TeX, dcl, vrml, rarscript,
	nsi, iss, isScripts, c1c, ada, abap4, AutoIt, awk, dssp,
	adsp, Baan, cobol, cache, eiffel, icon, lisp, matlab,
	modula2, picasm, python, rexx, ruby, sml, ocaml, tcltk,
	sicstusProlog, turboProlog, verilog, vhdl, z80, asm80,
	filesbbs, diff, messages, text, default

=item TEXT

The text to be processed, either as a string or as a reference to a list of
lines (without the newline symbols)

=item CALLBACKS

Optional parameter, a hash reference defining the functions to
be called during parsing of the text (all hash entries are optional).
If this parameter is omitted it will be set to:

	{
		initParsing => \&Syntax::Highlight::Universal::initParsing,
		addRegion => \&Syntax::Highlight::Universal::addRegion,
		enterScheme => \&Syntax::Highlight::Universal::enterScheme,
		leaveScheme => \&Syntax::Highlight::Universal::leaveScheme,
		finalizeParsing => \&Syntax::Highlight::Universal::finalizeParsing,
	}

The callbacks are explained in detail L<below|/Callbacks>.

=item Return value

If the callbacks parameter is omitted, the return value is the syntax
highlighted version of the text in (X)HTML. The regions are translated into
C<E<lt>spanE<gt>> elements, the class attribute is set to the region's name.
The resulting code can be formatted via CSS.

If the default callback functions are overridden, either the return value
of the C<initParsing> or C<finalizeParsing> callback will be returned,
depending on whether C<initParsing> returns a value.

=back

=head2 Importing configuration files

	$highlighter->addConfig(FILE, ...);

This method imports a list of configuration files. They replace
C<hrc/proto.hrc> that is used by default.

=over 4

=item FILE

The file containing a list of file format definitions. If this file
can't be found in the current directory, the module will look for it in
its library directory as well. For information on the format
of the file, see HRC reference (http://colorer.sf.net/hrc-ref/).

=back

=head2 Precompiling configuration files

	$highlighter->precompile(FILE);

Parsing HRC files takes a while, resulting in a high time demand for processing
of the first text. In order to speed it up, configuration files can be
preprocessed into a binary file. The time to load the configuration will be
reduced by a factor 5-10, memory usage also decreases. However, the binary
file can't be changed and has to be rebuilt every time changes are
made on the HRC files. Furthermore it isn't platform independent and should
be always rebuilt when moving to another server/another operating system.

This method will process the current configuration and write it into a file in
a binary format. It might take some time, the whole configuration needs to
be loaded into memory.

C<make test> will create a precompiled configuration file C<precompiled.hrcc>.
It can be copied into the library directory of the module and used instead of
the HRC configuration.

=over 4

=item FILE

Name of the file to be written

=back

=head2 Loading a precompiled configuration

	$highlighter->setPrecompiledConfig([FILE]);

This method will load a precompiled configuration file. It can
only be called once, combining several files isn't yet supported.
L<addConfig|/Importing configuration files> can't be used either
when using a precompiled configuration.

=over 4

=item FILE

The precompiled configuration file. If this file can't be found in the
current directory, the module will look for it in its library directory
as well. You can omit this parameter, the file C<precompiled.hrcc> will
be loaded then.

=back

=head2 Setting a cache directory

	$highlighter->setCacheDir(DIR);

This method will enable caching of the results and define a cache
directory. Then, a text will only go through the complete processing
if there is no file for it in the cache directory. Syntax
highlighting takes time, therefore caching is generally a good idea.
However, it won't be of much use if the texts processed are always
different. Other problem is the cleaning of the cache directory. The
cache files are never removed, this has to be done separately, e.g.
with a cron script emptying the cache directory every two days.

Caching only works if the default callback functions are used.

=over 4

=item DIR

The cache directory. The module might create subdirectories, depending
on the prefix length setting (see
L<setCachePrefixLen|/Setting cache prefix length>).

=back

=head2 Setting cache prefix length


	$highlighter->setCachePrefixLen(LENGTH);

This method defines how many characters should be used for subdirectories
of the cache directory.

=over 4

=item LENGTH

If this parameter is zero, the files will be put directly into the cache
directory. Otherwise subdirectories with names of specified length (the
first characters of the file name) will be created to allow faster access
to large amounts of files. The file name will contain the remaining of the
32 characters. Default value is 2, meaning that there can be up to 256
subdirectories.

=back

=head2 Callbacks

All callback functions get a reference to the list of text lines as their
first parameter. The other parameters differ:

=head3 initParsing(LINES, FORMAT)

=head3 finalizeParsing(LINES, FORMAT)

These functions are called before/after the parsing of the text. If
C<initParsing> returns a value, parsing will be aborted and
L<highlight|/Processing text> will return this value. This can be used for
caching to return cached results before even starting parsing.
Otherwise parsing will proceed normally and the return value of
C<finalizeParsing> will be returned.

=over 4

=item FORMAT

The text format, same as the parameter to L<highlight|/Processing text>

=back

=head3 addRegion(LINES, LINENO, START, END, REGIONS)

Called whenever a new region inside a line is identified.

=over 4

=item LINENO

Line number, zero-based. This parameter can only increase, Colorer
never goes back to a previous line.

=item START

The position of region start within the line

=item END

The position of region end (the first character not belonging to the region)
within the line

=item REGIONS

Reference to a list of region names. First in the list is the name of the
actual region found, the names of its parent regions (more generally defined
regions whose meaning includes the currently found) are following.

=back

=head3 enterScheme(LINES, LINENO, START, END, SCHEME, REGIONS)

=head3 leaveScheme(LINES, LINENO, START, END, SCHEME, REGIONS)

Called whenever the start/end of a scheme is found. The parameters
are all the same as for C<addRegion>, except:

=over 4

=item SCHEME

Name of the scheme found

=back

=back

=head1 SEE ALSO

=over 4

=item Colorer homepage

http://colorer.sf.net/

=item HRC reference

http://colorer.sf.net/hrc-ref/

=back

=head1 AUTHOR

Wladimir Palant, E<lt>palant@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2005 by Wladimir Palant

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.1 or,
at your option, any later version of Perl 5 you may have available.


=cut
