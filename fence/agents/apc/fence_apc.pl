#!/usr/bin/perl

###############################################################################
###############################################################################
##
##  Copyright (C) Sistina Software, Inc.  1997-2003  All rights reserved.
##  Copyright (C) 2004-2006 Red Hat, Inc.  All rights reserved.
##  
##  This copyrighted material is made available to anyone wishing to use,
##  modify, copy, or redistribute it subject to the terms and conditions
##  of the GNU General Public License v.2.
##
###############################################################################
###############################################################################

use Getopt::Std;
use Net::Telnet ();

# Get the program name from $0 and strip directory names
$_=$0;
s/.*\///;
my $pname = $_;

# Change these if the text returned by your equipment is different.
# Test by running script with options -t -v and checking /tmp/apclog

my $immediate = 'immediate'; # # Or 'delayed' - action string prefix on menu
my $masterswitch = 'masterswitch plus '; # 'Device Manager' option to choose
my $login_prompt = '/: /';
my $cmd_prompt = '/> $/';

my $max_open_tries = 3;      # How many telnet attempts to make.  Because the 
                             # APC can fail repeated login attempts, this number
                             # should be more than 1
my $open_wait = 5;           # Seconds to wait between each telnet attempt
my $telnet_timeout = 2;      # Seconds to wait for matching telent response
my $debuglog = '/tmp/apclog';# Location of debugging log when in verbose mode
$opt_o = 'reboot';           # Default fence action.  

my $logged_in = 0;

my $t = new Net::Telnet;



# WARNING!! Do not add code bewteen "#BEGIN_VERSION_GENERATION" and 
# "#END_VERSION_GENERATION"  It is generated by the Makefile

#BEGIN_VERSION_GENERATION
$FENCE_RELEASE_NAME="";
$REDHAT_COPYRIGHT="";
$BUILD_DATE="";
#END_VERSION_GENERATION

sub usage 
{
	print "Usage:\n";
	print "\n";
	print "$pname [options]\n";
	print "\n";
	print "Options:\n";
	print "  -a <ip>          IP address or hostname of MasterSwitch\n";
	print "  -h               usage\n";
	print "  -l <name>        Login name\n";
	print "  -n <num>         Outlet number to change: [<switch>:]<outlet> \n";
	print "  -o <string>      Action: Reboot (default), Off or On\n";
	print "  -p <string>      Login password\n";
	print "  -q               quiet mode\n";
	print "  -T               Test mode (cancels action)\n";
	print "  -V               version\n";
	print "  -v               Log to file /tmp/apclog\n";
	
	exit 0;
}

sub fail
{
	($msg)=@_;
	print $msg."\n" unless defined $opt_q;

	if (defined $t)
	{
		# make sure we don't get stuck in a loop due to errors
		$t->errmode('return');  

		logout() if $logged_in;
		$t->close();
	}
	exit 1;
}

sub fail_usage
{
	($msg)=@_;
	print STDERR $msg."\n" if $msg;
	print STDERR "Please use '-h' for usage.\n";
	exit 1;
}

sub version
{
	print "$pname $FENCE_RELEASE_NAME $BUILD_DATE\n";
	print "$REDHAT_COPYRIGHT\n" if ( $REDHAT_COPYRIGHT );
	exit 0;
}


sub login
{
	for (my $i=0; $i<$max_open_tries; $i++)
	{
		$t->open($opt_a);
		($_) = $t->waitfor($login_prompt);
  
		# Expect 'User Name : ' 
		if (! /name/i) {
			$t->close();
			sleep($open_wait);
			next;        
		}

		$t->print($opt_l);
		($_) = $t->waitfor($login_prompt);

		# Expect 'Password  : ' 
		if (! /password/i ) {
			$t->close();
			sleep($open_wait);
			next;         
		}
  
		# Send password
		$t->print($opt_p);  

		(my $dummy, $_) = $t->waitfor('/(>|(?i:user name|password)\s*:) /');
		if (/> /)
		{
			$logged_in = 1;

			# send newline to flush prompt
			$t->print("");  

			return;
		}
		else
		{
			fail "invalid username or password";
		}
	}
	fail "failed: telnet failed: ". $t->errmsg."\n" 
}

