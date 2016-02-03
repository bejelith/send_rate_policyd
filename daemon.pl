#!/usr/bin/perl 
use Socket;
use POSIX ;
use DBI;
use Switch;
use threads;
use threads::shared;
use Thread::Semaphore; 
use File::Basename;
my $semaphore = new Thread::Semaphore;
#CONFIGURATION SECTION
my @allowedhosts = ('127.0.0.1');
my $LOGFILE = "/var/log/send_rate_policyd.log";
chomp( my $vhost_dir = `pwd`);
my $port = 10381;
my $listen_address = '127.0.0.1';
my $s_key_type = 'domain'; #domain or email
my $dsn = "DBI:mysql:DBNAME:127.0.0.1";
my $db_user = '*********';
my $db_passwd = '***************';
my $db_table = 'email_sender_rate';
my $db_quotacol = 'message_quota';
my $db_tallycol = 'message_tally';
my $db_timecol = 'timestamp';
my $db_wherecol = 'name';
my $deltaconf = 'daily'; #daily, weekly, monthly
my $sql_getquota = "SELECT $db_quotacol, $db_tallycol, $db_timecol FROM $db_table WHERE $db_wherecol = ? AND $db_quotacol > 0";
my $sql_updatequota = "UPDATE $db_table SET $db_tallycol = $db_tallycol + ? WHERE $db_wherecol = ?";
my $sql_resetquota = "UPDATE $db_table SET $db_tallycol = 0 , $db_timecol = ? WHERE $db_wherecol = ?";
#END OF CONFIGURATION SECTION
$0=join(' ',($0,@ARGV));

if($ARGV[0] eq "printshm"){
	my $out = `echo "printshm"|nc $listen_address $port`;
	print $out;
	exit(0);
}
my %quotahash :shared;
my %scoreboard :shared;
my $lock:shared;
my $cnt=0;
my $proto = getprotobyname('tcp');
my $thread_count = 3;
my $min_threads = 2;
# create a socket, make it reusable
socket(SERVER, PF_INET, SOCK_STREAM, $proto) or die "socket: $!";
setsockopt(SERVER, SOL_SOCKET, SO_REUSEADDR, 1) or die "setsock: $!";
my $paddr = sockaddr_in($port, inet_aton($listen_address)); #Server sockaddr_in
bind(SERVER, $paddr) or die "bind: $!";# bind to a port, then listen
listen(SERVER, SOMAXCONN) or die "listen: $!";
&daemonize;
$SIG{TERM} = \&sigterm_handler;
$SIG{HUP} = \&print_cache;
while (1) {
	my $i = 0;
	my @threads;
	while($i < $thread_count){
		#$threads[$i] = threads->new(\&start_thr)->detach();
		threads->new(\&start_thr);
		logger("Started thead num $i.");
		$i++;
	}
	while(1){
		sleep 5;
		$cnt++;
		my $r = 0;
		my $w = 0;
		if($cnt % 6 == 0){
			lock($lock);
			&commit_cache;
			&flush_cache;
			logger("Master: cache committed and flushed");
		}
		while (my ($k, $v) = each(%scoreboard)){
			if($v eq 'running'){
				$r++;
			}else{
				$w++;
			}
		}
		if($r/($r + $w) > 0.9){
			threads->new(\&start_thr);
			logger("New thread started");
		}
		if($cnt % 150 == 0){
			logger("STATS: threads running: $r, threads waiting $w.");
		}
	}
}

exit;

sub start_thr {
	my $threadid = threads->tid();
	my $client_addr;
	my $client_ipnum;
	my $client_ip;
	my $client;
	while(1){
		$scoreboard{$threadid} = 'waiting';
		$semaphore->down();#TODO move to non-block
		$client_addr = accept($client, SERVER);
		$semaphore->up();
		$scoreboard{$threadid} = 'running';
		if(!$client_addr){
			logger("TID: $threadid accept() failed with: $!");
			next;
		}	
		my ($client_port, $client_ip) = unpack_sockaddr_in($client_addr);
		$client_ipnum = inet_ntoa($client_ip);
		logger("TID: $threadid accepted from $client_ipnum ...");
		
		select($client);
		$|=1;
	
		if(grep $_ eq $client_ipnum, @allowedhosts){
			my $message;
			my @buf;
			while(!eof($client)) {
				$message = <$client>;
				if($message =~ m/printshm/){
					my $r=0;
					my $w =0;
					print $client "Printing shm:\r\n";
					print $client "Domain\t\t:\tQuota\t:\tUsed\t:\t Sum \t:\tExpire\r\n";
					while(($k,$v) = each(%quotahash)){
						chomp(my $exp = ctime($quotahash{$k}{'expire'}));
						print $client "$k\t:\t".$quotahash{$k}{'quota'}."\t:\t $quotahash{$k}{'tally'}\t:\t$quotahash{$k}{'sum'}\t:\t $exp\r\n";
					}
					while (my ($k, $v) = each(%scoreboard)){
						if($v eq 'running'){
							$r++;
						}else{
							$w++;
						}
					}
					print $client "Threads running: $r, Threads waiting: $w\r\n";
					last;
				}elsif($message =~ m/=/){
					push(@buf, $message);
					next;
				}elsif($message == "\r\n"){
					#logger("Handle new request");
					my $ret = &handle_req(@buf);
					if($ret =~ m/unknown/){
						last;
					#New thread model - old code
					#	shutdown($client,2);
					#??	threads->exit(0);
					}else{
						print $client "action=$ret\n\n";
					}
					@buf = ();
				}else{
					print $client "message not understood\r\n";
				}
			}
		}else{
			logger("Client $client_ipnum connection not allowed.");
		}
		shutdown($client,2);
		undef $client;
		logger("TID: $threadid Client $client_ipnum disconnected.");
	}
	undef $scoreboard{$threadid};
	threads->exit(0);
}

