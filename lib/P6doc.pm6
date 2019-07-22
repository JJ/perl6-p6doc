use P6doc::Utils;

use Perl6::Documentable;
use Perl6::Documentable::Processing;

use JSON::Fast;
use Pod::To::Text;

use Path::Finder;


unit module P6doc;

constant DEBUG      = %*ENV<P6DOC_DEBUG>;
constant INTERACT   = %*ENV<P6DOC_INTERACT>;

# die with printing a backtrace
my class X::P6doc is Exception {
	has $.message;
	multi method gist(X::P6doc:D:) {
		self.message;
	}
}

sub module-names(Str $modulename) returns Seq is export {
	return $modulename.split('::').join('/') X~ <.pm .pm6 .pod .pod6>;
}

sub locate-module(Str $modulename) is export {
	my @candidates = search-paths() X~ </ Type/ Language/> X~ module-names($modulename).list;
	DEBUG and warn :@candidates.perl;
	my $m = @candidates.first: *.IO.f;

	unless $m.defined {
		# not "core" pod now try for panda or zef installed module
		$m = locate-curli-module($modulename);
	}

	unless $m.defined {
		my $message = join "\n",
		"Cannot locate $modulename in any of the following paths:",
		search-paths.map({"  $_"});
		X::P6doc.new(:$message).throw;
	}

	return $m;
}

sub is-pod(IO::Path $p) returns Bool {
	if not open($p).lines.grep( /^'=' | '#|' | '#='/ ) {
		return False
	} else {
		return True
	}
}

sub get-docs(IO::Path $path, :$section, :$package is copy) returns Str is export {
	if not $path.IO.e {
		fail "File not found: $path";
	}

	if (is-pod($path)) eq False {
		fail "No Pod found in $path";
	}

	my $proc = Proc.new: :err, :out, :merge;

	if $section.defined {
		%*ENV<PERL6_POD_HEADING> = $section;
		my $i = findbin().add('../lib');

		$proc.spawn($*EXECUTABLE, "-I$i", "--doc=SectionFilter", $path);
		return $proc.out.slurp: :close;
	} else {
		$proc.spawn($*EXECUTABLE, "--doc", $path);
		return $proc.out.slurp: :close;
	}
}

sub show-docs(Str $docstr, :$no-pager) is export {
	# show-docs will only handle paging and formatting, if desired
	X::NYI.new( feature => "sub {&?ROUTINE.name}",
				did-you-mean => "get-docs",
				workaround => "Please be patient." ).throw;
}

sub disambiguate-f-search($docee, %data) is export {
	my %found;

	for <routine method sub> -> $pref {
		my $ndocee = $pref ~ " " ~ $docee;

		if %data{$ndocee} {
            my @types = %data{$ndocee}.values>>.Str.grep({ $^v ~~ /^ 'Type' / });
			@types = [gather @types.deepmap(*.take)].unique.list;
			@types.=grep({!/$pref/});
			%found{$ndocee}.push: @types X~ $docee;
        }
	}

	my $final-docee;
	my $total-found = %found.values.map( *.elems ).sum;
	if ! $total-found {
		fail "No documentation found for a routine named '$docee'";
	} elsif $total-found == 1 {
		$final-docee = %found.values[0];
	} else {
		say "We have multiple matches for '$docee'\n";

		my %options;
		for %found.keys -> $key {
			%options{$key}.push: %found{$key};
		}
		my @opts = %options.values.map({ @($^a) });

		# 's' => Type::Supply.grep, ... | and we specifically want the %found values,
		#                               | not the presentation-versions in %options
		if INTERACT {
			my $total-elems = %found.values.map( +* ).sum;
			if +%found.keys < $total-elems {
				my @prefixes = (1..$total-elems) X~ ") ";
				say "\t" ~ ( @prefixes Z~ @opts ).join("\n\t") ~ "\n";
			} else {
				say "\t" ~ @opts.join("\n\t") ~ "\n";
			}
			$final-docee = prompt-with-options(%options, %found);
		} else {
			say "\t" ~ @opts.join("\n\t") ~ "\n";
			exit 1;
		}
	}

	return $final-docee;
}

sub prompt-with-options(%options, %found) {
	my $final-docee;

	my %prefixes = do for %options.kv -> $k,@o { @o.map(*.comb[0].lc) X=> %found{$k} };

	if %prefixes.values.grep( -> @o { +@o > 1 } ) {
		my (%indexes,$base-idx);
		$base-idx = 0;
		for %options.kv -> $k,@o {
			%indexes.push: @o>>.map({ ++$base-idx }) Z=> @(%found{$k});
		}
		%prefixes = %indexes;
	}

	my $prompt-text = "Narrow your choice? ({ %prefixes.keys.sort.join(', ') }, or !{ '/' ~ 'q' if !%prefixes<q> } to quit): ";

	while prompt($prompt-text).words -> $word {
		if $word  ~~ '!' or ($word ~~ 'q' and !%prefixes<q>) {
			exit 1;
		} elsif $word ~~ /:i $<choice> = [ @(%prefixes.keys) ] / {
			$final-docee = %prefixes{ $<choice>.lc };
			last;
		} else {
			say "$word doesn't seem to apply here.\n";
			next;
		}
	}

	return $final-docee;
}