# print_escape_char() -- utility subroutine for sending the 'Esc' character
sub print_escape_char
{
	# The APC menu uses "<esc>" to go 'up' menues.  We must set
	# the output_record_separator to "" so that "\n" is not printed
	# after the "<esc>" character

	$ors=$t->output_record_separator;
	$t->output_record_separator("");
	$t->print("\x1b"); # send escape
	$t->output_record_separator("$ors");
}


# Determine if the switch is a working state.  Also check to make sure that 
# the switch has been specified in the case that there are slave switches
# present.  This assumes that we are at the main menu.
sub identify_switch
{

	($_) = $t->waitfor($cmd_prompt);
	print_escape_char();

	# determine what type of switch we are dealling with
	($_) = $t->waitfor($cmd_prompt);
	if ( /Switched Rack PDU: Communication Established/i)
	{
		# No further test needed
	}
	elsif ( /MS plus 1 : Serial Communication Established/i )
	{
		if ( defined $switchnum )
		{
			$masterswitch = $masterswitch . $switchnum;
		}
		elsif ( /MS plus [^1] : Serial Communication Established/i )
		{
			fail "multiple switches detected.  'switch' must be defined.";
		}
		else
		{
			$switchnum = 1;
		}
	}
	else
	{
		fail "APC is in undetermined state"
	}	

	# send a newline to cause APC to reprint the menu
	$t->print("");
}


# Navigate through menus to the appropriate outlet control menu of the apc
# MasterSwitch and 79xx series switches.  Uses multi-line (mostly) 
# case-insensitive matches to recognise menus and works out what option number 
# to select from each menu.
sub navigate
{
	# Limit the ammount of menu depths to 20.  We should never be this deep
	for(my $i=20; $i ; $i--)
	{
		# Get the new text from the menu
		(($_) = $t->waitfor($cmd_prompt)) or next;

		# Identify next option 
		if ( 
			# "Control Console", "1- Device Manager"
			/--\s*control console.*(\d+)\s*-\s*device manager/is  ||

			# 
			# APC MasterSwitch Menus
			#
			# "Device Manager", "1- MasterSwitch plus 1"
			/--\s*device manager.*(\d+)\s*-\s*$masterswitch/is ||

			# "Device Manager", "1- Cluster Node 0   ON"
			/--\s*(?:device manager|$masterswitch).*(\d+)\s*-\s+Outlet\s+$switchnum:$opt_n\D[^\n]*\s(?-i:ON|OFF)\*?\s/ism ||

			# "MasterSwitch plus 1", "1- Outlet 1:1  Outlet #1  ON"
			/--\s*$masterswitch.*(\d+)\s*-\s*Outlet\s+$switchnum:$opt_n\s[^\n]*\s(?-i:ON|OFF)\*?\s/ism ||
	
			# Administrator outlet control menu
			/--\s*Outlet $switchnum:$opt_n\D.*(\d+)\s*-\s*outlet control\s*$switchnum:?$opt_n\D/ism || 


			#
			# APC 79XX Menus
			#
			# "3- Outlet Control/Configuration"
			/--\s*device manager.*(\d+)\s*-\s*Outlet Control/is ||

			# "Device Manager", "1- Cluster Node 0   ON"
			/--\s*Outlet Control.*\s+?(\d+)\s*-\s+[^\n\r]*\s*Outlet\s+$opt_n\D[^\n]*\s(?-i:ON|OFF)\*?\s/ism ||

			# Administrator Outlet Control menu
			/--[^\n\r]*Outlet\s+$opt_n\D.*(\d+)\s*-\s*control\s*outlet\s+$opt_n\D/ism ||
			/--[^\n\r]*Outlet\s+$opt_n\D.*(\d+)\s*-\s*control\s*outlet/ism
		) {
			$t->print($1);
			next;
		}

		if (/.*Press ([^\n\r]+) to continue.*$/) {
			$t->print("");
			next;
		}

		# "Outlet Control X:N", "4- Immediate Reboot"
		if ( /(\d+)\s*-\s*$immediate $opt_o/i || 
                     /--\s*Control Outlet\D.*(\d+)\s*-\s*Immediate\s*$opt_o/is ) {
			$t->print($1);
			last;
		}

		fail "failed: unrecognised menu response\n";
	}
}


sub logout 
{
	# send a newline to make sure that we refresh the menus 
	# ($t->waitfor() can hang otherwise)
	$t->print("");

	# Limit the ammount of menu depths to 20.  We should never be this deep
	for(my $i=20; $i ; $i--)
	{

		# Get the new text from the menu
		($_) = $t->waitfor($cmd_prompt);

		if ( 
			# "Control Console", "4- Logout"	 
			/--\s*control console.*(\d+)\s*-\s*Logout/is
		) {
			$t->print($1);
			last;
		}
		else 
		{
			print_escape_char();
			next;
		}
	}
}