sub handle_req {
	my @buf = @_;
	my $protocol_state;
	my $sasl_username; 
	my $recipient_count;
	local $/ = "\n";
	foreach $aline(@buf){
		my @line = split("=", $aline);
		chomp(@line);
		#logger("Line ". $line[0] ."=". $line[1]);
		switch($line[0]){
			case "protocol_state" { 
				chomp($protocol_state = $line[1]);
			}
			case "sasl_username"{
				chomp($sasl_username = $line[1]);
			}
			case "recipient_count"{
				chomp($recipient_count = $line[1]);
			}
		}
	}

	#if($recipient_count <= 5){
	#	$recipient_count = 1;
	#}

	if($protocol_state !~ m/DATA/ || $sasl_username eq "" ){
		return "ok";
	}
	
	my $skey = '';
	if($s_key_type eq 'domain'){
		$skey = (split("@", $sasl_username))[1];
	}else{
		$skey = $sasl_username;
	}
	#TODO: Maybe i should move to semaphore!!!
	lock($lock);
	if(!exists($quotahash{$skey})){
		logger("Looking for $skey");
		if(my $dbh = DBI->connect($dsn, $db_user, $db_passwd)){
		
			my $sql_query = $dbh->prepare($sql_getquota);
			$sql_query->execute($skey);
			if($sql_query->rows < 1){
				$sql_query->finish();
                                $dbh->disconnect;
                                return "dunno";
			}
			while(@row = $sql_query->fetchrow_array()){
				$quotahash{$skey} = &share({});
				$quotahash{$skey}{'quota'} = $row[0];
				if($row[1]){
					$quotahash{$skey}{'tally'} = $row[1];
				} else {
					$quotahash{$skey}{'tally'} = 0;
				}
				$quotahash{$skey}{'sum'} = 0;
				if($row[2]){
					$quotahash{$skey}{'expire'} = $row[2];
				}else{
					#$quotahash{$skey}{'expire'} = calcexpire($deltaconf);
					$quotahash{$skey}{'expire'} = 0;
				}
				undef @row;
			}
			$sql_query->finish();
			$dbh->disconnect;
		} else {
			logger("Error connection to database: " . $DBI::errstr);
			return "dunno";
		}
	}
	if($quotahash{$skey}{'expire'} < time() ){
		lock($lock);
		$quotahash{$skey}{'sum'} = 0;
		$quotahash{$skey}{'tally'} = 0;
		$quotahash{$skey}{'expire'} = calcexpire($deltaconf);
		my $dbh = DBI->connect($dsn, $db_user, $db_passwd);
	        my $sql_query = $dbh->prepare($sql_resetquota);
		$sql_query->execute($quotahash{$skey}{'expire'}, $skey)
			or logger("Query error: ". $sql_query->errstr);

	}
	if($quotahash{$skey}{'tally'} + $recipient_count > $quotahash{$skey}{'quota'}){
		return "471 Message quota exceeded"; 
	}
	$quotahash{$skey}{'tally'} += $recipient_count;
	$quotahash{$skey}{'sum'} += $recipient_count;
	return "dunno";
}

sub sigterm_handler {
	shutdown(SERVER,2);
	lock($lock);
	logger("SIGTERM received.\nFlushing cache...\nExiting.");
	&commit_cache;
	exit(0);
}

sub commit_cache {
	if(my $dbh = DBI->connect($dsn, $db_user, $db_passwd)){
		my $sql_query = $dbh->prepare($sql_updatequota);
		while(($k,$v) = each(%quotahash)){
			$sql_query->execute($quotahash{$k}{'sum'}, $k)
				or logger("Query error:".$sql_query->errstr);
			$quotahash{$k}{'sum'} = 0;
		}
		$dbh->disconnect;
	} else {
		logger("Error connection to database: " . $DBI::errstr);
	}
}

sub flush_cache {
	foreach $k(keys %quotahash){
		delete $quotahash{$k};
	}
}

sub print_cache {
	foreach $k(keys %quotahash){
        logger("$k: $quotahash{$k}{'quota'}, $quotahash{$k}{'tally'}, $quotahash{$k}{'sum'}");
    }
}

sub daemonize {
	my ($i,$pid);
	my $mask = umask 0027;
	print "Keedra SMTP Policy Daemon. Logging to $LOGFILE\n";
	#Should i delete this??
	#$ENV{PATH}="/bin:/usr/bin";
	#chdir("/");
	close STDIN;
	if(!defined(my $pid=fork())){
		die "Impossible to fork\n";
	}elsif($pid >0){
		exit 0;
	}
	setsid();
	close STDOUT;
	open STDIN, "/dev/null";
	open LOG, ">>$LOGFILE" or die "Unable to open $LOGFILE: $!\n";
	select((select(LOG), $|=1)[0]);
	open STDERR, ">>$LOGFILE" or die "Unable to redirect STDERR to STDOUT: $!\n";
	open PID, ">/var/run/".basename($0) or die $!;
	print PID $$;
	close PID;
	umask $mask;
}

sub calcexpire{
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
	my ($arg) = @_;
	if($arg eq 'monthly'){
		$exp = mktime (0, 0, 0, 1, ++$mon, $year);
	}elsif($arg eq 'weekly'){
		$exp = mktime (0, 0, 0, 1, $mon, $year);
	}elsif($arg eq 'daily'){
		$exp = mktime (0, 0, 0, ++$mday, $mon, $year);
	}else{
		$exp = mktime (0, 0, 0, 1, ++$mon, $year);
	}
	return $exp;
}

sub logger {
	my ($arg) = @_;
	my $time = localtime();
	chomp($time);
	print LOG  "$time $arg\n";
}


