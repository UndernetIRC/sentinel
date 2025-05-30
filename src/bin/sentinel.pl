#!/usr/bin/env perl
#
#    =====================================================================
#    |                   SPALEWARE LICENSE (Revision 0.1)                |
#    |-------------------------------------------------------------------|
#    | This file is part of a package called "GenEthic" and is           |
#    | licensed under SPALEWARE. You may freely modify and distribute    |
#    | this package or parts of it. But you MUST keep the SPALWARE       |
#    | license in it!                                                    |
#    |                                                                   |
#    =====================================================================
#
# You might want to enable debug, which
# will send you the IRC traffic to STDOUT
#
my $debug = 0;
#
######################################################
#                                                    #
# There's nothing to change below this line.         #
#                                                    #
######################################################
#
#

use strict;
use warnings;
use IO::Socket;
use POSIX "setsid";
use POSIX ":sys_wait_h";
use Time::Local;
use Time::HiRes qw (sleep);
use File::Basename;
use File::Copy;
use File::Path qw(make_path);
use File::Pid;
use File::chmod qw(chmod);
use LWP::UserAgent;
use LWP::Protocol::https;
use LWP::Simple;
use English qw(-no_match_vars);
use Net::CIDR;

$|=1;

my $version = '1.2';
my $revision = 2025042000;

$SIG{PIPE} = "IGNORE";
$SIG{CHLD} = sub { while ( waitpid(-1, WNOHANG) > 0 ) { } };

my %server;
my %data;
my $config;
my $CMD;
my %cap;