sub action
{
	# "Enter 'YES' to continue or <ENTER> to cancel : "
	($_) = $t->waitfor('/: /');
	if (! /$immediate $opt_o.*outlet $opt_n\s.*YES.*to continue/si ) {
		fail "failed: unrecognised $opt_o response\n";
	}

	# Test mode?
	$t->print($opt_T?'NO':'YES');

	# "Success", "Press <ENTER> to continue..." 
	($_) = $t->waitfor('/continue/');
	$t->print('');

	if (defined $opt_T) {
		logout(); 
		print "success: test outlet $opt_n $opt_o\n" unless defined $opt_q; 
		$t->close();

		# Allow the APC some time to clean connection
		# before next login.
		sleep 1;

		exit 0;
	} elsif ( /Success/i ) {
		logout();
		print "success: outlet $opt_n $opt_o\n" unless defined $opt_q; 
		$t->close();

		# Allow the APC some time to clean connection
		# before next login.
		sleep 1;

		exit 0;
	} 

	fail "failed: unrecognised action response\n";
}


sub get_options_stdin
{
	my $opt;
	my $line = 0;
	while( defined($in = <>) )
	{
		$_ = $in;
		chomp;

		# strip leading and trailing whitespace
		s/^\s*//;
		s/\s*$//;

		# skip comments
		next if /^#/;
	
		$line+=1;
		$opt=$_;
		next unless $opt;

		($name,$val)=split /\s*=\s*/, $opt;

		if ( $name eq "" )
		{
			print STDERR "parse error: illegal name in option $line\n";
			exit 2;
		} 
		# DO NOTHING -- this field is used by fenced 
		elsif ($name eq "agent" ) 
		{
		} 
		elsif ($name eq "ipaddr" ) 
		{
			$opt_a = $val;
		} 
		elsif ($name eq "login" ) 
		{
			$opt_l = $val;
		} 
		elsif ($name eq "option" ) 
		{
			$opt_o = $val;
		} 
		elsif ($name eq "passwd" ) 
		{
			$opt_p = $val;
		} 
		elsif ($name eq "port" ) 
		{
			$opt_n = $val;
		} 
		elsif ($name eq "switch" ) 
		{
			$switchnum = $val;
		} 
		elsif ($name eq "test" ) 
		{
			$opt_T = $val;
		} 
		elsif ($name eq "verbose" ) 
		{
			$opt_v = $val;
		} 
	}
}
		

sub telnet_error
{
	if ($t->errmsg ne "pattern match timed-out") {
		fail "failed: telnet returned: ".$t->errmsg."\n";
	} else {
		$t->print("");
	}
}


### MAIN #######################################################

if (@ARGV > 0) {
	getopts("a:hl:n:o:p:qTvV") || fail_usage ;
	
	usage if defined $opt_h;
	version if defined $opt_V;

	fail_usage "Unkown parameter." if (@ARGV > 0);

	fail_usage "No '-a' flag specified." unless defined $opt_a;
	fail_usage "No '-n' flag specified." unless defined $opt_n;
	fail_usage "No '-l' flag specified." unless defined $opt_l;
	fail_usage "No '-p' flag specified." unless defined $opt_p;
	fail_usage "Unrecognised action '$opt_o' for '-o' flag"
	unless $opt_o =~ /^(Off|On|Reboot)$/i;

	if ( $opt_n =~ /(\d+):(\d+)/ ) {
		$switchnum=($1);
		$opt_n = ($2);
	}
} else {
	get_options_stdin();

	fail "failed: no IP address" unless defined $opt_a;
	fail "failed: no plug number" unless defined $opt_n;
	fail "failed: no login name" unless defined $opt_l;
	fail "failed: no password" unless defined $opt_p;
	fail "failed: unrecognised action: $opt_o"
	unless $opt_o =~ /^(Off|On|Reboot)$/i;
} 

$t->timeout($telnet_timeout);
$t->input_log($debuglog) if $opt_v;
$t->errmode('return');  

&login;

&identify_switch;

# Abort on failure beyond here
$t->errmode(\&telnet_error);  

&navigate;
&action;

exit 0;


