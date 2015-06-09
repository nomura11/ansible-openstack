#!/usr/bin/perl

use strict;
use warnings;

my $usage = "Usage: merge-ini.pl <.ini file modifications>\n";

my $modfile = shift or die $usage;
my %configs;
my $cursec;

$cursec = "";
open(MODFILE, "$modfile") or die "open $modfile";
while (<MODFILE>) {
	if (/^\s*$/) { # ignore empty lines
		next;
	} elsif (/^\[([^\]]*)\]/) { # section header
		$cursec = $1;
		if (not $configs{$cursec}) {
			$configs{$cursec} = [];
		}
		next;
	}
	elsif (/^([a-zA-Z0-9:_-]+)\s*=\s*(.*)$/) { # key-value
		chomp($2);
		push(@{$configs{$cursec}}, [$1,$2]);
	} elsif (/^\.\.\./) { # skip '...'
		next;
	} else { # comments, etc.
		push(@{$configs{$cursec}}, [$_]);
	}
}
close(MODFILE);

# -------------------------------------------------------------

sub flush_section {
	my ($section) = @_;
	foreach my $e (@{$configs{$section}}) {
		if ($#{$e} == 1 && $e->[0]) {
			print "$e->[0] = $e->[1]\n";
		} elsif ($#{$e} == 0) {
			print "$e->[0]";
		}
	}
	$configs{$section} = [];
}

sub pop_config {
	my ($section, $key) = @_;

	foreach my $e (@{$configs{$section}}) {
		if ($#{$e} == 1 && $e->[0] eq $key) {
			$e->[0] = "";
			return $e->[1];
		}
	}

	return 0;
}

$cursec = "";
while (<STDIN>) {
	if (/^\[([^\]]*)\]/) {
		if ($configs{$cursec}) {
			flush_section($cursec);
		}
		$cursec = $1;
		print;
	} elsif (/^([a-zA-Z0-9:_-]+)\s*=\s*(.*)$/) {
		my $key = $1;
		my $newval = pop_config($cursec, $key);
		if ($newval) {
			print "$key = $newval\n";
		} else {
			print;
		}
	} else {
		print;
	}
}
if ($configs{$cursec}) {
	flush_section($cursec);
}

foreach my $section (keys %configs) {
	if (@{$configs{$section}}) {
		print "[$section]\n";
		flush_section($section);
	}
}
