#!/usr/bin/perl
use strict;
use warnings;
use DynaLoader;
my ($framework, $action) = @ARGV;
die "Invalid action\n" unless defined $action && ($action eq 'catalog' || $action eq 'selected');
my $handle = DynaLoader::dl_load_file("$framework/MediaRemoteAdapter", 0) or die "Cannot load media helper\n";
my $symbol = DynaLoader::dl_find_symbol($handle, "jack_$action") or die "Missing media entry point\n";
DynaLoader::dl_install_xsub('main::run_jack', $symbol);
run_jack();