if ( $ARGV[0] )
{
	if ( $ARGV[0] =~ /^\// ) { $config = $ARGV[0]; }
	else { $config = "$ENV{PWD}/$ARGV[0]"; }
}

my %conf = load_config($config);

if ( !%conf )
{
	exit 1;
}

logmsg("entering main loop");

if ( !$debug )
{
	daemonize();
}

$server{lastcon} = time - 61;

# Setting timers
$data{time}{statsc} = time - ( ( ( $conf{pollinterval} - 30 ) / 6 ) * 6 );
$data{time}{statsv} = time - ( ( ( $conf{pollinterval} - 30 ) / 6 ) * 5 );
$data{time}{statsl} = time - ( ( ( $conf{pollinterval} - 30 ) / 6 ) * 4 );
$data{time}{lusers} = time - ( ( ( $conf{pollinterval} - 30 ) / 6 ) * 3 );
$data{time}{who} = time - ( ( ( $conf{pollinterval} - 30 ) / 6 ) * 2 );
$data{time}{rping} = time - ( ( ( $conf{pollinterval} - 30 ) / 6 ) * 1 );
$data{time}{ison} = 30;
$data{time}{account} = 0;
$data{time}{lastcheck} = 0;
$data{time}{checkupdate} = 0;
$data{time}{connexitclean} = 0;
$data{time}{fw} = 0;

# Initialising counters
$data{fw}{cycles} = 0;
$data{notice}{cycles} = 0;

while(1)
{
	if ( !$server{socket} )
	{
		if ( $server{lastcon} < time - 60 )
		{
			logmsg("trying to connect");
			if ( connect_irc() )
			{
				logmsg("connected");
				if ( $conf{serverpass} )
				{
					queuemsg(1,"PASS $conf{serverpass}");
				}
				queuemsg(1,"CAP LS");
				queuemsg(1,"USER $conf{ident} . . :$conf{rname}");
				$data{nick} = get_nick();
				queuemsg(1,"NICK $data{nick}");
			}
			else
			{
				logmsg("connection failed");
			}
			$server{lastcon} = time;
		}
		elsif ( !(($server{lastcon} - time + 60) % 5) )
		{
			logmsg("Retrying to connect in " . ( $server{lastcon} - time + 60 ) . " sec");
		}
	}
	else
	{
		$data{status}{report} = time + $conf{pollinterval};
		while($server{socket})
		{
			read_irc();

			foreach(@{$server{in}})
			{
				$server{lastin} = time;
				irc_loop(shift(@{$server{in}}));
			}

			if ( $data{rfs} )
			{
				timed_events();
			}

			write_irc();

			if ( time - $server{lastin} > $conf{timeout} )
			{
				logmsg("ERROR: Server timed out");
				shutdown($server{socket},2);
				undef %server;
				undef %data;
			}
		}
	}
	sleep(1);
}

sub check_update()
{
	my $data = get('https://raw.githubusercontent.com/UndernetIRC/sentinel/main/.version');
	open my $url_fh, '<', \$data or return -1;
	return -1 unless defined $data;

	my $uversion;
	my $urevision;
	my $dependencies;
	my @missing;

	while (<$url_fh>)
	{
		if ( /^version ((\d|\.)+)/ )
		{
			$uversion = $1;
		}
		elsif ( /^revision (\d+)/ )
		{
			$urevision = $1;
		}
		elsif ( /^dependencies (.*)/ )
		{
			$dependencies = $1;
		}
	}

	logdeb("Most recent information on github is version: $uversion revision: $urevision");

	foreach (split(/ /,$dependencies))
	{
		if ( `/usr/bin/env perl -M$_ -e 'print "1";' 2>&1` ne '1' )
		{
			push(@missing,$_);
		}
	}

	if ( @missing )
	{
		logdeb("Missing dependencies: @missing");
		return "-2 @missing";
	}

	if ( $urevision > $revision )
	{
		logmsg("Update available (version: $uversion -- revision: $urevision)");
		return "Update available (version: " . chr(2) . $uversion . chr(2) . " -- revision: " . chr(2) . $urevision . chr(2) . ") running " . chr(2) . "v" . $version . chr(2) . " (rev. " . chr(2) . $revision . chr(2) . ")";
	}

	return 0;
}

sub do_restart
{
	my $execpath = $conf{path} . "/bin/" . ( split '/', $PROGRAM_NAME )[ -1 ];
	$execpath =~ s/\/\//\//;

	my $configpath = $conf{path} . "/etc/" . ( split '/', $config )[ -1 ];
	$configpath =~ s/\/\//\//;

	if ( system($execpath . " " . $configpath) )
	{
		logmsg("Error when starting new process: $!");
		return 0;
	}
	else
	{
		my $sock = $server{socket};
		print $sock "QUIT :" . $_[0] . "\r\n";
		sleep(5);

		logmsg("Successfully started Sentinel.");
		kill 9, $$;
	}
}

sub apply_update
{
	my $retme = 1;

	# Preparing
	make_path($conf{path} . "/.update/");
	my $file = $conf{path} . "/.update/update.pl";

	# Downloading update script
	my $rc = getstore('https://raw.githubusercontent.com/UndernetIRC/sentinel/main/tools/update.pl', $file);
	if ( is_error($rc) )
	{ 
		logmsg("Error when downloading update script: $rc");
		return 0;
	}
	chmod("+x", $file);

	# Running update script.
	my $chpid;
	if ( !defined($chpid = fork()) )
	{
		$retme = 0;
		return 0;
	}
	elsif ( $chpid == 0 )
	{
		if ( system($file . " " . $config) )
		{
			logmsg("Error when running update script: $!");
			$retme = 0;
		}
		else
		{
			logmsg("Successfully updated Sentinel.");
			exit;
		}
	}

	return $retme;
}

sub is_admin
{
	my $account = $data{clients}{$_[0]}{account};

	foreach ( @{$conf{admins}} )
	{
		if ( $_ eq $account )
		{ return 1; }
	}

	if ( !@{$conf{admins}} )
	{ return 1; }

	return 0;
}

sub send_warning
{
	queuemsg(2,$CMD . chr(3) . 4 . chr(2) . "WARNING" . chr(2) . ": " . $_[0] . chr(3));

	open(WARNFILE,">>$conf{path}/var/warnings.txt");
	print WARNFILE time . " " . $_[0] . "\n";
	close(WARNFILE);
}

sub push_notify
{
	if ( !$conf{pushenable} || $_[0] =~ /off/i ) { return 0; }

	my $priority = $_[0];
	my $message;

	if ( $conf{multimode} ) {
		$message .= "[$data{nick}] ";
	}

	$message .= $_[1];
	my $tag;

	my $url = 'https://api.pushover.net/1/messages.json';
	my $ua = LWP::UserAgent->new();
	$ua->timeout(10);

	foreach ( @{$conf{usertoken}} )
	{
		my $response;

		if ( $priority eq 2 && defined $_[2] && defined $_[3] )
		{
			my $srv1 = $_[2];
			$srv1 =~ s/\.$conf{networkdomain}//i;
			$srv1 =~ s/\./\_/g;
			my $srv2 = $_[3];
			$srv2 =~ s/\.$conf{networkdomain}//i;
			$srv2 =~ s/\./\_/g;

			$tag = $srv1 . "=" . $srv2;

			$response = $ua->post(
				$url,
				[
					"token" =>  $conf{pushtoken},
					"user" =>  $_,
					"priority" => 2,
					"expire" => $conf{pushexpire},
					"retry" => $conf{pushretry},
					"message" => $message,
					"tags" => $tag,
				]
			);
		}
		elsif ( $priority eq 2 && !defined $_[2] )
		{
			$response = $ua->post(
				$url,
				[
					"token" =>  $conf{pushtoken},
					"user" =>  $_,
					"priority" => 2,
					"expire" => $conf{pushexpire},
					"retry" => $conf{pushretry},
					"message" => $message,
				]
			);
		}
		else
		{
			$response = $ua->post(
				$url,
				[
					"token" =>  $conf{pushtoken},
					"user" =>  $_,
					"priority" => $priority,
					"message" => $message,
				]
			);
		}

		if ($response->is_success) {
			logmsg("Notification sent successfully to $_ (pri $priority)");
			logmsg("Tags: $tag") if ( defined $tag );
		} else {
			logmsg("Failed to send notification to $_: " . $response->status_line);
			logmsg("Response content: " . $response->decoded_content);
		}
	}
}

sub cancel_pushretry
{
	if ( !$conf{pushenable} || $_[0] ne 2 ) { return 0; }

	my $srv1 = $_[1];
	$srv1 =~ s/\.$conf{networkdomain}//i;
	$srv1 =~ s/\./\_/g;
	my $srv2 = $_[2];
	$srv2 =~ s/\.$conf{networkdomain}//i;
	$srv2 =~ s/\./\_/g;

	my $tag = $srv1 . "=" . $srv2;
	my $url = "https://api.pushover.net/1/receipts/cancel_by_tag/" . $tag . ".json";
	my $ua = LWP::UserAgent->new();
	$ua->timeout(10);
	my $response;

	$response = $ua->post( $url, [ "token" => $conf{pushtoken}, ] );

        if ($response->is_success) {
		logmsg("Emergency retries successfully cancelled for tags: $tag");
	} else {
		logmsg("Failed to cancel emergency retries with tags $tag: " . $response->status_line);
		logmsg("Response content: " . $response->decoded_content);
	}
}

sub queuemsg
{
	my $level = shift;
	my $msg   = shift;

	if ( $level == 1 )
	{
		push(@{$server{out1}},$msg);
	}
	elsif ( $level == 2 )
	{
		push(@{$server{out2}},$msg);
	}
	elsif ( $level == 3 )
	{
		push(@{$server{out3}},$msg);
	}
}

sub timed_events
{
	if ( time - $data{time}{checkupdate} > 86400 )
	{
		$data{time}{checkupdate} = time;

		my $update = check_update();

		if ( $update =~ s/^-2 *// )
		{
			queuemsg(3,$CMD . chr(3) . 2 . chr(2) . "UPDATE" . chr(2) . ": An update is available, but the following dependencies are missing: $update. Please install and re-run " . chr(31) . "update install" . chr(31) . " to update." . chr(3));
		}
		elsif ( $update eq '0' )
		{
			logdeb("No updates available (running v$version (rev. $revision)).");
		}
		elsif ( $update eq '-1' )
		{
			logdeb("There was an error checking for updates. (-1)");
		}
		else
		{
			queuemsg(3,$CMD . chr(3) . 2 . chr(2) . "UPDATE" . chr(2) . ": $update - run " . chr(31) . "update install" . chr(31) . " to update." . chr(3));
		}
	}

	if ( time - $data{time}{connexitclean} > 3600 )
	{
		# time to clean the connexit file
		my @CONN;
		open(CONN,"$conf{path}/var/connexit.txt");
		while(<CONN>)
		{
			if ( /^(\d+) / )
			{
				if ( $1 > time - 3600 )
				{
					push(@CONN,$_);
				}
			}
		}
		close(CONN);

		open(CONN,">$conf{path}/var/connexit.txt");
		foreach(@CONN)
		{
			print CONN $_;
		}
		close(CONN);

		$data{time}{connexitclean} = time;
	}
#	if ( time - $data{notice}{lastcheck} >= 0 && time - $data{notice}{lastprint} >= $conf{cetimethres} && !$conf{hubmode} )
	if ( time - $data{time}{lastcheck} >= $conf{cetimethres} && !$conf{hubmode} )
	{
		my $time;
		my $usermore = 0;
		my $userless = 0;
		my %ip_stats = (
			ipv4 => { usermore => 0, userless => 0 },
			ipv6 => { usermore => 0, userless => 0 }
		);
		
		foreach my $ip_type ('ipv4', 'ipv6') {
			foreach $time ( sort keys %{$data{notice}{$ip_type}} )
			{
				if ( $time >= time - $conf{cetimethres} )
				{
					if ( $data{notice}{$ip_type}{$time} =~ /^\d/ )
					{
						$ip_stats{$ip_type}{usermore} += $data{notice}{$ip_type}{$time};
					}
					else
					{
						$ip_stats{$ip_type}{userless} -= $data{notice}{$ip_type}{$time};
					}
				}
				else
				{
					delete($data{notice}{$ip_type}{$time});
				}
			}
			
			$usermore += $ip_stats{$ip_type}{usermore};
			$userless += $ip_stats{$ip_type}{userless};
		}
		
		my $ipv4_usermore = $ip_stats{ipv4}{usermore};
		my $ipv4_userless = $ip_stats{ipv4}{userless};
		my $ipv6_usermore = $ip_stats{ipv6}{usermore};
		my $ipv6_userless = $ip_stats{ipv6}{userless};

		# Possible attack - first cycle.
		if ( ( abs($usermore) >= $conf{ceuserthres} || abs($userless) >= $conf{ceuserthres} ) && !$data{notice}{cycles} )
		{
			send_warning("Possible attack: +$usermore/-$userless (IPv4: +$ipv4_usermore/-$ipv4_userless, IPv6: +$ipv6_usermore/-$ipv6_userless) users in $conf{cetimethres} seconds ($data{lusers}{locusers} users)");
			push_notify($conf{pushuserchange}, "USER CHANGE: +$usermore/-$userless (IPv4: +$ipv4_usermore/-$ipv4_userless, IPv6: +$ipv6_usermore/-$ipv6_userless)");

#			$data{notice}{lastprint} = time;
			$data{notice}{usermore} = $usermore;
			$data{notice}{userless} = $userless;
			$data{notice}{ipv4_usermore} = $ipv4_usermore;
			$data{notice}{ipv4_userless} = $ipv4_userless;
			$data{notice}{ipv6_usermore} = $ipv6_usermore;
			$data{notice}{ipv6_userless} = $ipv6_userless;
			$data{notice}{cycles} = 1;
		}
		# Possible attack still ongoing, new cycle. 
		elsif ( ( abs($usermore) >= $conf{ceuserthres} || abs($userless) >= $conf{ceuserthres} ) && $data{notice}{cycles} )
		{
#			$data{notice}{lastprint} = time;
			$data{notice}{usermore} += $usermore;
			$data{notice}{userless} += $userless;
			$data{notice}{ipv4_usermore} += $ipv4_usermore;
			$data{notice}{ipv4_userless} += $ipv4_userless;
			$data{notice}{ipv6_usermore} += $ipv6_usermore;
			$data{notice}{ipv6_userless} += $ipv6_userless;
			$data{notice}{cycles}++;
		}
		# No more user changes above threshold. Possible attack has stopped. Summarise and write to log.
		elsif ( abs($usermore) <= $conf{ceuserthres} && abs($userless) <= $conf{ceuserthres} && $data{notice}{cycles} )
		{
			if ( $data{notice}{cycles} > 1 )
			{
				send_warning("Possible attack " . chr(31) . "ended" . chr(31) . ": +$data{notice}{usermore}/-$data{notice}{userless} (IPv4: +$data{notice}{ipv4_usermore}/-$data{notice}{ipv4_userless}, IPv6: +$data{notice}{ipv6_usermore}/-$data{notice}{ipv6_userless}) users in " . $conf{cetimethres} * $data{notice}{cycles} . " seconds ($data{lusers}{locusers} users)");
				push_notify($conf{pushuserchange}, "USER CHANGE: +$data{notice}{usermore}/-$data{notice}{userless} (IPv4: +$data{notice}{ipv4_usermore}/-$data{notice}{ipv4_userless}, IPv6: +$data{notice}{ipv6_usermore}/-$data{notice}{ipv6_userless}) users in " . $conf{cetimethres} * $data{notice}{cycles} . " seconds");
			}

			# Find next unique attack id
			my $attackid = 0;
			if ( open(ATTACKLOG,"$conf{path}/var/attack.txt") )
			{
				while (<ATTACKLOG>)
				{
					if ( /^ATTACK\:(\d+)\:(\d+)\:(\d+)$/ )
					{
						if ( $1 > $attackid )
						{ $attackid = $1; }
					}
				}
			close(ATTACKLOG);
			}

			# Write relevant conn/exits to attacklog
			$attackid++;

			open(CONN,"$conf{path}/var/connexit.txt");
			open(ATTACKLOG,">>$conf{path}/var/attack.txt");
			print ATTACKLOG "ATTACK:$attackid:" . time . ":" . $conf{cetimethres} * $data{notice}{cycles} . "\n";

			while(<CONN>)
			{
			#	chop;
				if ( /^(\d+) (.*)$/ )
				{
					if ( $1 >= time - ( $conf{cetimethres} * $data{notice}{cycles} ) )
					{ print ATTACKLOG $_; }
				}
			}
			print ATTACKLOG "\n";
			close(CONN);
			close(ATTACKLOG);

			# Reset
			$data{notice}{cycles} = 0;
			$data{notice}{usermore} = 0;
			$data{notice}{userless} = 0;
		}

		$data{time}{lastcheck} = time;
	}
	
	if ( ( time - $data{time}{fw} ) >= $conf{fwinterval} && $conf{fwinterval} > 0 )
	{
		if (-e "$conf{path}/var/fwstats.txt")
		{
			open my $fh, '<', "$conf{path}/var/fwstats.txt" or die "Cannot open $conf{path}/var/fwstats.txt: $!";
    			my $line = <$fh>;
 			close $fh;
			chomp($line);

			# Store last data
			if ( exists $data{fw}{new} )
			{
				$data{fw}{old} = { %{$data{fw}{new}} };
			}

			# Split the line by ':' and fetch the values
			($data{fw}{new}{timestamp}, $data{fw}{new}{packets}, $data{fw}{new}{bytes}) = split /:/, $line;

			if ( exists $data{fw}{old}{timestamp} && exists $data{fw}{old}{packets} && exists $data{fw}{old}{bytes} 
				&& $data{fw}{new}{timestamp} != $data{fw}{old}{timestamp} )
			{
				$data{fw}{new}{kbps} = int( ( ( ( $data{fw}{new}{bytes} - $data{fw}{old}{bytes} ) / ($data{fw}{new}{timestamp} - $data{fw}{old}{timestamp} ) ) * 8 ) / 1000 );
				$data{fw}{new}{pps} = int( ( $data{fw}{new}{packets} - $data{fw}{old}{packets} ) / ($data{fw}{new}{timestamp} - $data{fw}{old}{timestamp} ) );
			}

			if ( $data{fw}{new}{kbps} > $conf{fwkbps} || $data{fw}{new}{pps} > $conf{fwpps} )
			{

				my $diff_kbps = $data{fw}{new}{kbps} - $data{fw}{old}{kbps};
				my $diff_pps = $data{fw}{new}{pps} - $data{fw}{old}{pps};
				if ( $diff_kbps =~ /^\d+$/ ) { $diff_kbps ="+$diff_kbps"; }
				if ( $diff_pps =~ /^\d+$/ ) { $diff_pps ="+$diff_pps"; }
				$data{fw}{cycles}++;

				send_warning("Firewall engaging at $data{fw}{new}{kbps}($diff_kbps) kbps / $data{fw}{new}{pps}($diff_pps) pps");
			}
			# We are no longer being hit, but last cycle. Notify and reset
			elsif ( $data{fw}{cycles} )
			{
				push_notify($conf{pushfw}, "Firewall no longer engaging after " . $data{fw}{cycles} * $conf{fwinterval} . " seconds");
				send_warning("Firewall no longer engaging!");
				$data{fw}{cycles} = 0;
			}

			if ( $data{fw}{cycles} == 1 )
			{
				push_notify($conf{pushfw}, "Firewall engaging!");
			}

		}
		$data{time}{fw} = time;
	}

	if ( ( time - $data{status}{report} ) >= $conf{pollinterval} )
	{
		# its report time

		open(MAP,">$conf{path}/var/map.txt");
		foreach ( keys %{$data{statsv}} )
		{
			print MAP "$_ $data{statsv}{$_}{users}\n";
		}
		close(MAP);

		open(MRTG,">$conf{path}/var/sentinel.log");

		my $trafmsg = 'TRAFFIC-> ';
		if ( $conf{trafficreport} )
		{
			%{$data{cpu}{new}} = cpu();
			my $tot;
			my $used;

			if ( exists $data{cpu}{old}{used} && exists $data{cpu}{old}{idle} )
			{
				$tot = ( $data{cpu}{new}{used} + $data{cpu}{new}{idle} ) - ( $data{cpu}{old}{used} + $data{cpu}{old}{idle} );
				$used = $data{cpu}{new}{used} - $data{cpu}{old}{used};
			}
			else
			{
				$tot = $data{cpu}{new}{used} + $data{cpu}{new}{idle};
				$used = $data{cpu}{new}{used};
			}

			my $time = $tot / 100;
			my $pcent = 0;
			if ( $time > 0 )
			{
				$pcent = int($used / $time);
			}

			if ( $pcent >= $conf{cputhres} && $pcent > $data{last}{cpu} )
			{
				send_warning("High CPU usage: $pcent pct");
				push_notify($conf{pushcpu}, "CPU: $pcent%");
			}

			$trafmsg .= chr(2) . "cpu" . chr(2) . " $pcent pct ";
			print MRTG sprintf("CPU:%s\n",$pcent);

			%{$data{cpu}{old}} = %{$data{cpu}{new}};
			$data{last}{cpu} = $pcent;
			
			if ( exists $data{traftime}{new} )
			{ $data{traftime}{old} = $data{traftime}{new}; }
			else
			{ $data{traftime}{old} = 0; }

			$data{traftime}{new} = time;
			%{$data{traffic}{new}} = traffic();

			my $difftime = $data{traftime}{new} - $data{traftime}{old};

			my $ifname;
			foreach $ifname ( sort keys %{$data{traffic}{new}} )
			{
				print MRTG "IF_$ifname\_PACKETS_I:" . $data{traffic}{new}{$ifname}{ip} . "\n";
				print MRTG "IF_$ifname\_PACKETS_O:" . $data{traffic}{new}{$ifname}{op} . "\n";
				print MRTG "IF_$ifname\_BYTES_I:"   . $data{traffic}{new}{$ifname}{ib} . "\n";
				print MRTG "IF_$ifname\_BYTES_O:"   . $data{traffic}{new}{$ifname}{ob} . "\n";
				my %rate;
				foreach ( keys %{$data{traffic}{new}{$ifname}} )
				{
					if ( exists $data{traffic}{old}{$ifname}{$_} )
					{
						my $old = $data{traffic}{old}{$ifname}{$_};
						my $new = $data{traffic}{new}{$ifname}{$_};

						if ( $new < $old )
						{
							$new += 4294967296;
						}

						$rate{$_} = int ( ( $new - $old ) / $difftime );
					}

					$data{traffic}{old}{$ifname}{$_} = $data{traffic}{new}{$ifname}{$_};
				}

				if ( $data{traftime}{old} )
				{
					$rate{ib} = int ( $rate{ib} * 8 / 1024 );
					$rate{ob} = int ( $rate{ob} * 8 / 1024 );
					$trafmsg .= chr(2) . $ifname . chr(2) . " $rate{ib}/$rate{ob} kbps $rate{ip}/$rate{op} pps ";
				}
			}
		}

		if ( $conf{multimode} )
		{
			$data{status}{report} = time;
		}
		else
		{
			$data{status}{report} = time - (  time % $conf{pollinterval} );
		}

		if ( !$conf{hubmode} )
		{
#			my $servcount = $data{statsv}{$data{servername}}{users};
			my $servcount = $data{lusers}{locusers};
			my $pos = 1;
			my $all = 0;
			foreach ( keys %{$data{statsv}} )
			{
				if ( $data{statsv}{$_}{users} > 15 )
				{
					$all++;
				}

				if ( $servcount < $data{statsv}{$_}{users} )
				{
					$pos++;
				}
			}

			if ( !$data{lusers}{unknown} ) { $data{lusers}{unknown} = 0; }
			if ( !$data{notice}{more} ) { $data{notice}{more} = 0; }
			if ( !$data{notice}{less} ) { $data{notice}{less} = 0; }

			if ( $conf{reportenable} )
			{ 
				my $pcent = sprintf("%0.2f%%",$data{lusers}{locusers}/$data{lusers}{glousers}*100);

				my $moreless = "(\+$data{notice}{more}/\-$data{notice}{less})";

				my $statmsg = "$data{lusers}{locusers}($pcent)/$data{lusers}{glousers} $moreless. ";

				my $diff = 0;
				if ( exists $data{last}{channels} )
				{
					$diff = $data{lusers}{channels} - $data{last}{channels};
				}

				if ( $diff =~ /^\d+$/ ) { $diff ="+$diff"; }

				$statmsg .= "No $pos/$all. ";
				$statmsg .= "$data{lusers}{channels}($diff)chans, ";
				$statmsg .= "$data{lusers}{unknown} unknown";

				$data{last}{channels} = $data{lusers}{channels};

				queuemsg(2,$CMD . "COUNT  -> $statmsg");
			}

			print MRTG "LOCAL_USERS:$data{lusers}{locusers}\n";
			print MRTG "GLOBAL_USERS:$data{lusers}{glousers}\n";
			print MRTG "UNKNOWN_USERS:$data{lusers}{unknown}\n";
			print MRTG "MAX_LOCAL_USERS:$data{lusers}{maxusers}\n";
			print MRTG "CHANNEL:$data{lusers}{channels}\n";
			print MRTG "POSITION:$pos\n";
			print MRTG "USERS_PERCENT:" . int($data{lusers}{locusers}/$data{lusers}{glousers}*10000) . "\n";
			print MRTG "USERS_MORE:$data{notice}{more}\n";
			print MRTG "USERS_LESS:$data{notice}{less}\n";

			$data{notice}{more} = 0;
			$data{notice}{less} = 0;
		}

		my $rpingmsg;

		foreach( keys %{$data{clines}} )
		{
			# We only want rping for C:lines not linked to us. If SendQ exists, its linked.
			# In HUBMODE, we only include other hubs.
			if ( !exists $data{uplinks}{$_} && ( ( $conf{hubmode} && $data{statsv}{$_}{hub} ) || !$conf{hubmode} ) )
			{
				my $rpdiff = 0;
				my $hub = $_;
				$hub =~ s/\.$conf{networkdomain}//i;

				$rpingmsg .= chr(2) . $hub . chr(2) . ":$data{clines}{$_}";
				if ( $data{last}{rping}{$_} =~ /^\d+$/ )
				{
					$rpdiff = $data{clines}{$_} - $data{last}{rping}{$_};
					if ( $rpdiff != 0 )
					{
						if ( $rpdiff =~ /^\d+$/ ) { $rpdiff ="+$rpdiff"; }
						$rpingmsg .= "($rpdiff)";
					}
				}
				$rpingmsg .= " -- ";

				if ( $data{clines}{$_} =~ /^\d+$/ )
				{
					my $srv = $_;
					$srv =~ s/\.$conf{networkdomain}//i;
					$srv =~ s/\./\_/g;
					print MRTG "RPING_$srv:$data{clines}{$_}\n";
					$data{last}{rping}{$_} = $data{clines}{$_};
				}
			}
		}

		if ( $rpingmsg && $conf{reportenable} )
		{
			$rpingmsg = substr $rpingmsg, 0, -4;
			queuemsg(2,$CMD . "RPING  -> $rpingmsg");
		}

		my $linkmsg;
		my $itr_count = 0;
		my $itr_tot = 0;

		foreach( keys %{$data{uplinks}} )
		{
			$itr_count++;
			$itr_tot++;
			my $uplink = $_;
			$uplink =~ s/\.$conf{networkdomain}//i;

			$linkmsg .= chr(2) . $uplink . chr(2) ."\[";

			if ( exists $data{clines}{$_} )
			{
				my $rpdiff = 0;

				$linkmsg .= "rp:$data{clines}{$_}";
				$rpdiff = $data{clines}{$_} - $data{last}{rping}{$_};
				if ( $rpdiff != 0 )
				{
					if ( $rpdiff =~ /^\d+$/ ) { $rpdiff ="+$rpdiff"; }
					$linkmsg .= "($rpdiff)";
				}

				$data{last}{rping}{$_} = $data{clines}{$_};

				my $srv = $_;
				$srv =~ s/\.$conf{networkdomain}//i;
				$srv =~ s/\./\_/g;
				print MRTG "RPING_$srv:$data{clines}{$_}\n";
			}

			my $sqdiff = 0;

			$linkmsg .= " sq:$data{uplinks}{$_}";
			if ( exists $data{last}{sendq}{$_} )
			{
				$sqdiff = $data{uplinks}{$_} - $data{last}{sendq}{$_};
				if ( $sqdiff != 0 )
				{
					if ( $sqdiff =~ /^\d+$/ ) { $sqdiff ="+$sqdiff"; }
					$linkmsg .= "($sqdiff)";
				}
			}

			if ( $data{uplinks}{$_} =~ /^\d+$/ )
			{
				$data{last}{sendq}{$_} = $data{uplinks}{$_};
				my $srv = $_;
				$srv =~ s/\.$conf{networkdomain}//i;
				$srv =~ s/\./\_/g;
				print MRTG "SENDQ_$srv:$data{uplinks}{$_}\n";
			}

			my $uptime = easytime(time-$data{statsv}{$_}{linkts});
			$linkmsg .= " up:$uptime] -- ";

			if ( $linkmsg && $conf{reportenable} && ( $itr_count == 3 || $itr_tot == keys %{$data{uplinks}} ) )
			{
				$linkmsg = substr $linkmsg, 0, -4;
				queuemsg(2,$CMD . "UPLINK -> $linkmsg");
				$itr_count = 0;
				$linkmsg = "";
			}
		}

		close(MRTG);

		if ( $trafmsg =~ /\d/ )
		{
			queuemsg(2,$CMD . $trafmsg);
		}

		queuemsg(2,$CMD . " ");

		# its IMPORT_FILE time

		if ( exists $conf{import_file} && -r "$conf{import_file}" )
		{
			my $import = 'IMPORT ->';
			open(IMPORT,"$conf{import_file}");
			while(<IMPORT>)
			{
				chop;
				my ($name,$limit,$value)=split(/\;/);

				if ( $limit =~ /any/i )
				{
					# always display
					$import .= " $name:$value";
				}
				elsif ( $limit >= 0  && $value >= $limit )
				{
					# display with threshold
					$import .= " $name:$value";
				}
			}
			close(IMPORT);

			if ( $import =~ /\d/ )
			{
				queuemsg(2,$CMD . $import);
			}
		}

		# clone check time
		if ( !$conf{hubmode} && $conf{locglineaction} !~ /disable/i )
		{
			my %counter;

			foreach ( keys %{$data{who}} )
			{
				my $rname = $data{who}{$_}{rname};
				$rname =~ tr/[A-Z]/[a-z]/;
				if ( length($rname) < 3 ) { next; }

				$counter{$rname}++;
			}
			my $rname;
			foreach $rname ( keys %counter )
			{
				if ( $counter{$rname} >= $conf{rnameglinelimit} )
				{
					# exceeds gline limit

					my $ignore = 0;
					foreach ( @{$conf{rnamelist}} )
					{
						my $match = wild2reg($_);
						if ( $rname =~ /^$match$/ )
						{
							$ignore = 1;
						}
					}

					if ( !$ignore )
					{
						my $rnamewild = '';
						foreach (split(//,$rname))
						{
							if ( $_ =~ /(\w|\-|\=|\_|\;|\,|\.)/ )
							{
								$rnamewild .= $_;
							}
							else
							{
								$rnamewild .= "?";
							}
						}
						my $rnamereg  = $rnamewild;
						$rnamereg =~ s/\./\\./g;
						$rnamereg =~ s/\?/./g;

						# applying new rname on user list;

						my $newmatch = 0;
						foreach ( keys %{$data{who}} )
						{
							if ( $data{who}{$_}{rname} =~ /^$rnamereg$/i )
							{
								$newmatch++;
							}
						}

						if ( $counter{$rname} eq $newmatch )
						{
							if ( $conf{locglineaction} =~ /warn/i )
							{
								queuemsg(2,$CMD . chr(3) . 4 . chr(2) . "CLONE WARNING" . chr(2) . ": '$rname' -> '$rnamewild' ($newmatch users)" . chr(3));
							}
							elsif ( $conf{locglineaction} =~ /gline/i )
							{
								queuemsg(2,$CMD . chr(2) . "GLINE" . chr(2) . " for '$rname' -> '$rnamewild' ($newmatch users)");
								queuemsg(2,"GLINE +\$R$rnamewild $conf{rnameglinetime} :Auto-Klined for $conf{rnameglinetime} seconds.");
							}
						}
						else
						{
							if ( $conf{locglineaction} =~ /gline/i )
							{
								queuemsg(2,$CMD . chr(3) . 4 . chr(2) . "GLINE WARNING" . chr(2) . ": will not set gline for '$rname' (gline on '$rnamewild') should affect $counter{$rname} users, but will affect $newmatch users. Please take a manual action!" . chr(3));
							}
						}
					}
				}
			}
			undef %counter;

			# Check for IP clones
			foreach ( keys %{$data{who}} )
			{
				my $cnet = $data{who}{$_}{ip};
				$cnet =~ s/\.\d+$/\.\*/;
				$counter{$cnet}++;
			}

			my $userip;
			foreach $userip ( keys %counter )
			{
				if ( $counter{$userip} >= $conf{ipglinelimit} )
				{
					my $ignore = 0;
					foreach ( @{$conf{iplist}} )
					{
						my $match = wild2reg($_);
						if ( $userip =~ /^$match$/ )
						{
							$ignore = 1;
						}
					}
					if ( !$ignore )
					{
						if ( $conf{locglineaction} =~ /warn/i )
						{
							queuemsg(2,$CMD . chr(3) . 4 . chr(2) . "CLONE WARNING" . chr(2) . ": '$userip' ($counter{$userip} users)" . chr(3));
						}
						elsif ( $conf{locglineaction} =~ /gline/i )
						{
							queuemsg(2,$CMD . chr(2) . "GLINE" . chr(2) . " for '$userip' ($counter{$userip} users)");
							queuemsg(2,"GLINE \!\+*\@$userip $conf{ipglinetime} :Auto-Klined for $conf{ipglinetime} seconds.");
						}
					}
				}
			}
		}
	}

	# its poll time

	if ( ( time - $data{time}{statsc} ) >= ( $conf{pollinterval} - 30 ) )
	{
		if ( $data{status}{statsc} )
		{
			queuemsg(1,"STATS c");
			$data{status}{statsc} = 0;
		}
		else
		{
			$data{status}{statsc} = 1;
			$data{time}{statsc} = time;
		}
	}

	if ( ( time - $data{time}{statsv} ) >= ( $conf{pollinterval} - 30 ) )
	{
		if ( $data{status}{statsv} )
		{
			queuemsg(1,"STATS v");
			$data{status}{statsv} = 0;
			delete $data{statsv};
		}
		else
		{
			$data{status}{statsv} = 1;
			$data{time}{statsv} = time;
		}
	}

	if ( ( time - $data{time}{statsl} ) >= ( $conf{pollinterval} - 30 ) )
	{
		if ( $data{status}{statsl} )
		{
			queuemsg(1,"STATS l");
			$data{status}{statsl} = 0;
			delete $data{statsl};
		}
		else
		{
			$data{status}{statsl} = 1;
			$data{time}{statsl} = time;
		}
	}

	if ( ( ( time - $data{time}{lusers} ) >= ( $conf{pollinterval} - 30 ) ) && !$conf{hubmode} )
	{
		if ( $data{status}{lusers} )
		{
			queuemsg(1,"LUSERS");
			$data{status}{lusers} = 0;
		}
		else
		{
			$data{status}{lusers} = 1;
			$data{time}{lusers} = time;
		}
	}

	if ( ( time - $data{time}{account} ) >= 300 && !$cap{'account-notify'} )
	{
		my $channel = $conf{reportchan};
		if ( $conf{operchan} ne '' ) { $channel .= ",$conf{operchan}"; }

		queuemsg(1,"WHO $channel xco%na");
		$data{time}{account} = time;
	}

	if ( ( time - $data{time}{ison} ) >= 300 )
	{
		queuemsg(1,"ISON :@{$conf{nicks}}");
		$data{time}{ison} = time;
	}

	if ( ( ( time - $data{time}{who} ) >= ( $conf{pollinterval} - 30 ) ) && !$conf{hubmode} && $conf{locglineaction} !~ /disable/i )
	{
		if ( $data{status}{who} )
		{
			open(WHO,">$conf{path}/var/users.tmp");
			close(WHO);
			queuemsg(1,"WHO $data{servername} x%nuhilraf");
			$data{status}{who} = 0;
			delete $data{who};
			$data{autoid} = 0;
		}
		else
		{
			$data{status}{who} = 1;
			$data{time}{who} = time;
		}
	}

	if ( ( time - $data{time}{rping} ) >= ( $conf{pollinterval} - 30 ) )
	{
		if ( $data{status}{rping} )
		{
			foreach( keys %{$data{clines}} )
			{
				if ( ( $conf{hubmode} && ( $data{statsv}{$_}{hub} || exists $data{uplinks}{$_} ) ) || !$conf{hubmode} )
				{
					queuemsg(1,"RPING $_");
					$data{status}{rping} = 0;
				}
			}
		}
		else
		{
			$data{status}{rping} = 1;
			$data{status}{rpwarn} = 1;
			$data{time}{rping} = time;
		}
	}

	if ( ( time - $data{time}{rping} ) >= 10 && $data{status}{rpwarn} )
	{
		my $warnmsg;
		my $notify = 0;

		foreach( keys %{$data{clines}} )
		{
			if ( $data{clines}{$_} =~ /^\d+$/
				&& int($data{clines}{$_}) > $conf{rpingwarn}
				&& int($data{clines}{$_}) > $data{last}{rping}{$_}
				&& exists $data{uplinks}{$_} )
			{
				my $srv = $_;
				$srv =~ s/\.$conf{networkdomain}//i;

				my $diff = $data{clines}{$_} - $data{last}{rping}{$_};
				if ( $diff =~ /^\d+$/ ) { $diff ="+$diff"; }

				$warnmsg .= $srv . ": " . $data{clines}{$_} . "(" . $diff . ") ";
				$notify = 1;
			}
		}
		if ( $notify )
		{
			send_warning("Detected RPING: $warnmsg");
			push_notify($conf{pushrping}, "RPING: $warnmsg");
		}
		$data{status}{rpwarn} = 0;
	}

	if ( ( time - $data{time}{statsl} ) >= 10 && $data{status}{sqwarn} )
	{
		my $warnmsg;
		my $notify = 0;

		foreach( keys %{$data{uplinks}} )
		{
			if ( $data{uplinks}{$_} > $conf{sendqwarn} && $data{uplinks}{$_} > $data{last}{sendq}{$_} )
			{
				my $srv = $_;
				$srv =~ s/\.$conf{networkdomain}//i;

				my $diff = $data{uplinks}{$_} - $data{last}{sendq}{$_};
				if ( $diff =~ /^\d+$/ ) { $diff ="+$diff"; }

				$warnmsg .= $srv . ": " . $data{uplinks}{$_} . "(" . $diff . ") ";
				$notify = 1;
			}
		}
		if ( $notify )
		{
			send_warning("Detected SENDQ: $warnmsg");
			push_notify($conf{pushsendq}, "SENDQ: $warnmsg");
		}

		$data{status}{sqwarn} = 0;
	}
}

sub irc_loop
{
	my $line = shift;

	if ( $line =~ s/^:([^\s]+)\!([^\s]+)\@([^\s]+) //i )
	{
		# user stuff

		my $nick = $1;
		my $user = $2;
		my $host = $3;

		if ( $line =~ /^JOIN ($conf{reportchan})(?:\s+(\S+))?(?:\s+:.*)?$/i
			|| ( $conf{operchan} ne '' && $line =~ /^JOIN ($conf{operchan})(?:\s+(\S+))?(?:\s+:.*)?$/i ) )
		{
			# correct channel?
			my $channel = $1;
			my $account = $2 // '';
			
			# user joined channel

			if ( $nick =~ /^$data{nick}$/i )
			{
				# its me!

				$data{channels}{lc($channel)}{ison} = 1;
				$data{channels}{lc($channel)}{limit} = 0;				

				if ( $channel =~ /^\&/ )
				{
					queuemsg(1,"MODE $channel +o $data{nick}");
				}

				queuemsg(1,"WHO $channel xc%nifac");
			}
			else
			{
				$data{clients}{$nick}{lc($channel)} = 1;
				queuemsg(2,"WHO $nick x%nifa");
			}
		}
		elsif ( $line =~ /^ACCOUNT ([^\s]+)$/ )
		{
			$data{clients}{$nick}{account} = $1;
		}
		elsif ( ($line =~ s/^MODE\s+($conf{reportchan})\s+//i) || ($conf{operchan} ne '' && $line =~ s/^MODE\s+($conf{operchan})\s+//i) )
		{
			my $channel = $1;

			# channel mode
			if ( $line =~ /^\+o $data{nick}$/i )
			{
				$data{channels}{lc($channel)}{isop} = 1;

				if ( $data{lusers}{maxusers}
					&& $data{channels}{lc($channel)}{limit} != $data{lusers}{maxusers}
					&& !$conf{hubmode} && !$conf{multimode} ) {
					queuemsg(1,"MODE $channel +l $data{lusers}{maxusers}");
				}

				if ( $conf{chanmode} =~ /k/ )
				{
					queuemsg(1,"MODE $channel $conf{chanmode} $conf{chankey}");
				}
				elsif ( $conf{chanmode} )
				{
					queuemsg(1,"MODE $channel $conf{chanmode}");
				}
			}
			elsif ( $nick =~ /^$data{nick}$/i && $line =~ /^\+l (\d+)$/ )
			{
				$data{channels}{lc($channel)}{limit} = $1;
			}
			elsif ( $line =~ /^(\-|\+|\w)+( \d+)*$/ )
			{
				if ( $nick =~ /^$data{nick}$/i )
				{
					# nothing yet
				}
				else
				{
					if ( $data{lusers}{maxusers} && !$conf{hubmode} && !$conf{multimode} ) {
						queuemsg(2,"MODE $channel +l $data{lusers}{maxusers}");
					}

					if ( $conf{chanmode} )
					{
						queuemsg(2,"MODE $channel $conf{chanmode}");
					}
				}
			}
		}
		elsif ( $line =~ s/^(PRIVMSG|NOTICE) $data{nick} ://i && $data{clients}{$nick}{oper} )
		{
			# message from oper
			my $replymode = $1;

			# is ctcp ?
			if ( $line =~ /^/ )
			{
				if ( $line =~ /^TIME (.*)$/i )
				{
					$data{clients}{$nick}{offset} = guess_tz($1);
					my $offset = easytime($data{clients}{$nick}{offset});
					if ( $offset =~ /^\d/ ) { $offset = "+$offset"; }
					queuemsg(2,"NOTICE $nick :Your offset to GMT is $offset. Timestamps in DCC will be shown in your localtime.");
				}
			}
			elsif ( $line =~ s/^help *//i )
			{
				if ( $line =~ /nick/i )
				{
					queuemsg(3,"$replymode $nick :command: NICK <nickname>");
					queuemsg(3,"$replymode $nick :note   : change the nickname of the bot.");
				}
				elsif ( $line =~ /update/i )
				{
					queuemsg(3,"$replymode $nick :command: UPDATE <check|install>");
					queuemsg(3,"$replymode $nick :note   : 'check' checks for available updates.");
					queuemsg(3,"$replymode $nick :       : 'install' installs available updates.");

				}
				elsif ( $line =~ /reload/i )
				{
					queuemsg(3,"$replymode $nick :command: RELOAD <cold|warm>");
					queuemsg(3,"$replymode $nick :note   : 'warm' reload configuration on the fly.");
					queuemsg(3,"$replymode $nick :       : 'cold' reload configuration and restart.");
				}
				elsif ( $line =~ /die/i )
				{
					queuemsg(3,"$replymode $nick :command: DIE <reason>");
				}
				elsif ( $line =~ /raw/i )
				{
					queuemsg(3,"$replymode $nick :command: RAW <command>");
					queuemsg(3,"$replymode $nick :note   : sends a command directly to the server.");
					if ( !$conf{enableraw} )
					{
						queuemsg(3,"$replymode $nick :warning: THIS COMMAND IS DISABLED BY CONFIGURATION!");
					}
				}
				elsif ( $line =~ /dcc/i )
				{
					queuemsg(3,"$replymode $nick :command: DCC <ip> [port]");
					queuemsg(3,"$replymode $nick :note   : starts a DCC session. the port is optional.");
				}
				else
				{
					queuemsg(3,"$replymode $nick :command: HELP <nick|raw|dcc|reload|die|update>");
					queuemsg(3,"$replymode $nick :note   : help about commands");
				}
			}

			elsif ( $line =~ /^debug/i && $debug )
			{
				logdeb("Clients:");
				foreach ( keys %{$data{clients}} )
				{
					my $itNick = $_;
					logdeb("  $itNick");
					foreach ( keys %{$data{clients}{$itNick}} )
					{
						logdeb("    $_: $data{clients}{$itNick}{$_}");
					}
				}
				logdeb("Channels:");
				foreach ( keys %{$data{channels}} )
				{
					my $itChan = $_;
					logdeb("  $itChan");
					foreach ( keys %{$data{channels}{$itChan}} )
					{
						logdeb("    $_: $data{channels}{$itChan}{$_}");
					}
				}
			}			
			elsif ( $line =~ /^update (check|install)/i && is_admin($nick) )
			{
				my $update = check_update();
				my $hasupdate = 0;

				if ( $update =~ s/^-2 *// )
				{
					$update = "An update is available, but the following dependencies are missing: $update. Please install and re-run 'update install'.";
				}
				elsif ( $update eq '0' )
				{
					$update = "No updates available (running v$version (rev. $revision)).";
				}
				elsif ( $update eq '-1' )
				{
					$update = "There was an error checking for updates.";
				}
				else
				{
					$hasupdate = 1;
				}

				if ( $line =~ /check/i )
				{
					if ( $hasupdate ) { $update .= " - run " . chr(31) . "update install" . chr(31) . " to update."; }
					queuemsg(3,"$replymode $nick :$update");
				}
				elsif ( $line =~ /install/i )
				{
					if ( $hasupdate )
					{
						my $sock = $server{socket};
						print $sock "$replymode $nick :$update\r\n";
						print $sock "$replymode $nick :Attempting to install...\r\n";

						if ( !apply_update() )
						{
							queuemsg(3,"$replymode $nick :There was an error when applying the update.");
						}
						else
						{
							print $sock $CMD . chr(3) . 4 . "Update installed by " . chr(2) . $nick . chr(2) . " -- restarting..." . chr(3) . "\r\n";
							sleep(10);

							if ( !do_restart("I'm being overhauled.") )
							{
								queuemsg(3, "$replymode $nick :There was an error during restart.");
								queuemsg(3, $CMD . chr(3) . 4 . "Update failed." . chr(3));
							}
						}
					}
					else
					{
						queuemsg(3,"$replymode $nick :$update");
					}
				}
			}
			elsif ( $line =~ s/^reload *//i && is_admin($nick) )
			{
				if ( $line =~ /warm/i )
				{
					%conf = load_config($config);
					queuemsg(3,$CMD . chr(3) . 2 . "Configuration reloaded by " . chr(2) . $nick . chr(2) . chr(3));
					queuemsg(3,"$replymode $nick :configuration reloaded.");
				}
				elsif ( $line =~ /cold/i )
				{
					queuemsg(1,"QUIT :cold reload requested by $nick (be back in about $conf{timeout} seconds).");
					%conf = load_config($config);
				}
				else
				{
					queuemsg(3,"$replymode $nick :error: missing or incorrect argument(s), try 'help reload'");
				}
			}
			elsif ( $line =~ s/^die *//i && is_admin($nick) )
			{
				my $sock = $server{socket};
				print $sock $CMD . chr(3) . 4 . "Shutting down on the order of " . chr(2) . $nick . chr(2) . chr(3) . "\r\n";
				print $sock "QUIT :" . $line . "\r\n";

				sleep(3);
				exit(0);
			}
			elsif ( $line =~ s/^nick *//i && is_admin($nick) )
			{
				if ( $line =~ /^([^\s]+)$/ )
				{
					queuemsg(3,"NICK $1");
				}
				else
				{
					queuemsg(3,"$replymode $nick :error: missing or incorrect argument(s), try 'help nick'");
				}
			}
			elsif ( $line =~ s/^dcc *//i )
			{

				my $userip = 0;
				my $userport = 0;

				if ( $line =~ /^(\d+\.\d+\.\d+\.\d+|)$/ || $line =~ /^(\d+\.\d+\.\d+\.\d+|) (\d+)$/)
				{
					foreach ( @{$conf{dccips}} )
					{
						if ( $_ eq $1 )
						{
							$userip = $_;
						}
					}

					if ( $2 ) {
						$userport = $2;
					}
				}

				if ( $conf{dccenable} eq 0 )
				{
					queuemsg(3,"$replymode $nick :DCC is disabled by configuration.");
				}
				elsif ( !$userip )
				{
					queuemsg(3,"$replymode $nick :Invalid IP. You must select either of the following IP addresses: @{$conf{dccips}}.");
				}
				elsif ( $conf{dccport} && $userport )
				{
					queuemsg(3,"$replymode $nick :You cannot specify a DCC port. It has been fixed by configuration.");
				}
				else
				{

					my ($dccsock,$dccport) = init_dcc($userip,$userport);

					if ( $dccsock && $dccport )
					{
						my $code = gencode();
						queuemsg(3,"NOTICE \@$conf{reportchan} :$nick requested DCC, code is $code");
						my $dccip = unpack("N",inet_aton($userip));
						queuemsg(3,"PRIVMSG $nick :DCC CHAT chat $dccip $dccport");
						dcc($dccsock,$code,$data{clients}{$nick}{offset});
					}
					else
					{
						queuemsg(3,"$replymode $nick :Failed to initialize DCC");
					}
				}
			}
			elsif ( $line =~ s/^raw *//i && is_admin($nick) )
			{
				if ( $line =~ /^(.+)$/ )
				{
					if ( $conf{enableraw} )
					{
						queuemsg(3,"$1");
					}
					else
					{
						queuemsg(3,"$replymode $nick :This command is disabled (by configuration).");
					}
				}
				else
				{
					queuemsg(3,"$replymode $nick :error: missing or incorrect argument(s), try 'help raw'");
				}
			}
			elsif ( $line =~ /^Please wait while checking your identity.../ )
			{
				# Ignore
			}
			else
			{
				queuemsg(3,"$replymode $nick :Unknown command '$line', try 'help'");
			}
		}
		elsif ( $line =~ /^NICK :(.*)$/ )
		{
			my $newnick = $1;
			if ( $nick =~ /^$data{nick}$/i )
			{
				$data{nick} = $newnick;
			}
			else
			{
				$data{clients}{$newnick} = $data{clients}{$nick};
				delete $data{clients}{$nick};
			}
		}
		elsif ( $line =~ /^QUIT/ )
		{
			delete $data{clients}{$nick};
		}
		elsif ( $line =~ /^PART :?([^\s]+)/ )
		{
			# Mark the user as parted from this channel.
			$data{clients}{$nick}{lc($1)} = 0;

			# If the user is not present on neither channel, delete it.
			if ( !$data{clients}{$nick}{lc($conf{reportchan})} && !$data{clients}{$nick}{lc($conf{operchan})} )
			{
				delete $data{clients}{$nick};
				logdeb("PART: $nick has left all channels. Deleting.");
			}
		}

	}
	elsif ( $line =~ s/^:((\w|\.|\-|\_)+) //i )
	{

		my $logline = $line;

		if ( $logline =~ s/^NOTICE \* ://i )
		{
			if ( $logline =~ /^\*\*\* Notice -- (BOUNCE or )*HACK\((\d+)\): (.*) \[(\d+)\]$/i )
			{
				# hack_type:timestamp:msg
				writemsg("hack","$2:$4:$3");
			}
			elsif ( $logline =~ /Client connecting: (.*) \((.*)\) \[(.*)\] \{(.*)\} \[(.*)\] <(.*)>$/ )
			{
				# nick:host:[ip]:numeric:class:rname/reason
				writemsg("connexit","CONN:$1:$2:[$3]:$6:$4:$5");

				# Log number of connections.
				$data{notice}{more}++;
				$data{lusers}{locusers}++;
				my $time = time;
				my $ip_type = is_ipv6($3) ? 'ipv6' : 'ipv4';
				$data{notice}{$ip_type}{$time}++;				
			}
			elsif ( $logline =~ /Client exiting: (.*) \((.*)\) \[(.*)\] \[(.*)\] <(.*)>$/ )
			{
				# nick:host:[ip]:numeric:class:rname/reason
				writemsg("connexit","EXIT:$1:$2:[$4]:$5::$3");

				# Log number of connections.
				$data{notice}{less}++;
				$data{lusers}{locusers}--;
				my $time = time;
				my $ip_type = is_ipv6($4) ? 'ipv6' : 'ipv4';
				$data{notice}{$ip_type}{$time}--;
			}
			elsif ( $logline =~ /\*\*\* Notice -- (.*) adding (local|global) GLINE for (.*), expiring at (\d+): (.*)/i )
			{
				# gline_type:who:user@host:expire
				if ( $2 eq 'local' )
				{
					queuemsg(3,$CMD . chr(2) . "LOCGLINE" . chr(2) . " for $3 set by " . chr(2) . $1. chr(2) . " ($5)");
				}
				writemsg("gline","$2:$1:$3:$4:$5");
			}
			elsif ( $logline =~ s/^\*\*\* Notice -- //i )
			{
				writemsg("notice",$logline);
			}
		}
		# server stuff

		if ( $line =~ /^(376|422) /  )
		{
			# end of MOTD 376 or MOTD file missing 422
			queuemsg(1,"OPER $conf{operuser} $conf{operpass}");
		}
		elsif ( $line =~ /^002 $data{nick} :Your host is (.*), running version/ )
		{
			$data{servername} = $1;
			$data{servername} =~ tr/[A-Z]/[a-z]/;
		}
		elsif ( $line =~ /^381 / )
		{
			# OPER done
			queuemsg(1,"MODE $data{nick} +ids 65535");
			if ( $conf{chankey} )
			{
				if ( $conf{operchan} ne '' ) { queuemsg(1,"JOIN $conf{operchan} $conf{chankey}"); } 
				queuemsg(1,"JOIN $conf{reportchan} $conf{chankey}");
			}
			else
			{
				if ( $conf{operchan} ne '' ) { queuemsg(1,"JOIN :$conf{operchan}"); } 
				queuemsg(1,"JOIN :$conf{reportchan}");
			}
		}
		elsif ( $line =~ /^(471|472|473|474|475) $data{nick} ((\&|\#)\w+)/i  )
		{
			# Unable to join channel, OVERRIDE it !
			queuemsg(1,"JOIN $2 :OVERRIDE");
		}
		elsif ( $line =~ /^433 / )
		{
			# nickname already in use.
			$data{nick} = get_nick();
			queuemsg(1,"NICK $data{nick}");
		}
#		elsif ( $line =~ /^491|464 / )
#		{
#			# No O:Line
#			logmsg("No O:Line. Exiting.");
#			exit;
#		}
		elsif ( $line =~ /^251 $data{nick} :There are (\d+) users and (\d+) invisible/i )
		{
			my $total = $1 + $2;
			$data{lusers}{glousers} = $total;
		}
		elsif ( $line =~ /^253 $data{nick} (\d+) :/i )
		{
			$data{lusers}{unknown} = $1;
		}
		elsif ( $line =~ /^254 $data{nick} (\d+) :/i )
		{
			$data{lusers}{channels} = $1;
		}
		elsif ( $line =~ /^255 $data{nick} :I have (\d+) clients/i )
		{
			$data{lusers}{locusers} = $1;
		}
		elsif ( $line =~ /^303 $data{nick} :(.*)/i )
		{
			my %taken;
			foreach( split(/ /,$1) )
			{ $taken{$_} = 1; }

			foreach ( @{$conf{nicks}} )
			{
				last if $_ eq $data{nick} ;

				if ( ! exists $taken{$_} )
				{
					queuemsg(1,"NICK $_");
					last;
				}
			}

		}
		# We are joning an empty channel. Set modes.
		elsif ( $line =~ /^353 $data{nick} = ($conf{reportchan}|$conf{operchan}) :\@$data{nick}$/i )
		{
			my $channel = $1;
			$data{channels}{lc($channel)}{isop} = 1;

			if ( $data{lusers}{maxusers} && !$conf{hubmode} && !$conf{multimode} ) {
				queuemsg(1,"MODE $channel +l $data{lusers}{maxusers}");
			}

			if ( $conf{chanmode} =~ /k/ )
			{
				queuemsg(1,"MODE $channel $conf{chanmode} $conf{chankey}");
			}
			elsif ( $conf{chanmode} )
			{
				queuemsg(1,"MODE $channel $conf{chanmode}");
			}
		}
		elsif ( $line =~ s/^354 $data{nick} //i )
		{
			if ( $line =~ /^([^\s]+) ((\.|\:|\w)+) ((\w|\-|\:|\_|\.)+) ([^\s]+) ((\w|\@|\<|\+|\-|\*)+) (\d+) (\w+) :(.*)$/i )
			{
				$data{autoid}++;
				my $autoid = $data{autoid};

				$data{who}{$autoid}{user}  = $1;
				$data{who}{$autoid}{ip}    = $2;
				$data{who}{$autoid}{host}  = $4;
				$data{who}{$autoid}{nick}  = $6;
				$data{who}{$autoid}{mode}  = $7;
				$data{who}{$autoid}{idle}  = $9;
				$data{who}{$autoid}{xuser} = $10;
				$data{who}{$autoid}{rname} = $11;
				open(WHO,">>$conf{path}/var/users.tmp");
				print WHO "$1	$2	$4	$6	$9	$10	$11	$7\n";
				close(WHO);
			}
			# This regex captures WHO queries for opers on the server.
			elsif ( $line =~ /^(?!$data{nick})([^\s]+)$/i && $conf{chaninvite} )
			{
				if ( !$data{clients}{$1}{lc($conf{reportchan})} )
				{ queuemsg(2,"INVITE $1 $conf{reportchan}"); }

				if ( $conf{operchan} ne '' && !$data{clients}{$1}{lc($conf{operchan})} )
				{ queuemsg(2,"INVITE $1 $conf{operchan}"); }
			}
			# This regex captures WHO queries for accounts.
			# This is not in use if account-notify is active.
			elsif ( $line =~ /^([^\s]+) (\w+)$/i )
			{
				if ( $2 ne 0 )
				{
					$data{clients}{$1}{account} = $2;
				}
			}
			# This regex is meant to capture both:
			# - WHO <channel> xc%nifac
			# - WHO <nick> x%nifa
			# $channel is 0 if it's a query for a user.
			elsif ( $line =~ /^(?:([&\#][^\s]+)\s)?([^\s]+) (?!$data{nick})([^\s]+) ((\*|\@|\w)+) ([^\s]+)$/i )
			{
				my ($channel, $ip, $opernick, $modes, $account) = ($1 // 0, $2, $3, $4, $6);
				my $giveOps = 0;
				my $doKick = 1;

				logdeb("WHO: $channel - $ip - $opernick - $modes - $account");
				# Register the user's presence on the channel.
				if ( $channel ne "0" )
				{
					$data{clients}{$opernick}{lc($channel)} = 1;
				}

				if ( lc($channel) eq lc($conf{reportchan}) )
				{
					$data{ready} = 1;
				}

				# Request offset if we haven't already.
				if ( !exists $data{clients}{$opernick}{offset} )
				{
					queuemsg(2,"PRIVMSG $opernick :TIME");
					queuemsg(2,"NOTICE $opernick :Please wait while checking your identity...");
					$data{clients}{$opernick}{offset} = 0;
				}

				my $ip_version = ($ip =~ /:/) ? 6 : 4;
				foreach ( @{$conf{ippermit}} )
				{
					my $block_version = ($_ =~ /:/) ? 6 : 4;

					# Normalise single IPs to CIDR format
    					my $cidr = $_;
    					if ($cidr !~ /\/\d+$/)
					{ $cidr .= ($_ =~ /:/) ? "/128" : "/32"; }

					if ( $ip_version != $block_version )
					{ next; }
					
					if ( Net::CIDR::cidrlookup($ip,$cidr) )
					{ 
						$doKick = 0;
						$giveOps = 1;
						last;
					}
				}

				if ( $modes =~ /\*/ )
				{
					# is oper
					$data{clients}{$opernick}{oper} = 1;

					if ( $account ne "0" )
					{ $data{clients}{$opernick}{account} = $account; }

					$doKick = 0;
					$giveOps = 1;
				}

				if ( $modes =~ /\@/ && $channel ne "0" )
				{
					$giveOps = 0;
				}

				if ( $doKick )
				{
					# is not oper nor permitted
					if ( $channel ne "0" )
					{
						queuemsg(2,"KICK $channel $opernick :You have no right to be in this channel!");
						$data{clients}{$opernick}{lc($channel)} = 0;
					}
					else
					{
						if ( $data{clients}{$opernick}{lc($conf{reportchan})} )
						{
							queuemsg(2,"KICK $conf{reportchan} $opernick :You have no right to be in this channel!");
							$data{clients}{$opernick}{lc($conf{reportchan})} = 0;
						}

						if ( $conf{operchan} ne '' && $data{clients}{$opernick}{lc($conf{operchan})})
						{
							queuemsg(2,"KICK $conf{operchan} $opernick :You have no right to be in this channel!");
							$data{clients}{$opernick}{lc($conf{operchan})} = 0;
						}
					}

					# If the user is not present on neither channel, delete it.
					if ( !$data{clients}{$opernick}{lc($conf{reportchan})}
						&& ( $conf{operchan} eq '' || !$data{clients}{$opernick}{lc($conf{operchan})} ) )
					{
						delete $data{clients}{$opernick};
						logdeb("KICK: $opernick has left all channels. Deleting.");
					}
				}
				elsif ( $giveOps )
				{
					if ( $channel ne "0" )
					{
						queuemsg(2,"MODE $channel +o $opernick") if $data{channels}{lc($channel)}{isop};
					}
					else
					{
						if ( $data{channels}{lc($conf{reportchan})}{ison}
							&& $data{clients}{$opernick}{lc($conf{reportchan})}
							&& $data{channels}{lc($conf{reportchan})}{isop} ) 
						{
							queuemsg(2,"MODE $conf{reportchan} +o $opernick");
						}

						if ( $conf{operchan} ne ''
							&& $data{channels}{lc($conf{operchan})}{ison}
							&& $data{clients}{$opernick}{lc($conf{operchan})}
							&& $data{channels}{lc($conf{operchan})}{isop} ) 
						{
							queuemsg(2,"MODE $conf{operchan} +o $opernick");
						}
					}
				}
			}
		}
		elsif ( $line =~ /^315 $data{nick} / )
		{
			# end of WHO
			if ( !$data{rfs} && $data{ready} )
			{ 
				queuemsg(2,$CMD . chr(3) . 2 . chr(2) . "Sentinel" . chr(2) . " v$conf{version}, ready." . chr(3));
				$data{rfs} = 1;
				queuemsg(2,"WHO $data{servername} xo%n");
			}

			if ( !$conf{hubmode} && $conf{locglineaction} !~ /disable/i )
			{
				$data{status}{who} = 1;
				copy("$conf{path}/var/users.tmp", "$conf{path}/var/users.txt");
			}
		}
		elsif ( $line =~ s/^213 $data{nick} C //i )
		{
			my ($hub, undef, undef) = split(/ /,$line);
			$hub =~ tr/[A-Z]/[a-z]/;
			if ( !exists $data{clines}{$hub} )
			{
				$data{clines}{$hub} = "n/a";
				$data{last}{rping}{$hub} = 0;
			}
		}
		elsif ( $line =~ s/^211 $data{nick} ((\w|\d|\.)+) (\d+) //i )
		{
			my $server = $1;
			$server =~ tr/[A-Z]/[a-z]/;
			my $sendq = $3;

			if ( $server =~ /$conf{networkdomain}/i )
			{
				$data{uplinks}{$server} = $sendq;
			}
		}
		elsif ( $line =~ s/^236 $data{nick} //i )
		{
			# STATS v
			# Servername Uplink Flags Hops Numeric/Numeric Lag RTT Up Down Clients/Max Proto LinkTS Info    
			$line =~ s/( |	)+/ /g;
			my ( $srcsrv,$dstsrv,$flags,$hops,$numeric1,$numeric2,$lag,$rtt,$up,$down,$clients,$maxclients,$proto,$linkts,$info ) = split(/ /,$line);
			$srcsrv =~ tr/[A-Z]/[a-z]/;
			$dstsrv =~ tr/[A-Z]/[a-z]/;

			if ( $srcsrv =~ /servername/ )
			{
				# ignore;
			}
			else
			{
				$data{statsv}{$srcsrv}{uplink}   = $dstsrv;
				$data{statsv}{$srcsrv}{users}    = $clients;
				$data{statsv}{$srcsrv}{maxusers} = $maxclients;
				$data{statsv}{$srcsrv}{linkts}   = $linkts;
				$data{statsv}{$srcsrv}{hub}      = 0;

				if ( $flags =~ /H/ )
				{
					$data{statsv}{$srcsrv}{hub} = 1;
				}
			}

			if ( $dstsrv =~ /$data{servername}/i && $srcsrv !~ /$data{servername}/i && !exists $data{uplinks}{$srcsrv} )
			{
				$data{uplinks}{$srcsrv} = "n/a";
			}
		}
		elsif ( $line =~ /^219 $data{nick} (c|v|l) /i )
		{
			# end of STATS

			if ( $1 =~ /c/i )
			{
				$data{time}{statsc} = time;
				$data{status}{statsc} = 1;
			}
			elsif ( $1 =~ /v/i )
			{
				$data{time}{statsv} = time;
				$data{status}{statsv} = 1;
			}
			elsif ( $1 =~ /l/i )
			{
				$data{time}{statsl} = time;
				$data{status}{statsl} = 1;
				$data{status}{sqwarn} = 1;
			}
		}
		elsif ( $line =~ /^RPONG $data{nick} (.*) (\d+) :/ )
		{
			my $srv = $1;
			my $rping = $2;
			$srv =~ tr/[A-Z]/[a-z]/;

			$data{clines}{$srv} = $2;
			$data{time}{rping} = time;
			$data{status}{rping} = 1;
			$data{status}{rpwarn} = 1;
		}
		elsif ( $line =~ s/^NOTICE (.*) :\*\*\* Notice -- //i )
		{
			if ( $line =~ /^Failed OPER attempt by (.*) \((.*)\)$/i )
			{
				my $failnick = $1;
				my $failhost = $2;

				$data{operfail}{$failhost}++;
				queuemsg(2,$CMD . chr(3) . 4 . chr(2) . "OPER Failed" . chr(2) . " for $failnick\!$failhost ($data{operfail}{$failhost})" . chr(3));
				if ( $data{operfail}{$failhost} >= $conf{operfailmax} )
				{
					delete $data{operfail}{$failhost};
					if ( $conf{operfailaction} =~ /kill/i )
					{
						queuemsg(2,"KILL $failnick :$conf{operfailreason}");
					}
					elsif ( $conf{operfailaction} =~ /gline/i )
					{
						queuemsg(2,"GLINE +$failhost $conf{operfailgtime} :$conf{operfailreason}");
					}
				}
				else
				{
					queuemsg(2,"NOTICE $failnick :$conf{operfailwarn}");
				}
			}
			elsif ( $line =~ /^(.*) \((.*)\) is now operator \((.)\)$/ )
			{
				my $opernick = $1;
				my $operhost = $2;
				my $opermode = "GlobalOPER";
				if ( $3 =~ /o/ )
				{
					$opermode = "LocalOPER";
				}

				if ( $data{channels}{lc($conf{reportchan})}{ison} )
				{
					queuemsg(2,$CMD . chr(3) . 2 . "$opernick\!$operhost is now ". chr(31) ."$opermode" . chr(31) . chr(3));
					if ( !($opernick =~ /^$data{nick}$/i ) && $conf{chaninvite} )
					{
						queuemsg(2,"INVITE $opernick $conf{reportchan}");
					}
				}

				if ( $data{channels}{lc($conf{operchan})}{ison} 
					&& !($opernick =~ /^$data{nick}$/i )
					&& $conf{chaninvite} )
				{
					queuemsg(2,"INVITE $opernick $conf{operchan}");
				}
			}
			elsif ( $line =~ /^Net junction: ([^\s]+) ([^\s]+)$/ )
			{
				queuemsg(3,$CMD . chr(3) . 2 . chr(2) . "NETJOIN:" . chr(2) ." $1 -- $2" . chr(3));

				my $notified = 0;
				my $server1 = $1;
				my $server2 = $2;

				if ( ( $server1 =~ /$data{servername}/i || $server2 =~ /$data{servername}/i ) && $conf{pushlocsplit} !~ /off/i )
				{
					push_notify($conf{pushnetjoin}, "NETJOIN $server1 $server2");
					cancel_pushretry($conf{pushlocsplit},$server1,$server2);
					$notified = 1;
				}
				else
				{
					foreach ( keys %{$conf{splitlist}} )
					{
						if ( $server1 =~ /$_/i || $server2 =~ /$_/i )
						{
							push_notify($conf{pushnetjoin}, "NETJOIN $server1 $server2");
							cancel_pushretry($conf{splitlist}{$_},$server1,$server2);
							$notified = 1;
						}
					}
				}

				if ( $conf{pushnetall} !~ /off/i && !$notified )
				{
					push_notify($conf{pushnetjoin}, "NETJOIN $server1 $server2");
					cancel_pushretry($conf{pushnetall},$server1,$server2);
				}
			}
			elsif ( $line =~ /^Net break: ([^\s]+) ([^\s]+) \((.*)\)$/ )
			{
				queuemsg(3,$CMD . chr(3) . 4 . chr(2) . "NETQUIT:" . chr(2) . " $1 -- $2 ($3)" . chr(3));

				my $notified = 0;
				my $server1 = $1;
				my $server2 = $2;
				my $message = $3;

				if ( $server1 =~ /$data{servername}/i && exists $data{uplinks}{$server2} )
				{
					delete $data{uplinks}{$server2};
				}
				elsif ( $server2 =~ /$data{servername}/i && exists $data{uplinks}{$server1} )
				{
					delete $data{uplinks}{$server1};
				}

				if ( ( $server1 =~ /$data{servername}/i || $server2 =~ /$data{servername}/i ) )
				{
					push_notify($conf{pushlocsplit}, "NETQUIT $server1 $server2 ($message)",$server1,$server2);
					$notified = 1;
				}
				else
				{
					foreach ( keys %{$conf{splitlist}} )
					{
						if ( $server1 =~ /$_/i || $server2 =~ /$_/i )
						{
							push_notify($conf{splitlist}{$_}, "NETQUIT $server1 $server2 ($message)",$server1,$server2);
							$notified = 1;
						}
					}
				}

				if ( !$notified )
				{
					push_notify($conf{pushnetall}, "NETQUIT $server1 $server2 ($message)",$server1,$server2);
				}
			}
		}
		elsif ( $line =~ /NOTICE $data{nick} :Highest connection count: \d+ \((\d+) clients\)$/ && !$conf{hubmode} )
		{
			$data{lusers}{maxusers} = $1;
			$data{status}{lusers} = 1;
			if ( !$conf{multimode} )
			{
				if ( $data{channels}{lc($conf{reportchan})}{ison}
					&& $data{channels}{lc($conf{reportchan})}{limit} != $data{lusers}{maxusers} )
				{
					queuemsg(1,"MODE $conf{reportchan} +l $data{lusers}{maxusers}");
				}

				if ( $data{channels}{lc($conf{operchan})}{ison}
					&& $data{channels}{lc($conf{operchan})}{limit} != $data{lusers}{maxusers} )
				{
					queuemsg(1,"MODE $conf{operchan} +l $data{lusers}{maxusers}");
				}
			}
		}
		elsif ( $line =~ /^CAP ($data{nick}|\*) LS :(.*)/ )
		{
			foreach my $capab (split /\s+/, $2) {
				$cap{$capab} = 0;
				logdeb("Recognized CAP: $capab");
			}

			# Checking for account-notify and extended-join
			my $capReq;
			$capReq .= "account-notify " if exists $cap{'account-notify'};
			$capReq .= "extended-join " if exists $cap{'extended-join'};
			$capReq =~ s/\s+$//;

			if ( $capReq ne '' )
			{
				queuemsg(1, "CAP REQ :$capReq");
			}
		}
		elsif ( $line =~ /^CAP ($data{nick}|\*) ACK :(.*)/ )
		{
			foreach my $capab (split /\s+/, $2) {
				$cap{$capab} = 1;
				logdeb("Enabled CAP: $capab");
			}

			queuemsg(1, "CAP END");
		}
	}
	elsif ( $line =~ /^PING :(.*)/ )
	{
		queuemsg(1,"PONG :$1");
	}
	elsif ( $line =~ /^ERROR (.*)/ )
	{
		logmsg("ERROR from server: $1");
		queuemsg(1,"QUIT :ERROR FROM SERVER");
		delete $server{socket};
	}
}

sub get_nick
{
	my $nick = '';
	if ( $conf{nicks}[$conf{nickpos}] )
	{
		$nick = $conf{nicks}[$conf{nickpos}];
		$conf{nickpos}++;
	}
	else
	{
		$conf{nickpos}=0;
		$conf{nicksuffix}++;
		$nick = $conf{nicks}[$conf{nickpos}] . $conf{nicksuffix};
	}
	return $nick;
}

sub write_irc
{
	my $sock = $server{socket};
	my $msg;

	if ( $server{out1}[0] )
	{
		$msg  = shift(@{$server{out1}});
	}
	elsif ( $server{out2}[0] )
	{
		$msg = shift(@{$server{out2}});
	}
	elsif ( $server{out3}[0] )
	{
		$msg = shift(@{$server{out3}});
	}

	if ( $msg && $sock )
	{
		print $sock "$msg\r\n";
		logdeb("-> $msg");
	}
}

sub read_irc
{
	my $xdata = $server{data};
	if ( select($xdata, undef, undef, 0.05) )
	{
		if ( vec($xdata,fileno($server{socket}),1) )
		{
			my $tmp;
			sysread($server{socket},$tmp,262144);
			$server{bufin} .= $tmp;

			while( $server{bufin} =~ s/(.*)(\n)// )
			{
				my $line = $1;
				$line =~ s/(\r|\n)+$//;
				push(@{$server{in}},$line);
				if ( $line =~ /Client (connecting|exiting): / || $line =~ / 354 / ) { #ignore;
				} else { logdeb("<- $line"); }

			}
		}
	}
}

sub connect_irc
{
	$server{socket} = IO::Socket::INET->new (
		Proto		=> 'tcp',
		LocalAddr	=> $conf{vhost},
		PeerAddr	=> $conf{serverip},
		PeerPort	=> $conf{serverport},
		Blocking	=> 0,
		Reuse		=> 1,
	);

	if ( $server{socket} )
	{
		$server{data} = '';
		vec($server{data},fileno($server{socket}),1) = 1;
		return 1;
	}
	else
	{
		return 0;
	}
}

sub load_config
{
	my $config  = shift;

	if ( !$config )
	{
		logerr("syntax: $0 /path/to/configfile.conf");
		exit 1;
	}
	elsif ( $config =~ /^\// && -r "$config" && -f "$config" )
	{
		my %newconf;
		open(CONFIG,"$config");
		while(<CONFIG>)
		{
			chop;

			if ( /^((\w|_)+)(	| )+(.*)/ )
			{
				my $name = $1;
				my $value = $4;
				$name =~ tr/[A-Z]/[a-z]/;

				logdeb("CONFIG $name -> $value");

				if ( $name eq 'nick' )
				{
					foreach(split(/,/,$value))
					{
						push(@{$newconf{nicks}},$_);
					}
					$newconf{nickpos} = 0;
				}
				elsif ( $name eq 'admin' )
				{
					push(@{$newconf{admins}},$value);
				}
				elsif ( $name eq 'permitip' )
				{
					push(@{$newconf{ippermit}},$value);
				}
				elsif ( $name eq 'rnameexcept' )
				{
					push(@{$newconf{rnamelist}},$value);
				}
				elsif ( $name eq 'ipexcept' )
				{
					push(@{$newconf{iplist}},$value);
				}
				elsif ( $name eq 'pushuser' )
				{
					push(@{$newconf{usertoken}},$value);
				}
				elsif ( $name eq 'pushnetsplit' )
				{
					my ($server,$priority) = split(/ /,$value,2);
					$newconf{splitlist}{$server} = $priority;
				}
				elsif ( $name eq 'dcclisten' )
				{
					if ( $value =~ /^(\d+\.\d+\.\d+\.\d+|)$/ )
					{
						push(@{$newconf{dccips}},$value);
					}
				}
				$newconf{$name}=$value;
			}
		}
		close(CONFIG);

		# checking config settings

		my @ECONF;

		if ( !( $newconf{serverip} =~ /^\d+\.\d+\.\d+\.\d+$/ ) )
		{ push(@ECONF,"SERVERIP"); }
		if ( !( $newconf{serverport} =~ /^\d+$/ ) )
		{ push(@ECONF,"SERVERPORT"); }
		if ( !( $newconf{vhost} =~ /^(\d+\.\d+\.\d+\.\d+|)$/ ) )
		{ push(@ECONF,"VHOST"); }
		if ( !( $newconf{hubmode} =~ /^0|1$/ ) )
		{ push(@ECONF,"HUBMODE"); }
		if ( !( $newconf{multimode} =~ /^0|1$/ ) )
		{ push(@ECONF,"MULTIMODE"); }
		if ( !( $newconf{timeout} =~ /^\d+$/ ) )
		{ push(@ECONF,"TIMEOUT"); }
		if ( !( $newconf{dccenable} =~ /^\d+$/ ) )
		{ push(@ECONF,"DCCENABLE"); }
		if ( !( $newconf{dccport} =~ /^\d+$/ ) )
		{ push(@ECONF,"DCCPORT"); }
		if ( !( $newconf{nick} =~ /^(,|[^\s])+$/ ) )
		{ push(@ECONF,"NICK"); }
		if ( !( $newconf{ident} =~ /^\w+$/ ) )
		{ push(@ECONF,"IDENT"); }
		if ( !( $newconf{operuser} =~ /^.+$/ ) )
		{ push(@ECONF,"OPERUSER"); }
		if ( !( $newconf{operpass} =~ /^.+$/ ) )
		{ push(@ECONF,"OPERPASS"); }
		if ( !( $newconf{reportchan} =~ /^(\&|\#)[^\s]+$/ ) )
		{ push(@ECONF,"REPORTCHAN"); }
		if ( !( $newconf{operchan} =~ /^$|^(\&|\#)[^\s]+$/ ) )
		{ push(@ECONF,"OPERCHAN"); }
		if ( !( $newconf{chankey} =~ /^(([^\s]+)|)$/ ) )
		{ push(@ECONF,"CHANKEY"); }
		if ( !( $newconf{chanmode} =~ /^(\+[kimnpstrDrcC]+)?$/ ) )
		{ push(@ECONF,"CHANMODE"); }
		if ( !( $newconf{chaninvite} =~ /^0|1$/ ) )
		{ push(@ECONF,"CHANINVITE"); }
		if ( !( $newconf{networkdomain} =~ /^(\w|\.|\-|\_)+$/ ) )
		{ push(@ECONF,"NETWORKDOMAIN"); }

		if ( !( $newconf{trafficreport} =~ /^0|1$/ ) )
		{ push(@ECONF,"TRAFFICREPORT"); }

		if ( $newconf{operfailmax} =~ /^\d+$/ )
		{
			if ( $newconf{operfailmax} > 0 ) {
				if ( !( $newconf{operfailwarn} =~ /^.+$/ ) )
				{ push(@ECONF,"OPERFAILWARN"); }
				if ( !( $newconf{operfailaction} =~ /^KILL|GLINE$/i ) )
				{ push(@ECONF,"OPERFAILACTION"); }
				if (
					$newconf{operfailaction} =~ /GLINE/i
				&&
					!( $newconf{operfailgtime} =~ /^\d+$/ )
				)
				{ push(@ECONF,"OPERFAILGTIME"); }
				if ( !( $newconf{operfailreason} =~ /^.+$/ ) )
				{ push(@ECONF,"OPERFAILREASON"); }
			}
		} else { push(@ECONF,"OPERFAILMAX"); }

		if ( !( $newconf{reportenable} =~ /^0|1$/ ) )
		{ push(@ECONF,"REPORTENABLE"); }

		if ( !( $newconf{reportcmd} =~ /^PRIVMSG|ONOTICE$/i ) )
		{ push(@ECONF,"REPORTCMD"); }

		if ( !( $newconf{locglineaction} =~ /^GLINE|WARN|DISABLE$/i ) )
		{ push(@ECONF,"LOCGLINEACTION"); }
		if ( !( $newconf{rnameglinetime} =~ /^\d+$/ ) )
		{
			push(@ECONF,"RNAMEGLINETIME");
		}
		else
		{
			if ( !($newconf{rnameglinelimit} =~ /^\d+$/ ) )
			{ push(@ECONF,"RNAMEGLINELIMIT"); }
		}

		if ( !( $newconf{ipglinetime} =~ /^\d+$/ ) )
		{
			push(@ECONF,"IPGLINETIME");
		}
		else
		{
			if ( !($newconf{ipglinelimit} =~ /^\d+$/ ) )
			{ push(@ECONF,"IPGLINELIMIT"); }
		}

		if ( !( $newconf{ceuserthres} =~ /^\d+$/ ) )
		{ push(@ECONF,"CEUSERTHRES"); }
		if ( !( $newconf{cetimethres} =~ /^\d+$/ ) )
		{ push(@ECONF,"CETIMETHRES"); }

		if ( !( $newconf{cputhres} =~ /^\d+$/ ) )
		{ push(@ECONF,"CPUTHRES"); }

		if ( !( $newconf{fwinterval} =~ /^\d+$/ ) )
		{ push(@ECONF,"FWINTERVAL"); }
		if ( !( $newconf{fwkbps} =~ /^\d+$/ ) )
		{ push(@ECONF,"FWKBPS"); }
		if ( !( $newconf{fwpps} =~ /^\d+$/ ) )
		{ push(@ECONF,"FWPPS"); }

		if ( !( $newconf{rname} =~ /^.+$/ ) )
		{ push(@ECONF,"RNAME"); }

		if ( !( $newconf{pushenable} =~ /^0|1$/ ) )
		{ push(@ECONF,"PUSHENABLE"); }

		if ( defined $newconf{pushnetsplit} )
		{
			if ( !( $newconf{pushnetsplit} =~ /^(?:(?:\w|\.)+ (?:\-2|\-1|0|1|2))?$/ ) )
			{ push(@ECONF,"PUSHNETSPLIT"); }
		}

		if ( !( $newconf{pushnetall} =~ /^off|\-2|\-1|0|1|2$/i ) )
		{ push(@ECONF,"PUSHNETALL"); }
		if ( !( $newconf{pushnetjoin} =~ /^off|\-2|\-1|0|1|2$/i ) )
		{ push(@ECONF,"PUSHNETJOIN"); }
		if ( !( $newconf{pushexpire} =~ /^\d+$/ ) )
		{ push(@ECONF,"PUSHEXPIRE"); }
		if ( !( $newconf{pushretry} =~ /^([3-9]\d|[1-9]\d{2,})$/ ) )
		{ push(@ECONF,"PUSHRETRY"); }

		if ( !( $newconf{pushtoken} =~ /^.+$/ ) )
		{ push(@ECONF,"PUSHTOKEN"); }

		if ( !( $newconf{pushlocsplit} =~ /^off|\-2|\-1|0|1|2$/i ) )
		{ push(@ECONF,"PUSHLOCSPLIT"); }
		if ( !( $newconf{pushsendq} =~ /^off|\-2|\-1|0|1|2$/i ) )
		{ push(@ECONF,"PUSHSENDQ"); }
		if ( !( $newconf{pushrping} =~ /^off|\-2|\-1|0|1|2$/i ) )
		{ push(@ECONF,"PUSHRPING"); }
		if ( !( $newconf{pushuserchange} =~ /^off|\-2|\-1|0|1|2$/i ) )
		{ push(@ECONF,"PUSHUSERCHANGE"); }
		if ( !( $newconf{pushcpu} =~ /^off|\-2|\-1|0|1|2$/i ) )
		{ push(@ECONF,"PUSHCPU"); }
		if ( !( $newconf{pushfw} =~ /^off|\-2|\-1|0|1|2$/i ) )
		{ push(@ECONF,"PUSHFW"); }

		if ( !( $newconf{rpingwarn} =~ /^.+$/ ) )
		{ push(@ECONF,"RPINGWARN"); }

		if ( !( $newconf{sendqwarn} =~ /^.+$/ ) )
		{ push(@ECONF,"SENDQWARN"); }

		if ( $newconf{version} ne $version )
		{ push(@ECONF,"VERSION MISMATCH!"); }

		if ( !-w "$newconf{path}" || !-d "$newconf{path}" )
		{ push(@ECONF,"PATH, cannot write to $newconf{path}"); }

		if ( @ECONF )
		{
			foreach(@ECONF)
			{
				logerr("Error in configuration file for directive \"$_\"");
			}
			logerr("Aborting...");
			exit 1;
		}

		if ( $newconf{trafficreport} )
		{
			# guessing the OS
			my $os = `uname -s`; chop $os;
			my $rel = `uname -r`; chop $rel;

			if ( $os =~ /FreeBSD/i )
			{
				$newconf{trafficsub} = 'fbsd';
			}
			elsif ( $os =~ /Linux/i )
			{
				$newconf{trafficsub} = 'linux';
			}
			else
			{
				logmsg("TRAFFICREPORT: $os-$rel is NOT supported. Feature disabled.");
				$newconf{trafficreport} = 0;
			}
		}

		if ( $newconf{reportcmd} =~ /privmsg/i )
		{
			$CMD = "PRIVMSG $newconf{reportchan} :";
		}
		elsif ( $newconf{reportcmd} =~ /onotice/i )
		{
			$CMD = "NOTICE \@$newconf{reportchan} :";
		}

		return %newconf;
	}
	else
	{
		logerr("cannot read file, aborting...");
		exit 1;
	}
}

sub logdeb
{
	if ( $debug )
	{
		printf("%s DEBUG : %s\n",unix2local(),(shift));
	}
}

sub logmsg
{
	if ( $debug || !exists $conf{path} )
	{
		printf("%s LOG   : %s\n",unix2local(),(shift));
	}
	else
	{
		open(LOGFILE,">>$conf{path}/var/debug.log");
		print LOGFILE sprintf("%s LOG   : %s\n",unix2local(),(shift));
		close(LOGFILE);
	}
}

sub logerr
{
	if ( $debug || !exists $conf{path} )
	{
		printf("%s ERROR : %s\n",unix2local(),(shift));
	}
	else
	{
		open(LOGFILE,">>$conf{path}/var/debug.err");
		print LOGFILE sprintf("%s ERROR : %s\n",unix2local(),(shift));
		close(LOGFILE);
	}
}

sub easytime {

	my $total = shift;
	my $sign = '';
	if ( $total =~ /^-/ )
	{
		$sign = '-';
		$total =~ s/^-//;
	}

	my $sec = $total % 60;
	$total = ($total-$sec)/60;

	my $min = $total % 60;
	$total = ($total-$min)/60;

	my $hour = $total % 24;
	$total = ($total-$hour)/24;

	my $day  = $total % 7;
	$total = ($total-$day)/7;

	my $week = $total;

	if    ($week) { return sprintf("%s%d" . "w" . "%d" . "d" . "%d" . "h",$sign,$week,$day,$hour); }
	elsif ($day)  { return sprintf("%s%d" . "d" . "%d" . "h" . "%d" . "m",$sign,$day,$hour,$min);  }
	else	  { return sprintf("%s%d" . "h" . "%d" . "m" . "%d" . "s",$sign,$hour,$min,$sec);  }

}

sub daemonize
{
	if ( defined ( my $pid = fork() ) )
	{
		if ( $pid )
		{
			# I'm daddy
			print "Sentinel v$conf{version} started (PID: $pid).\n";

			my $pidfile = File::Pid->new({
				file => $conf{path} . '/bin/sentinel.pid',
				pid => $pid,
			});   
			$pidfile->write;
   
			exit;
		}
		else
		{
			# I'm junior
			chdir "/";
			open STDIN, '/dev/null';
			open STDOUT, '>>/dev/null';
			open STDERR, '>>/dev/null';
			setsid;
			umask 0;
		}
	}
	else
	{
		print STDERR "Can't fork $!\n";
		exit 1;
	}
}

sub writemsg
{
	my $file = shift;
	my $msg  = shift;
	open(FILE,">>$conf{path}/var/$file.txt") || warn "Cannot write to $conf{path}/var/$file.txt";
	print FILE sprintf("%s %s\n",time,$msg);
	close(FILE);
}

sub guess_tz
{
	my $usertime = shift;
	$usertime =~ s/(	| )+/ /g;

	if ( $usertime =~ /GMT(\+|\-)(\d+)/ )
	{
		my $offset = "$1$2";
		return $offset * 3600;
	}
	elsif ( $usertime =~ /(\+|\-)(\d{4})/ )
	{
		my $offset = "$1$2";
		return $offset * 36;
	}
	# Fri, 26 Apr 2024 13:44:04 +0100
	elsif ( $usertime =~ /(\w{3}), (\d{1,2}) (\w{3}) (\d{4}) (\d+):(\d+):(\d+)$/ )
	{
		my $day = $2;
		my $mon = $3;
		my $year = $4;
		my $hour = $5;
		my $min  = $6;
		my $sec  = $7;

		$mon =~ s/jan/1/i;
		$mon =~ s/feb/2/i;
		$mon =~ s/mar/3/i;
		$mon =~ s/apr/4/i;
		$mon =~ s/may/5/i;
		$mon =~ s/jun/6/i;
		$mon =~ s/jul/7/i;
		$mon =~ s/aug/8/i;
		$mon =~ s/sep/9/i;
		$mon =~ s/oct/10/i;
		$mon =~ s/nov/11/i;
		$mon =~ s/dec/12/i;
		$mon--;

		return timegm($sec,$min,$hour,$day,$mon,$year) - time;
	}
	# Fri Apr 26 13:56:48 2024
	elsif ( $usertime =~ /(\w{3}) (\w{3}) (\d{1,2}) (\d+):(\d+):(\d+) (\d{4})$/ )
	{
		my $mon = $2;
		my $day = $3;
		my $hour = $4;
		my $min  = $5;
		my $sec  = $6;
		my $year = $7;

		$mon =~ s/jan/1/i;
		$mon =~ s/feb/2/i;
		$mon =~ s/mar/3/i;
		$mon =~ s/apr/4/i;
		$mon =~ s/may/5/i;
		$mon =~ s/jun/6/i;
		$mon =~ s/jul/7/i;
		$mon =~ s/aug/8/i;
		$mon =~ s/sep/9/i;
		$mon =~ s/oct/10/i;
		$mon =~ s/nov/11/i;
		$mon =~ s/dec/12/i;
		$mon--;

		return timegm($sec,$min,$hour,$day,$mon,$year) - time;
	}
	# 03/06/2024 15:44
	elsif ( $usertime =~ /(\d{2})\/(\d{2})\/(\d{4}) (\d+):(\d+)$/ )
	{
		my $day = $1;
		my $mon = $2;
		my $year = $3;
		my $hour = $4;
		my $min  = $5;

		$mon =~ s/jan/1/i;
		$mon =~ s/feb/2/i;
		$mon =~ s/mar/3/i;
		$mon =~ s/apr/4/i;
		$mon =~ s/may/5/i;
		$mon =~ s/jun/6/i;
		$mon =~ s/jul/7/i;
		$mon =~ s/aug/8/i;
		$mon =~ s/sep/9/i;
		$mon =~ s/oct/10/i;
		$mon =~ s/nov/11/i;
		$mon =~ s/dec/12/i;
		$mon--;

		return timegm(0,$min,$hour,$day,$mon,$year) - time;
	}
	# Fri 26th Apr 2024 03:07p
	elsif ( $usertime =~ /(\w{3}) (\d{1,2})(\w{2}) (\w{3}) (\d{4}) (\d+):(\d+)(\w{1})$/ )
	{
		my $day = $2;
		my $mon = $4;
		my $year = $5;
		my $hour = $6;
		my $min  = $7;

		$mon =~ s/jan/1/i;
		$mon =~ s/feb/2/i;
		$mon =~ s/mar/3/i;
		$mon =~ s/apr/4/i;
		$mon =~ s/may/5/i;
		$mon =~ s/jun/6/i;
		$mon =~ s/jul/7/i;
		$mon =~ s/aug/8/i;
		$mon =~ s/sep/9/i;
		$mon =~ s/oct/10/i;
		$mon =~ s/nov/11/i;
		$mon =~ s/dec/12/i;
		$mon--;

		if ( $8 eq "p")
		{
			$hour = $hour + 12;
		}

		return timegm(0,$min,$hour,$day,$mon,$year) - time;
	}
	else
	{
		logmsg("Failed to parse TIME response: $usertime");
		return 0;
	}
}

sub init_dcc
{
	my ($userip,$userport) = @_;
	my $dccport  = 0;
	if ( $conf{dccport} )
	{
		$dccport = $conf{dccport};
	}
	elsif ( $userport )
	{
		$dccport = $userport;
	}
	
	my $dccsock;

	if ( $dccport )
	{
#		$dccsock = IO::Socket::INET->new (
		$dccsock = new IO::Socket::INET (
			Proto		=> 'tcp',
			LocalPort	=> $dccport,
			LocalHost	=> $userip,
#			LocalAddr	=> $userip,
			Timeout		=> 30,
			Listen		=> 1,
			Reuse		=> 1 );
	}
	else
	{
		$dccsock = IO::Socket::INET->new (
			Proto		=> 'tcp',
			LocalAddr	=> $userip,
			Timeout		=> 10,
			Listen		=> 1,
			Reuse		=> 1 );
	}

#	$SIG{INT} = sub { $dccsock->close(); exit 0; }

	if ( $dccsock && !$@ )
	{
		return ( $dccsock, $dccsock->sockport() );
	}
	else
	{
		return 0;
	}
}

sub dcc
{
	my $socket = shift;
	my $code   = shift;
	my $offset = shift;

	my $dcctimeout = 3600;
	my $dccwarn    = 3300;
	my $lastin     = time;
	my $warned     = 0;

	# lets go away now.
	if ( !( my $pid = fork() ) )
	{
		# I am junior
		
		if ( my $client = $socket->accept() )
		{
			shutdown($socket,2);

			my $wdata;
			vec($wdata,fileno($client),1) = 1;

			print $client "Password?\n";
			my $auth = 0;

			open(DCCLOG,">>$conf{path}/var/dcc.log");
			print DCCLOG sprintf("[%s] %s: connect\n",unix2local(),$client->peerhost);

			while(fileno($client))
			{
				my $xdata = $wdata;
				my $line  = '';
				if ( select($xdata, undef, undef, 0.25) )
				{
					if (vec($xdata, fileno($client), 1))
					{
						$line = <$client>;
						$line =~ s/(\r|\n)+$//;
						if ( $line =~ /./ ) { # got something...
						}
						else
						{
							print DCCLOG sprintf("[%s] %s: connection reset by peer\n",unix2local(),$client->peerhost);
							exit;
						}
					}
				}
				if ( $line )
				{
					print DCCLOG sprintf("[%s] %s: command: %s\n",unix2local(),$client->peerhost,$line);
					$lastin = time;
					$warned = 0;

					$line =~ s/  / /g;
					$line =~ s/^ //;
					$line =~ s/ $//;

					if ( !$auth )
					{
						if ( $line eq $code )
						{
							$auth = 1;
							print DCCLOG sprintf("[%s] %s: authenticated\n",unix2local(),$client->peerhost);
							print $client "Sentinel v$conf{version} DCC Interface\n";

							my $eoff = easytime($offset);
							if ( $eoff =~ /^\d/ ) { $eoff = "+$eoff"; }
							print $client "Your GMT offset is $eoff\n";
							print $client "note: you can change your GMT offset at any time with the 'TZ' command, see 'HELP TZ'\n";
							print $client "\n";
							print $client chr(2) . "WARNING: please choose carefully the search options. Otherwise you risk to be flooded by thousands of messages!" . chr(2) . "\n";
							print $client "\n";
							print $client "enter 'HELP' for help ;)\n";
						}
						else
						{
							print DCCLOG sprintf("[%s] %s: wrong password\n",unix2local(),$client->peerhost);
							print $client "password mismatch, bye\n";
							shutdown($client,2);
							exit;
						}
					}
					elsif ( $line =~ s/^help *//i )
					{
						if ( $line =~ /^tz$/i )
						{
							print $client "HELP: command 'TZ'\n";
							print $client "change the GMT offset, in order to display all timestamps in your local time.\n";
							print $client "syntax  : TZ <+/-><OFFSET>\n";
							print $client "example : TZ +1\n";
							print $client "Will set you in GMT+1\n";
						}
						elsif ( $line =~ /^notice$/i )
						{
							print $client "HELP: command 'NOTICE'\n";
							print $client "commands syntax.\n";
							print $client "syntax  : NOTICE <match> [optional match]\n";
							print $client "example : NOTICE KILL spale\n";
							print $client "shows all servers notices comtaining 'KILL' and 'spale'\n";
						}
						elsif ( $line =~ /^help$/i )
						{
							print $client "HELP: command 'HELP'\n";
							print $client "the commands syntax.\n";
							print $client "syntax  : HELP [command]\n";
							print $client "example : HELP TZ\n";
							print $client "shows the syntax of the 'TZ' command.\n";
						}
						elsif ( $line =~ /^hack$/i )
						{
							print $client "HELP: command 'HACK'\n";
							print $client "logs of HACK notices matching a given string.\n";
							print $client "syntax  : HACK <string>\n";
							print $client "example : HACK #channel\n";
							print $client "shows all HACK notices containing the string '#channel'.\n";
						}
						elsif ( $line =~ /^quit$/i )
						{
							print $client "HELP: command 'QUIT'\n";
							print $client "Ends the DCC session.\n";
							print $client "syntax  : QUIT\n";
						}
						elsif ( $line =~ /^gline$/i )
						{
							print $client "HELP: command 'GLINE'\n";
							print $client "logs of GLINE notices matching a given string.\n";
							print $client "syntax  : GLINE <string>\n";
							print $client "example : GLINE 10.20.30.40\n";
							print $client "shows all GLINE notices containing the string '10.20.30.40'.\n";
						}
						elsif ( $line =~ /^conn$/i )
						{
							print $client "HELP: command 'CONN'\n";
							print $client "last n connections/disconnections.\n";
							print $client "syntax  : CONN <number>\n";
							print $client "example : CONN 300\n";
							print $client "shows the last 300 connections/disconnections.\n";
						}
						elsif ( $line =~ /^scan$/i )
						{
							print $client "HELP: command 'SCAN'\n";
							print $client "scan the local users.\n";
							print $client "syntax  : SCAN <NICK|USER|HOST|IP|RNAME|XUSER||IDLE|MODE> <string>\n";
							print $client "note    : ? and * wildcards allowed.\n";
							print $client "example : SCAN RNAME *irc*\n";
							print $client "shows all the users having the string 'irc' in their realname field.\n";
						}
						elsif ( $line =~ /^clones$/i )
						{
							print $client "HELP: command 'CLONES'\n";
							print $client "scan the local users for similar entries.\n";
							print $client "syntax  : CLONES\n";
						}
						elsif ( $line =~ /^map$/i )
						{
							print $client "HELP: command 'MAP'\n";
							print $client "show a map of servers ordered by number of clients.\n";
							print $client "syntax  : MAP\n";
						}
						elsif ( $line =~ /^attack$/i )
						{
							print $client "HELP: command 'ATTACK'\n";
							print $client "shows information about possible attacks (mass user connect/quit).\n";
							print $client "syntax  : ATTACK <LIST|SHOW> [id]\n";
						}
						elsif ( $line =~ /^warnings$/i )
						{
							print $client "HELP: command 'WARNINGS'\n";
							print $client "shows the n last warnings.\n";
							print $client "syntax  : WARNINGS <number>\n";
							print $client "example : WARNINGS 50\n";
							print $client "shows the last 50 warnings.\n";
						}
						else
						{
							print $client "Available commands are: (use HELP <command> for more details)\n";
							print $client "HELP, TZ, HACK, CONN, GLINE, NOTICE, SCAN, CLONES, ATTACK, WARNINGS, MAP, QUIT\n";
						}
						
					}
					elsif ( $line =~ /^notice +(.*)$/i )
					{
						my $arg1 = $1;
						my $arg2 = '';

						if ( $arg1 =~ / / )
						{
							($arg1,$arg2) = split(/ /,$arg1);
						}

						$arg1 = wild2reg($arg1);
						$arg2 = wild2reg($arg2);

						my $all = 0;
						my $count = 0;

						open(NOTICE,"$conf{path}/var/notice.txt");
						while(<NOTICE>)
						{
							chop;
							if ( /$arg1/ )
							{
								my $match = 0;
								if ( $arg2 )
								{
									if ( /$arg2/i )
									{
										$match = 1;
									}
								}
								else
								{
									$match = 1;
								}
								if ( $match )
								{
									if ( /(\d+) (.*)$/ )
									{
										print $client sprintf("[%s] %s\n",unix2date($1),$2);
										$count++;
									}
								}
							}
						
							$all++;
						}
						close(NOTICE);

						print $client "Found $count of $all notices.\n";
					}
					elsif ( $line =~ /^clones$/i )
					{
						if ( $conf{hubmode} || $conf{locglineaction} =~ /disable/i )
						{
							print $client "This function is disabled in hub mode or when locglineaction is disabled\n";
						}
						else
						{
							my $all = 0;

							my $whots = unix2date((stat("$conf{path}/var/users.txt"))[9],$offset);
							print $client "User base last updated at $whots\n";
							print $client "Loading user base ...\n";

							my %a;
							my %c;

							$c{user}  = "numbers are replaced by '?'";
							$c{ip}    = "ip addresses are summarized by C classes";
							$c{host}  = "hostnames are summarized by domain.tld";
							$c{nick}  = "nicknames are summarized by their 4 first chars and numbers are replaced by '?'";
							$c{idle}  = "idle times are splitted into 4 ranges. 0-1h,1h-1d,1d-1w,1w+";
							$c{rname} = "color/control codes are replaced by ^C/^B/^U/^R";


							open(FILE,"$conf{path}/var/users.txt");
							while(<FILE>)
							{
								chop;
								my %u;
								($u{user},$u{ip},$u{host},$u{nick},$u{idle},$u{xuser},$u{rname})=split(/	/);

								$u{user} =~ s/\d/?/g;
								$u{ip}   =~ s/\.\d+$/\.\*/;

								if ( $u{host} =~ /\.\d+$/ )
								{
									$u{host} = 'no hostname';
								}
								else
								{
									$u{host} =~ s/.*\.((\w|\_|\-)+)\.(\w+)$/\*.$1.$3/;
								}

								$u{nick} =~ s/\d/\?/g;
								$u{nick} =~ s/^(....).*/$1\*/;

								if ( $u{idle} > 604800 )
								{ $u{idle} = '> 1w'; }
								elsif ( $u{idle} > 86400 )
								{ $u{idle} = '1d - 1w'; }
								elsif ( $u{idle} > 3600 )
								{ $u{idle} = '1h - 1d'; }
								else
								{ $u{idle} = '< 1h'; }

								if ( $u{xuser} ) { $u{xuser} = 1; }

								$u{rname} =~ s//^C/g;
								$u{rname} =~ s//^U/g;
								$u{rname} =~ s//^B/g;
								$u{rname} =~ s//^R/g;

								foreach(split(/ /,"user ip host nick idle xuser rname"))
								{
									push(@{$a{$_}},$u{$_});
								}
								$all++;

							}
							close(FILE);

							print $client "Sorting results ...\n";

							my $xuser = 0;
							foreach(@{$a{xuser}}) { if ( $_ ) { $xuser++; } }
							print $client "found $xuser users of $all logged into X\n";

							my $type;
							foreach $type (split(/ /,"user host ip nick idle rname"))
							{
								print $client "Results for '$type' ($c{$type})\n";

								my %u;
								foreach ( @{$a{$type}} )
								{
									$u{$_}++;
								}

								my @TEMP;
								foreach ( keys %u )
								{
									push(@TEMP,sprintf("%05d	%s",$u{$_},$_));
								}
								my $limit = 10;
								foreach ( reverse sort @TEMP )
								{
									if ( $limit > 0 )
									{
										my ($no,$msg)=split(/	/,$_);
										$no+=0;
										print $client sprintf("%5s -> %s\n",$no,$msg);
									}
									$limit--;
								}
							}
							print $client "done.\n";
						}
					}
					elsif ( $line =~ /^map$/ )
					{
						my $mapts = unix2date((stat("$conf{path}/var/map.txt"))[9],$offset);
						print $client "MAP last updated at $mapts\n";

						my @MAP;
						open(MAP,"$conf{path}/var/map.txt");
						while(<MAP>)
						{
							chop;
							my ($serv,$users) = split(/ /);
							push(@MAP,sprintf("%05s %s",$users,$serv));
						}
						close(MAP);
						foreach(reverse(sort(@MAP)))
						{
							my($users,$serv) = split(/ /);
							$users += 0;
							if ( $users > 5 )
							{
								print $client sprintf("%5s %s\n",$users,$serv);
							}
						}
						print $client "done.\n";
					}
					elsif ( $line =~ /^scan (nick|user|host|ip|rname|idle|xuser|mode) (.*)$/i )
					{
						if ( $conf{hubmode} || $conf{locglineaction} =~ /disable/i )
						{
							print $client "This function is disabled in hub mode or when locglineaction is disabled.\n";
						}
						else
						{
							my $field = $1;
							my $match = wild2reg($2);

							$field =~ tr/[A-Z]/[a-z]/;

							my $whots = unix2date((stat("$conf{path}/var/users.txt"))[9],$offset);
							print $client "User base last updated at $whots\n";

							my $count = 0;
							my $all   = 0;

							open(FILE,"$conf{path}/var/users.txt");
							while(<FILE>)
							{
								chop;
								my %u;
								($u{user},$u{ip},$u{host},$u{nick},$u{idle},$u{xuser},$u{rname},$u{mode})=split(/	/);
								$all++;

								if ( $u{$field} =~ /^$match$/i )
								{
									$count++;
									my $idle = easytime($u{idle});
									print $client "$u{nick}\!$u{user}\@$u{host} [$u{ip}] mode:$u{mode} idle:$idle Xuser:$u{xuser} ($u{rname})\n";
								}
							}
							close(FILE);
							print $client "Found $count users of $all users.\n";
						}
					}
					elsif ( $line =~ /^conn (\d+)$/i )
					{
						my $num = $1;
						my @CONN;
						my $count = 0;
						my $tcount = 0;
						open(CONN,"$conf{path}/var/connexit.txt");
						while(<CONN>)
						{
							chop;
							$count++;
							push(@CONN,$_);
						}
						close(CONN);

						my $start = $count - $num;
						if ( $start < 0 ) { $start = 0; }

						for ( my $id = $start; $id < $count; $id++ )
						{
							my $msg = $CONN[$id];
							if ( $msg =~ /^(\d+) (CONN|EXIT):(.*):(.*):\[(.*)\]:.....:(\w*):(.*)$/ )
							{
								my $ts       = $1;
								my $type     = $2;
								my $nick     = $3;
								my $userhost = $4;
								my $ip       = $5;
								my $class    = $6;
								my $txt      = $7;
								$tcount++;

								print $client sprintf("[%s] %s %s\!%s %s class:%s (%s)\n",unix2date($ts,$offset),$type,$nick,$userhost,$ip,$class,$txt);

							}
						}
						if ( !$tcount )
						{ print $client "Log is empty.\n"; }
						else
						{ print $client "Listed $tcount entries.\n"; }
					}
					elsif ( $line =~ /^warnings (\d+)$/i )
					{
						my $num = $1;
						my @WARN;
						my $count = 0;
						my $tcount = 0;
						open(WARN,"$conf{path}/var/warnings.txt");
						while(<WARN>)
						{
							chop;
							$count++;
							push(@WARN,$_);
						}
						close(WARN);

						my $start = $count - $num;
						if ( $start < 0 ) { $start = 0; }

						for ( my $id = $start; $id < $count; $id++ )
						{
							if ( $WARN[$id] =~ /^(\d+) (.*)$/ )
							{
								print $client sprintf("[%s] %s\n", unix2date($1,$offset),$2);
								$tcount++;
							}
						}

						if ( !$tcount )
						{ print $client "Log is empty.\n"; }
						else
						{ print $client "Listed $tcount warnings.\n"; }
					}
					elsif ( $line =~ s/^attack *//i )
					{
						if ( $line =~ /list/i )
						{
							my $count = 0;
							if ( open(ATTACKLOG,"$conf{path}/var/attack.txt") )
							{
								while(<ATTACKLOG>)
								{
									chop;
									if ( /^ATTACK\:(\d+)\:(\d+)\:(\d+)$/ )
									{
										print $client "ID: " . $1 . " -- Possible attack ended on " . unix2date($2,$offset) . " after $3 seconds.\n";
										$count++;
									}
								}
								close(ATTACKLOG);
							}

							if ( !$count )
							{ print $client "Attack log is empty.\n"; }
							else
							{ print $client "Found $count possible attaks in attack log. Use 'attack show <ID>' for details.\n"; }
						}
						elsif ( $line =~ /show (\d+)/i )
						{
							my $id = $1;
							my $count = 0;
							my $found = 0;
							open(ATTACKLOG,"$conf{path}/var/attack.txt");
							while(<ATTACKLOG>)
							{
								chop;

								# Lets stop at the next possible attack
								last if ( /^ATTACK\:(\d+)\:(\d+)\:(\d+)$/ && $found );

								# Let's only show entries following the unique ID
								if ( /^ATTACK\:$id\:(\d+)\:(\d+)$/ )
								{ $found = 1; }

								if ( /^(\d+) (CONN|EXIT):(.*):(.*):\[(.*)\]:.....:(\w*):(.*)$/ && $found )
								{
									$count++;
									my $ts       = $1;
									my $type     = $2;
									my $nick     = $3;
									my $userhost = $4;
									my $ip       = $5;
									my $class    = $6;
									my $txt      = $7;

									print $client sprintf("[%s] %s %s\!%s %s class:%s (%s)\n",unix2date($ts,$offset),$type,$nick,$userhost,$ip,$class,$txt);
								}
							}

							close(ATTACKLOG);

							if ( !$found )
							{ print $client "Unknown ID.\n"; }
							elsif ( $count )
							{ print $client "Listed $count CONN/EXITs.\n"; }
							else
							{ print $client "What? No entries found for this ID.\n"; }
						}
						else
						{
							print $client "Invalid command. Use 'help attack'.\n";
						}
					}
					elsif ( $line =~ /^gline (.*)$/ )
					{
						my $match = wild2reg($1);
						my $count = 0;
						my $all   = 0;
						open(GLINE,"$conf{path}/var/gline.txt");
						while(<GLINE>)
						{
							chop;
							if ( /$match/i && /^(\d+) (global|local):(.*):(.*\@.*|\$R.*):(\d+):(.*)$/ )
							{
								my $ts1  = $1;
								my $mode = $2;
								my $serv = $3;
								my $user = $4;
								my $ts2  = $5;
								my $msg  = $6;

								$serv =~ s/\.$conf{networkdomain}//i;

								print $client sprintf("[%s - %s] %6s %s glined %s (%s)\n",unix2date($ts1,$offset),unix2date($ts2,$offset),$mode,$serv,$user,$msg);
								$count++;
							}
							$all++;
						}
						close(GLINE);
						print $client "Found $count glines of $all glines.\n";
					}
					elsif ( $line =~ /^hack (.*)$/i )
					{
						my $match = wild2reg($1);
						my $count = 0;
						my $all   = 0;
						open(HACK,"$conf{path}/var/hack.txt");
						while(<HACK>)
						{
							chop;
							if ( /^(\d+) (\d):(\d+):(.*)$/ )
							{
								my $ts1  = $1;
								my $mode = $2;
								my $ts2  = $3;
								my $msg  = $4;
								if ( $msg =~ /$match/i )
								{
									if ( $mode eq 2 || $mode eq 3 )
									{
										$mode = "DESYNC  HACK($mode)";
									}
									elsif ( $mode eq 4 )
									{
										$mode = "SERVICE HACK($mode)";
									}
									else
									{
										$mode = "UNKNOWN HACK($mode)";
									}
									print $client sprintf("[%s] %s %s (%s)\n",unix2date($ts1,$offset),$mode,$msg,easytime($ts1-$ts2));
									$count++;
								}
							}
							$all++;
						}
						close(HACK);
						print $client "Found $count hack of $all hack.\n";
					}
					elsif ( $line =~ /^tz (\-|\+)(\d+)$/i )
					{
						$offset = "$1$2" * 3600;
						my $eoff = easytime($offset);
						if ( $eoff =~ /^\d/ ) { $eoff = "+$eoff"; }
						print $client "Your offset to GMT is now $eoff\n";
					}
					elsif ( $line =~ /^quit$/i )
					{
						print DCCLOG sprintf("[%s] %s: quit\n",unix2local(),$client->peerhost);
						print $client "Thanks for using Sentinel v$conf{version}, bye!\n";
						exit;
					}
					else
					{
						print $client "no such command, missing or invalid argument(s), try 'HELP'\n";
					}

				}

				if ( time - $lastin >= $dccwarn && !$warned )
				{
					print $client sprintf("WARNING, session will timeout in %s seconds.\n",$dcctimeout-$dccwarn);
					$warned = 1;
				}
				elsif ( time - $lastin >= $dcctimeout )
				{
					print DCCLOG sprintf("[%s] %s: timeout\n",unix2local(),$client->peerhost);
					print $client "DCC timeout.\n";
					exit;
				}
			}
		}
		exit;
	}

	return 1;
}

sub gencode
{
	my $chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
	my $code = '';

	for(0..1)
	{
		my $charid = int(rand(length($chars)));
		my $char = $chars;
		$char =~ s/^.{$charid}(.).*/$1/;
		$code .= $char;
	}
	return $code;
}
sub cpu
{
	my %cpu;
	if ( $conf{trafficsub} eq 'fbsd' )
	{
		open(CPU,"/sbin/sysctl kern.cp_time |");
		while(<CPU>)
		{
			chop;
			if ( /^kern.cp_time: (\d+) (\d+) (\d+) (\d+) (\d+)$/ )
			{
				$cpu{used} = $1 + $2 + $3 + $4;
				$cpu{idle} = $5;
			}
		}
		close(CPU);
	}
	elsif ( $conf{trafficsub} eq 'linux' )
	{
		open(CPU,"/proc/stat");
		while(<CPU>)
		{
			chop;
			s/ +/ /g;
			if ( /^cpu (\d+) (\d+) (\d+) (\d+)/ )
			{
				$cpu{used} = $1 + $2 + $3;
				$cpu{idle} = $4;
			}
		}
		close(CPU);
	}

	return %cpu;
}

sub traffic
{
	my %iftraffic;

	if ( $conf{trafficsub} eq 'fbsd' )
	{
		open(TRAF,"netstat -nib |");
		while(<TRAF>)
		{
			chop;
			if ( /^(\w+) +\d+ +<Link\#\d+> +\w\w:\w\w:\w\w:\w\w:\w\w:\w\w +(\d+) +(\d+) +(\d+) +(\d+) +(\d+) +(\d+) +(\d+)/i )
			{
				my $ifname = $1;
				if ( $ifname =~ /(lo|gif|wg|tun)\d+/ )
				{
					#ignored
				}
				else
				{
					$iftraffic{$ifname}{ip} = $2;
					$iftraffic{$ifname}{ib} = $5;
					$iftraffic{$ifname}{op} = $6;
					$iftraffic{$ifname}{ob} = $8;
				}
			}
		}
		close(TRAF);
	}
	elsif ( $conf{trafficsub} eq 'linux' )
	{
		open(TRAF,"/proc/net/dev");
		while(<TRAF>)
		{
			chop;
			s/^ +//;
			s/:/ /;
			s/ +/ /g;
			if ( /^(\w+) (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) / )
			{
				my $ifname = $1;
				if ( $ifname =~ /lo|((gif|wg|tun)\d+)/ )
				{
					#ignored
				}
				else
				{
					$iftraffic{$ifname}{ip} = $3;
					$iftraffic{$ifname}{op} = $11;
					$iftraffic{$ifname}{ib} = $2;
					$iftraffic{$ifname}{ob} = $10;
				}
			}
		}
		close(TRAF);
	}
	return %iftraffic;
}

sub unix2date
{
	my $ts = shift;
	$ts += shift || 0;

	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday) = gmtime($ts);  

	$mon++;
	$year +=1900;

	return sprintf("%04d-%02d-%02d %02d:%02d:%02d",$year,$mon,$mday,$hour,$min,$sec);
}

sub unix2local
{
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday) = localtime(time);

	$mon++;
	$year +=1900;

	return sprintf("%04d-%02d-%02d %02d:%02d:%02d",$year,$mon,$mday,$hour,$min,$sec);
}

sub wild2reg
{
	my $wild = shift;

	$wild =~ s/(\\|\[|\]|\^|\$|\.|\+|\{|\})/\\$1/g;
	$wild =~ s/\*/\.\*/g;
	$wild =~ s/\?/\./g;

	return $wild;
}

sub is_ipv6 {
    my ($ip) = @_;
    return $ip =~ /:/ ? 1 : 0;
}