sub locate-curli-module($module) {
	my $cu = try $*REPO.need(CompUnit::DependencySpecification.new(:short-name($module)));
	unless $cu.DEFINITE {
		fail "No such type '$module'";
		#exit 1;
	}
	return ~ $cu.repo.prefix.child('sources/' ~ $cu.repo-id);
}

# see: Zef::Client.list-installed()
# Eventually replace with CURI.installed()
# https://github.com/rakudo/rakudo/blob/8d0fa6616bab6436eab870b512056afdf5880e08/src/core/CompUnit/Repository/Installable.pm#L21
sub list-installed() is export {
	my @curs       = $*REPO.repo-chain.grep(*.?prefix.?e);
	my @repo-dirs  = @curs>>.prefix;
	my @dist-dirs  = |@repo-dirs.map(*.child('dist')).grep(*.e);
	my @dist-files = |@dist-dirs.map(*.IO.dir.grep(*.IO.f).Slip);

	my $dists := gather for @dist-files -> $file {
		if try { Distribution.new( |%(from-json($file.IO.slurp)) ) } -> $dist {
			my $cur = @curs.first: {.prefix eq $file.parent.parent}
			my $dist-with-prefix = $dist but role :: { has $.repo-prefix = $cur.prefix };
			take $dist-with-prefix;
		}
	}
}

###
###
###

#| Create a Perl6::Documentable::Registry for the given directory
sub compose-registry(
	$topdir,
	@dirs = ['Type'] ) returns Perl6::Documentable::Registry
{
	my $registry = process-pod-collection(
		cache => False,
		verbose => False,
		topdir => $topdir,
		dirs => @dirs
	);
	$registry.compose;

	return $registry
}

#| Receive a list of pod files and process them, return a list of Perl6::Documentable objects
sub process-pods(IO::Path @files) returns Array[Perl6::Documentable] {
	...
}

#| Create a list of relevant files in a given directory (recursively, if necessary)
sub type-list-files(Str $query, $dir) is export {
	my @results;
	my $searchname;

	my $query-depth = 0;

	my $finder = Path::Finder;

	if $query.contains('::') {
		# Add one to the number of elements to receive the correct depth
		$query-depth = $query.split('::').elems + 1;
		$searchname = $query.split('::').tail;

	} else {
		$searchname = $query;
	}

	$finder = $finder.depth($query-depth);
	$finder = $finder.name("{$searchname}.pod6");

	for $finder.in($dir, :file) -> $file {
		@results.push($file);
	}

	return @results;
}

#| Search for a single Routine/Method/Subroutine, e.g. `split`
sub routine-search(
	Str $routine,
	:@topdirs = get-doc-locations() ) returns Array[Perl6::Documentable] is export
{
	my Perl6::Documentable @results;

	for @topdirs -> $td {
		my $registry = compose-registry($td);

		# The result from `.lookup` is containerized, thus we use `.list`
		for $registry.lookup($routine, :by<name>).list -> $r {
			@results.append: $r;
		}
	}

	return @results
}

#| Search for documentation in association with a type, e.g. `Map`, `Map.new`
sub type-search(
	Str $type,
	Str :$routine?,
	:@topdirs = get-doc-locations() ) returns Array[Perl6::Documentable] is export
{
	my Perl6::Documentable @results;

	for @topdirs -> $td {
		my $registry = compose-registry($td);

		for $registry.lookup($type, :by<name>).list -> $r {
			@results.append: $r;
		}
	}

	@results = @results.grep: *.subkinds.contains('class');

	# If we provided a routine to search for, we now look for it inside the found classes
	# and return an array of those results instead
	if defined $routine {
		my Perl6::Documentable @filtered-results;

		for @results -> $rs {
			# Loop definitions, look for searched routine
			# `.defs` contains a list of Perl6::Documentables defined inside
			# a given object.
			for $rs.defs -> $def {
				if $def.name eq $routine {
					@filtered-results.push($def);
				}
			}
		}

		return @filtered-results;
	}

	return @results
}

#|
sub show-f-search-results(Perl6::Documentable @results) is export {
	if @results.elems == 1 {
		say pod2text(@results.first.pod);
	} elsif @results.elems < 1 {
		say "No matches";
	} else {
		say 'Multiple matches:';
		for @results -> $r {
			# `.origin.name` gives us the correct name of the pod our
			# documentation is defined in originally
			say "    {$r.origin.name} {$r.subkinds} {$r.name}";
		}
	}
}

#|
sub show-t-search-results(Perl6::Documentable @results) is export {
	if @results.elems == 1 {
		say pod2text(@results.first.pod);
	} elsif @results.elems < 1 {
		say "No matches";
	} else {
		say 'Multiple matches:';
		for @results -> $r {
			say "    {$r.subkinds} {$r.name}";
		}
	}
}

# vim: expandtab shiftwidth=4 ft=perl6
