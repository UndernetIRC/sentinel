#!/usr/bin/env perl

# Sentinel updater

use strict;
use warnings;
use LWP::Simple;
use File::Path qw( make_path rmtree );
use File::Copy;

my %conf;
my $files;
my $gitraw = 'https://raw.githubusercontent.com/UndernetIRC/sentinel/main/src';

$SIG{CHLD} = 'DEFAULT';

# Checking arguments
if ( $ARGV[0] )
{
	if ( $ARGV[0] =~ /^\// )
	{
		if ( ! -r "$ARGV[0]" )
                {
                        print "$ARGV[0] doesnt exist.\n";
			exit;
		}
	}
	else
	{
                print "configuration file must have an ABSOLUTE PATH!\n";
                print "example: $0 /home/sentinel/etc/sentinel.conf\n";
		exit;
        }
}
else
{
	print "syntax : $0 /path/to/configuration/file.conf\n";
	print "example: $0 /home/sentinel/etc/sentinel.conf\n";
	exit;
}

# Fetch name of config file
my $config = ( split '/', $ARGV[0] )[ -1 ];

# Loading configuration, including PATH
load_config();

# Creating directories
make_path($conf{path} . "/.update/bin/");
make_path($conf{path} . "/.update/etc/");

# Files to fetch
push(@{$files},"/bin/sentinel.pl");
push(@{$files},"/etc/sample.conf");

# Fetching updates and running config merge
fetch_update();

# Apply updates
apply_updates();
clean_up();

print("Done.\n");
exit(0);

# Fetch update from GitHub
sub fetch_update
{
	foreach(@{$files})
	{
		my $url = $gitraw . $_;
		my $file = $conf{path} . "/.update" . $_;
		my $rc = getstore($url, $file);

		if ( is_error($rc) )
		{ die "Download of $url failed: $rc"; }
		print "Downloaded $url -- saved to: $file\n";
	}

	merge_config();
}

# Load config variables
sub load_config
{
	open(CONFIG,$ARGV[0]) or die "Unable to load existing configuration file: $!";
	while(<CONFIG>)
	{
		chop;

		if ( /^((\w|_)+)(	| )+(.*)?/ )
		{
			my $name = $1;
			my $value = $4;
			$name =~ tr/[A-Z]/[a-z]/;

			if ( $name eq 'permitip' )
			{
				push(@{$conf{permitip}},$value);
			}
			elsif ( $name eq 'admin' )
			{
				push(@{$conf{admin}},$value);
			}
			elsif ( $name eq 'rnameexcept' )
			{
				push(@{$conf{rnameexcept}},$value);
			}
			elsif ( $name eq 'ipexcept' )
			{
				push(@{$conf{ipexcept}},$value);
			}
			elsif ( $name eq 'pushuser' )
			{
				push(@{$conf{pushuser}},$value);
			}
			elsif ( $name eq 'pushnetsplit' )
			{
				my ($server,$priority) = split(/ /,$value,2);
				$conf{pushnetsplit}{$server} = $priority;
			}
			elsif ( $name eq 'dcclisten' )
			{
				if ( $value =~ /^(\d+\.\d+\.\d+\.\d+|)$/ )
				{
					push(@{$conf{dcclisten}},$value);
				}
			}
			else
			{
				$conf{$name}=$value;
			}
		}
	}
	close(CONFIG);
	print "Existing configuration loaded.\n";
}

sub merge_config
{
	my %skip;
	my $newentries;

	open(NEWCONFIG,">" . $conf{path} . "/.update/etc/" . $config . ".new") or die "Unable to write to new configuration file: $!";
	open(DISTCONFIG,$conf{path} . "/.update/etc/sample.conf") or die "Unable to open dist configuration file: $!";
	while(<DISTCONFIG>)
	{
		if ( /^(#|\s)/ )
		{
			print NEWCONFIG "$_";
		}
		elsif ( /^((\w|_)+)(	| )+(.*)?/ )
		{
			my $name = $1;
			my $value = $4;
			$name =~ tr/[A-Z]/[a-z]/;

			if ( !exists $conf{$name} )
			{
				print NEWCONFIG "$_";
				push(@{$newentries},$name);
			}
			elsif ( $name eq 'version' )
			{
				print NEWCONFIG "$_";
			}
			elsif ( $name eq 'permitip' )
			{
				if ( $skip{$name} ) { next; }
				$skip{$name} = 1;

				foreach ( @{$conf{permitip}} )
				{ print NEWCONFIG "PERMITIP	$_\n"; }
			}
			elsif ( $name eq 'admin' )
			{
				if ( $skip{$name} ) { next; }
				$skip{$name} = 1;

				foreach ( @{$conf{admin}} )
				{ print NEWCONFIG "ADMIN		$_\n"; }
			}
			elsif ( $name eq 'rnameexcept' )
			{
				if ( $skip{$name} ) { next; }
				$skip{$name} = 1;

				foreach ( @{$conf{rnameexcept}} )
				{ print NEWCONFIG "RNAMEEXCEPT	$_\n"; }
			}
			elsif ( $name eq 'ipexcept' )
			{
				if ( $skip{$name} ) { next; }
				$skip{$name} = 1;

				foreach ( @{$conf{ipexcept}} )
				{ print NEWCONFIG "IPEXCEPT	$_\n"; }
			}
			elsif ( $name eq 'pushuser' )
			{
				if ( $skip{$name} ) { next; }
				$skip{$name} = 1;

				foreach ( @{$conf{pushuser}} )
				{ print NEWCONFIG "PUSHUSER	$_\n"; }
			}
			elsif ( $name eq 'pushnetsplit' )
			{
				if ( $skip{$name} ) { next; }
				$skip{$name} = 1;

				foreach ( keys %{$conf{pushnetsplit}} )
				{ print NEWCONFIG "PUSHNETSPLIT	$_ $conf{pushnetsplit}{$_}\n"; }
			}
			elsif ( $name eq 'dcclisten' )
			{
				if ( $skip{$name} ) { next; }
				$skip{$name} = 1;

				foreach ( @{$conf{dcclisten}} )
				{ print NEWCONFIG "DCCLISTEN	$_\n"; }
			}
			else
			{
				if ( $conf{$name} eq '' && $value eq '' )
				{
					# ignore
				}
				elsif ( $conf{$name} eq '' )
				{
					s/\Q$value\E//;
				}
				else
				{
					s/\Q$value\E/$conf{$name}/;
				}

				print NEWCONFIG "$_";
			}
		}
		else
		{
			print "Unknown config line: $_";
		}
	}
	close(CONFIG);
	close(NEWCONFIG);
	print "Configuration merged to: $conf{path}/.update/etc/$config.new\n";

	if ( $newentries ) 
	{ print "New configuration entries - check values: @{$newentries}\n"; }
}

sub apply_updates
{
	# Make backup folder
	my $time = time;

	make_path($conf{path} . "/.backup/" . $time . "/bin/");
	make_path($conf{path} . "/.backup/" . $time . "/etc/");

	# Transfer new files and make backup of existing files
	foreach(@{$files})
	{
		copy($conf{path} . $_, $conf{path} . "/.backup/" . $time . $_);
		print("Copying " . $conf{path} . $_ . " --> " . $conf{path} . "/.backup/" . $time . $_ . "\n");
		copy($conf{path} . "/.update" . $_, $conf{path} . $_);
		print("Copying " . $conf{path} . "/.update" . $_ . " --> " . $conf{path} . $_ . "\n");
	}

	# Transfer config file
	copy($ARGV[0], $conf{path} . "/.backup/" . $time . "/etc/" . $config);
	print("Copying original configuration file " . $ARGV[0] . " --> " . $conf{path} . "/.backup/" . $time . "/" . $config . "\n");
	copy($conf{path} . "/.update/etc/" . $config . ".new", $ARGV[0]);
	print("Copying merged configuration file " . $conf{path} . "/.update/etc/" . $config . ".new --> " . $ARGV[0] . "\n");
}

sub clean_up
{
	rmtree($conf{path} . "/.update/");
	print("Finished cleaning up temp files\n");
}
