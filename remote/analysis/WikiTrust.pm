package WikiTrust;

use constant DEBUG => 0;

use strict;
use warnings;
use DBI;
use Error qw(:try);
use Apache2::RequestRec ();
use Apache2::Const -compile => qw( OK );
use Apache2::Connection ();
use CGI;
use CGI::Carp;
use IO::Zlib;
use Compress::Zlib;
use Cache::Memcached;
use Data::Dumper;
use JSON;
use Date::Manip;
use POSIX qw(strftime);
use File::Path qw(rmtree);	# on newer perls, this is remove_tree
use List::Util qw(max);

use constant QUEUE_PRIORITY => 10; # wikitrust_queue is now a priority queue.
use constant SLEEP_TIME => 3;
use constant NOT_FOUND_TEXT_TOKEN => "TEXT_NOT_FOUND";
use constant AGE_REVISION_CONVERSION => 7 * 24 * 3600;

our %methods = (
	'edit' => \&handle_edit,
	'vote' => \&handle_vote,
	'gettext' => \&handle_gettext,
	'wikiorhtml' => \&handle_wikiorhtml,
	'sharehtml' => \&handle_sharehtml,
	'stats' => \&handle_stats,
	'status' => \&handle_status,
	'miccheck' => \&handle_miccheck,
	'delete' => \&handle_deletepage,
	'vandalism' => \&handle_vandalism,
	'vandalismZD' => \&handle_vandalismZD,
	'rawvandalism' => \&handle_rawvandalism,
	'quality' => \&handle_vandalism,
	'rawquality' => \&handle_rawvandalism,
	'select' => \&handle_selection,
    );

our $cache = undef;	# will get initialized when needed

sub cmdline {
    *CGI::no_cache = sub {};
    my $cgi = CGI->new();
    foreach my $arg (@ARGV) {
	my ($var, $val) = split(/=/, $arg);
	$cgi->param($var, $val);
    }
    handler($cgi);
}

sub handler {
  my $r = shift;
  my $cgi = CGI->new($r);

  my $dbh = DBI->connect(
    $ENV{WT_DBNAME},
    $ENV{WT_DBUSER},
    $ENV{WT_DBPASS},
    { RaiseError => 1, AutoCommit => 1 }
  );

  my $result = "";
  try {
    my ($pageid, $title, $revid, $time, $username, $method);
    $method = $cgi->param('method');
    if (!$method) {
      $method = 'gettext';
      if ($cgi->param('vote')) {
        $method = 'vote';
      } elsif ($cgi->param('edit')) {
        $method = 'edit';
      }
    }

    throw Error::Simple("Bad method: $method") if !exists $methods{$method};
    my $func = $methods{$method};
    $result = $func->($dbh, $cgi, $r);
  } otherwise {
    my $E = shift;
    print STDERR $E;
    $r->no_cache(1);
    $r->content_type('text/plain; charset=utf-8');
    $r->print('EERROR detected.  Try again in a moment, or report an error on the WikiTrust bug tracker.');
  };
  return $result;
}

sub get_stdargs {
    my $cgi = shift @_;
    my ($pageid, $title, $revid, $time, $username);
    my $method = $cgi->param('method');
    if (!$method) {
	# old parameter names
	$pageid = $cgi->param('page') || 0;
	$title = $cgi->param('page_title') || '';
	$revid = $cgi->param('rev') || -1;
	$time = $cgi->param('time') || timestamp();
	$username = $cgi->param('user') || '';
    } else {
	# new parameter names
	$pageid = $cgi->param('pageid') || 0;
	$title = $cgi->param('title') || '';
	$revid = $cgi->param('revid') || -1;
	$time = $cgi->param('time') || timestamp();
	$username = $cgi->param('username') || '';
    }
    return ($revid, $pageid, $username, $time, $title);
}

sub timestamp {
    my @time = localtime();
    return sprintf("%04d%02d%02d%02d%02d%02d", $time[5]+1900, $time[4]+1, $time[3], $time[2], $time[1], $time[0]);
}

sub secret_okay {
    my $cgi = shift @_;
    my $secret = $cgi->param('secret') || '';
    my $true_secret = $ENV{WT_SECRET} || '';
    return ($secret eq $true_secret);
}

# To fix atomicity errors, wrapping this in a procedure.
sub mark_for_coloring {
  my $page = shift @_;
  my $page_title = shift @_;
  my $dbh = shift @_;
  my $priority = shift @_ || QUEUE_PRIORITY;

  die "Illegal page_id $page for '$page_title'"
	if $page <= 0 && $page_title eq '';
  confess "Illegal page_id for '$page_title'" if $page <= 0;

  my $sth = $dbh->prepare(
    "INSERT INTO wikitrust_queue (page_id, page_title, priority) VALUES (?, ?, ?)"
	." ON DUPLICATE KEY UPDATE requested_on = now(), priority=? "
  ) || die $dbh->errstr;
  $sth->execute($page, $page_title, $priority, $priority) || die $dbh->errstr;
}

sub handle_vote {
  my ($dbh, $cgi, $r) = @_;
  my ($rev, $page, $user, $time, $page_title) = get_stdargs($cgi);

  die "Illegal page_id from user '$user'" if $page <= 0;
  die "Illegal rev_id from user '$user'" if $rev <= 0;

  $r->content_type('text/plain');

  # can't trust non-verified submitters
  $user = 0 if !secret_okay($cgi);

  my $sel_sql = "SELECT voter_name FROM wikitrust_vote WHERE voter_name = ? AND revision_id = ?";
  if (my $ref = $dbh->selectrow_hashref($sel_sql, {}, ($user, $rev))){
    $r->print('dup');
    return Apache2::Const::OK;
  }

  my $sth = $dbh->prepare("INSERT INTO wikitrust_vote (revision_id, page_id, "
    . "voter_name, voted_on) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE "
    . "voted_on = ?") || die $dbh->errstr;
  $sth->execute($rev, $page, $user, $time, $time) || die $dbh->errstr;
  # Not a transaction: $dbh->commit();

  if ($sth->rows > 0){
    mark_for_coloring($page, $page_title, $dbh);
  }

  # Token saying things are ok
  # Votes do not return anything. This just sends back the ACK
  # that the vote was recorded.
  # We could change this to be the re-colored wiki-text, reflecting the
  # effect of the vote, if you like.
  $r->print('good');
  return Apache2::Const::OK;
}

sub get_median {
  my $dbh = shift;
  my $median = 0.0;
  my $sql = "SELECT median FROM wikitrust_global";
  if (my $ref = $dbh->selectrow_hashref($sql)){
    $median = $$ref{'median'};
  }
  return $median;
}

sub util_getPageDirname {
  my ($pageid) = @_;
  my $path = $ENV{WT_BLOB_PATH} || die "WT_BLOB_PATH undefined";
  return undef if !defined $path;
  my $page_str = sprintf("%012d", $pageid);
  for (my $i = 0; $i <= 3; $i++){
    $path .= "/" . substr($page_str, $i*3, 3);
  }
  return $path;
}

sub util_getRevFilename {
  my ($pageid, $blobid) = @_;
  my $path = util_getPageDirname($pageid);
  return undef if !defined $path;

  my $blob_str = sprintf("%09d", $blobid);

  if ($blobid >= 1000){
    $path .= "/" . sprintf("%06d", $blobid);
  }
  my $page_str = sprintf("%012d", $pageid);
  $path .= "/" . $page_str . "_" . $blob_str . ".gz";
  return $path;
}

# Extract text from a blob
sub util_extractFromBlob {
  my ($rev_id, $blob_content) = @_;
  my @parts = split(/:/, $blob_content, 2);
  my $offset = 0;
  my $size = 0;
  while ($parts[0] =~ m/\((\d+) (\d+) (\d+)\)/g){
    if ($1 == $rev_id){
      $offset = $2;
      $size = $3;
      return substr($parts[1], $offset, $size);
    }
  }
  throw Error::Simple("Unable to find $rev_id in blob");
}

sub fetch_colored_markup {
  my ($page_id, $rev_id, $dbh) = @_;

  my $median = get_median($dbh);

  ## Get the blob id
  my $sth = $dbh->prepare ("SELECT blob_id FROM "
      . "wikitrust_revision WHERE "
      . "revision_id = ?") || die $dbh->errstr;
  my $blob_id = -1;
  $sth->execute($rev_id) || die $dbh->errstr;
  if (my $ref = $sth->fetchrow_hashref()) {
    $blob_id = $$ref{'blob_id'};
  } else {
    return NOT_FOUND_TEXT_TOKEN;
  }

  my $file = util_getRevFilename($page_id, $blob_id);
  if ($file) {
    warn "fetch_colored_markup: file=[$file]\n" if DEBUG;
    return NOT_FOUND_TEXT_TOKEN if !-r $file;

    my $fh = IO::Zlib->new();
    $fh->open($file, "rb") || die "open($file): $!";
    my $text = join("", $fh->getlines());
    $fh->close();
    return $median.",".util_extractFromBlob($rev_id, $text);
  }

  my $new_blob_id = sprintf("%012d%012d", $page_id, $blob_id);
  $sth = $dbh->prepare ("SELECT blob_content FROM "
      . "wikitrust_blob WHERE "
      . "blob_id = ?") || die $dbh->errstr;
  my $result = NOT_FOUND_TEXT_TOKEN;
  $sth->execute($new_blob_id) || die $dbh->errstr;
  if (my $ref = $sth->fetchrow_hashref()) {
    my $blob_c = Compress::Zlib::memGunzip($$ref{'blob_content'});
    $result = $median.",".util_extractFromBlob($rev_id, $blob_c);
  }
  return $result;
}

sub handle_edit {
  my ($dbh, $cgi, $r) = @_;
  my ($rev, $page, $user, $time, $page_title) = get_stdargs($cgi);
  # since we still need to download actual text,
  # it's safe to not verify the submitter
  mark_for_coloring($page, $page_title, $dbh);
  $r->content_type('text/plain');
  $r->print('good');
  return Apache2::Const::OK;
}

sub util_ColorIfAvailable { 
  my ($dbh, $page, $rev, $page_title) = @_;
  my $result = fetch_colored_markup($page, $rev, $dbh);
  if ($result eq NOT_FOUND_TEXT_TOKEN){
    # If the revision is not found among the colored ones,
    # we mark it for coloring,
    # and it wait a bit, in the hope that it got colored.
    mark_for_coloring($page, $page_title, $dbh);
    sleep(SLEEP_TIME);
    # Tries again to get it, to see if it has been colored.
    $result = fetch_colored_markup($page, $rev, $dbh);
  }
  return $result;
}

sub handle_gettext {
  my ($dbh, $cgi, $r) = @_;
  my ($rev, $page, $user, $time, $page_title) = get_stdargs($cgi);
  my $result = util_ColorIfAvailable($dbh, $page, $rev, $page_title);
  if ($result eq NOT_FOUND_TEXT_TOKEN) {
    $r->headers_out->{'Cache-Control'} = "max-age=" . 60;
  } else {
    $r->headers_out->{'Cache-Control'} = "max-age=" . 5*24*60*60;
  }
  $r->content_type('text/plain; charset=utf-8');
  $r->print($result);
  return Apache2::Const::OK;
}

sub handle_wikiorhtml {
  my ($dbh, $cgi, $r) = @_;
  if (exists $ENV{WT_MESSAGE}) {
    # send a message to users
    $r->headers_out->{'Cache-Control'} = "max-age=" . 10*60;
    $r->content_type('text/plain; charset=utf-8');
    $r->print('E');
    $r->print($ENV{WT_MESSAGE});
    return Apache2::Const::OK;
  }
  my ($rev, $page, $user, $time, $page_title) = get_stdargs($cgi);
  my $cache = util_getCache();
  my $data = $cache->get($rev);
  if (defined $data && ref $data eq 'HASH') {
    $r->headers_out->{'Cache-Control'} = "max-age=" . 30*24*60*60;
    $r->content_type('text/plain; charset=utf-8');
    $r->print('H');
    $r->print($data->{html});
    return Apache2::Const::OK;
  }

  my $result = util_ColorIfAvailable($dbh, $page, $rev, $page_title);
  if ($result eq NOT_FOUND_TEXT_TOKEN) {
    $r->headers_out->{'Cache-Control'} = "max-age=" . 15;
  } else {
    $r->headers_out->{'Cache-Control'} = "max-age=" . 30;
  }
  $r->content_type('text/plain; charset=utf-8');
  $r->print('W');
  $r->print($result);
  return Apache2::Const::OK;
}

sub handle_stats {
  my ($dbh, $cgi, $r) = @_;

  $r->no_cache(1);
  $r->content_type('text/plain; charset=utf-8');

  my $sth = $dbh->prepare ("SELECT * FROM wikitrust_queue") || die $dbh->errstr;
  $sth->execute() || die $dbh->errstr;
  $r->print("Processing queue for WikiTrust dispatcher:\n\n");
  my $found_header = 0;
  my $rows = $sth->rows;
  $r->print("($rows rows)\n");
  while ((my $ref = $sth->fetchrow_hashref())){
    if (!$found_header) {
      foreach (sort keys %$ref) { $r->print(sprintf("%20s ", $_)); }
      $r->print("\n");
      foreach (sort keys %$ref) { $r->print('='x21); }
      $r->print("\n");
      $found_header = 1;
    }
    foreach (sort keys %$ref) { $r->print(sprintf("%20s ", $ref->{$_})); }
    $r->print("\n");
  }
  $r->print("\n\nMemCache statistics:\n\n");
  my $cache = util_getCache();
  my $stats = $cache->stats();
  foreach my $key (keys %$stats) {
    $r->print("\t$key = ". Dumper($stats->{$key}) . "\n");
  }
  return Apache2::Const::OK;
}

# miccheck: Called by the plugin to see if this language is
# actually implemented.  Basically, it tests that the DNS
# is configured and working correctly from user to us.
sub handle_miccheck {
  my ($dbh, $cgi, $r) = @_;

  $r->headers_out->{'Cache-Control'} = "max-age=" . 30*24*60*60;
  $r->content_type('text/plain; charset=utf-8');
  $r->print("OK");
  return Apache2::Const::OK;
}

sub handle_status {
  my ($dbh, $cgi, $r) = @_;

  $r->no_cache(1);
  $r->content_type('text/plain; charset=utf-8');

  my $cache = util_getCache();
  throw Error::Simple("Memcache failure") if !defined $cache;
  my $stats = $cache->stats();
  throw Error::Simple("Memcache stats failure") if !defined $stats;
  throw Error::Simple("DBI failure") if !defined $dbh;
  my $sth = $dbh->prepare("SELECT COUNT(*) FROM wikitrust_queue")
      || throw Error::Simple($dbh->errstr);
  $sth->execute() || throw Error::Simple($dbh->errstr);
  if (my $ref = $sth->fetchrow_arrayref()) {
    my $pages = $ref->[0];
    $r->print("pages.value ".$pages."\n");
  } else {
    throw Error::Simple("No result from DBI query");
  }

  return Apache2::Const::OK;
}

# deletepage: A debugging method, this allows the all of the colored revisions of a page
# to be deleted and re-colored.
# It takes a secret paramiter, which is a shared seceret password
# Also a pid paramiter, which is the page_id of the page to be deleted
sub handle_deletepage {
  my ($dbh, $cgi, $r) = @_;

  my ($rev, $page, $user, $time, $page_title) = get_stdargs($cgi);
  $r->no_cache(1);
  $r->content_type('text/plain; charset=utf-8');
 
  die "Illegal page_id $page for '$page_title'"
	if $page <= 0;

  # Get the page_title.
  # We need to make sure we get the actual page title, as this is currently the only
  # way to get the page_title entry column wikitrust_page to be correct.
  my $sth = $dbh->prepare ("SELECT page_title FROM wikitrust_page WHERE page_id = ?") 
    || die $dbh->errstr;
  $sth->execute($page) || die $dbh->errstr;
  my $title = $sth->fetchrow_hashref();
  if (defined $title) {
    $page_title = $title->{page_title} if $title->{page_title} ne '';
  }

  # Get the title from the q, if its not in the wikitrust_page table
  if (!$page_title){
    $sth = $dbh->prepare ("SELECT page_title FROM wikitrust_queue WHERE page_id = ?") 
      || die $dbh->errstr;
    $sth->execute($page) || die $dbh->errstr;
    if (my $title = $sth->fetchrow_hashref()){
      $page_title = $title->{page_title} if $title->{page_title} ne '';
    }
  }

  # If the right password and page_title are set.
  if(secret_okay($cgi)){
    $dbh->begin_work() || die $dbh->errstr;
    try {
      # Delete the revisions.
      $sth = $dbh->prepare ("DELETE FROM wikitrust_revision WHERE page_id = ?") 
	|| die $dbh->errstr;
      $sth->execute($page) || die $dbh->errstr;

      $sth = $dbh->prepare ("DELETE FROM revision WHERE rev_page = ?") 
	|| die $dbh->errstr;
      $sth->execute($page) || die $dbh->errstr;

      # And delete the page
      $sth = $dbh->prepare ("DELETE FROM wikitrust_page WHERE page_id = ?") 
	|| die $dbh->errstr;
      $sth->execute($page) || die $dbh->errstr;
 
      $sth = $dbh->prepare ("DELETE FROM page WHERE page_id = ?") 
	|| die $dbh->errstr;
      $sth->execute($page) || die $dbh->errstr;
 
      # Clean up the queue
      $sth = $dbh->prepare ("DELETE FROM wikitrust_queue WHERE page_id = ?")
	|| die $dbh->errstr;
      $sth->execute($page) || die $dbh->errstr;

      my $page_path = util_getPageDirname($page);
      if (-e $page_path) {
	rmtree($page_path) || die "unable to delete $page_path: $!";
      }


      $dbh->commit() || die $dbh->errstr;


      mark_for_coloring($page, $page_title, $dbh);

      $r->print("$page_title is being re-colored.");
    } otherwise {
      $dbh->rollback();
      my $E = shift;
      print STDERR $E;
      $r->print("DB error: $E");
    };
  } else {
    $r->print("Incorrect password or missing page_id.");
  }
  return Apache2::Const::OK;
}

sub util_getCache {
    return $cache if defined $cache;
    my $server = $ENV{WT_MEMCACHED} || '127.0.0.1:11211';
    return new Cache::Memcached {
	    'servers' => [ $server ],
	    'debug' => DEBUG,
	    'compress_threshold' => 1000,
	    'namespace' => $ENV{WT_NAMESPACE} || '',
	};
}

sub handle_sharehtml {
    my ($dbh, $cgi, $r) = @_;

    my $myhtml = $cgi->param('myhtml') || '';
    my $revid = $cgi->param('revid') || 0;
    if (($myhtml eq '') || ($revid <= 0)) {
      $r->content_type('text/plain');
      $r->print('Thanks, but no thanks.');
      return Apache2::Const::OK;
    }

    my $c = $r->connection;
    my $remoteip = $c->remote_ip();
    my $proxyip = $r->headers_in->{'X-Forwarded-For'} || '';

warn "Received share from $remoteip (proxy = $proxyip)";

    my $cache = util_getCache();

    my $changed = 0;
    my $data = $cache->get($revid);
    if (!defined $data || (ref $data ne 'HASH')) {
	$changed = 1;
	$data = {
	    'html' => $myhtml,
	    'src' => { $remoteip => 1 },
	    'srcs' => 1,
	    };
    }
    if ($data->{srcs}<5 && !exists $data->{src}->{$remoteip}) {
	$changed = 1;
	$data->{srcs}++;
	$data->{src}->{$remoteip} = 1;
    }

    $cache->set($revid, $data) if $changed;

    $r->content_type('text/plain');
    $r->print('Thanks.');
    return Apache2::Const::OK;
}

sub handle_rawvandalism {
    my ($dbh, $cgi, $r) = @_;
    my ($rev, $page, $user, $time, $page_title) = get_stdargs($cgi);

    if ($rev <= 0) {
      $r->content_type('text/plain');
      $r->print('Need to specify a revid.');
      return Apache2::Const::OK;
    }

    my $q = getQualityData($page_title, $page, $rev, $dbh);
    # Remove fields that aren't helpful in machine learning
    foreach (qw(username next_username prev_username
	user_id next_userid prev_userid
	quality_info page_id
	time_string next_timestamp prev_timestamp))
    {
	delete $q->{$_};
    }

    $r->content_type('application/json');
    $r->headers_out->{'Cache-Control'} = "max-age=" . 10*60;
    $r->print(encode_json($q));
    return Apache2::Const::OK;
}

# Returns the probability that a revision is vandalism.
# > 50% = vandalism, < 50% = regular
# Input is the quality data for a revision.
sub vandalismModel {
    my $q = shift @_;
    my $total = 0.134;
    if ($q->{Min_quality} < -0.662) {
	$total += 0.891;
	if ($q->{L_delta_hist0} < 0.347) {
	    $total += -0.974;
	} else {
	    $total += 0.151;
	}
	if ($q->{Avg_quality} < -0.117) {
	    $total += -0.002;
	} else {
	    $total += -0.695;
	}
    } else {
	$total += -1.203;
    }
    if ($q->{Reputation} < 0.049) {
	$total += 0.358;
	if ($q->{P_prev_hist5} < 0.01) {
	    $total += 0.519;
	} else {
	    $total += -0.298;
	    if ($q->{L_delta_hist2} < 0.347) {
		$total += -1.125;
	    } else {
		$total += 1.113;
	    }
	    if ($q->{Avg_quality} < 0.156) {
		$total += 0.531;
	    } else {
		$total += -2.379;
	    }
	}
    }
    if ($q->{Logtime_next} < 2.97) {
	$total += 1.025;
    } else {
	$total += 0.035;
	if ($q->{Delta} < 3.741) {
	    $total += -0.232;
	} else {
	    $total += 0.212;
	}
    }
    my $prob = 1/(1+exp(-$total));
    return $prob;
}

# Returns the probability that a revision is vandalism.
# > 50% = vandalism, < 50% = regular
# Input is the quality data for a revision.
sub vandalismZdModel {
    my $q = shift @_;
    my $total = 0.134;
    if ($q->{L_delta_hist0} < 0.347) {
	$total += -1.018;
	if ($q->{Hist0} < 0.5) {
	    $total += -0.113;
	} else {
	    $total += 0.528;
	}
    } else {
	$total += 0.766;
	if ($q->{L_delta_hist3} < 0.347) {
	    $total += 0.026;
	    if ($q->{L_delta_hist4} < 0.347) {
		$total += 0.1;
	    } else {
		$total += -0.751;
	    }
	} else {
	    $total += -0.962;
	}
	if ($q->{P_prev_hist0} < 0.004) {
	    $total += 0.094;
	} else {
	    $total += -0.493;
	}
    }
    if ($q->{Anon} == JSON::true) {
	$total += -0.576;
    } else {
	$total += 0.312;
    }
    if ($q->{P_prev_hist9} < 0.115) {
	$total += -0.333;
    } else {
	$total += 0.182;
	if ($q->{Hist7} < 1.5) {
	    $total += 1.217;
	} else {
	    $total += -0.029;
	}
    }
    if ($q->{Delta} < 2.901) {
	$total += -0.251;
    } else {
	$total += 0.182;
    }
    if ($q->{Comment_len} < 18.5) {
	$total += 0.123;
    } else {
	$total += -0.229;
    }
    my $prob = 1/(1+exp(-$total));
    return $prob;
}


sub handle_vandalism {
    my ($dbh, $cgi, $r) = @_;
    my ($rev, $page, $user, $time, $page_title) = get_stdargs($cgi);

    if ($rev <= 0) {
      $r->content_type('text/plain');
      $r->print('Need to specify a revid.');
      return Apache2::Const::OK;
    }

    my $q = getQualityData($page_title, $page, $rev, $dbh);
    my $prob = vandalismModel($q);

    $r->content_type('text/plain');
    $r->headers_out->{'Cache-Control'} = "max-age=" . 3*60;
    $r->print($prob);
    return Apache2::Const::OK;
}

sub handle_vandalismZD {
    my ($dbh, $cgi, $r) = @_;
    my ($rev, $page, $user, $time, $page_title) = get_stdargs($cgi);

    if ($rev <= 0) {
      $r->content_type('text/plain');
      $r->print('Need to specify a revid.');
      return Apache2::Const::OK;
    }

    my $q = getQualityData($page_title, $page, $rev, $dbh);

    # the ZD model needs comment_len
    my $sth = $dbh->prepare ("SELECT rev_comment FROM "
      . "revision WHERE "
      . "rev_id = ? LIMIT 1") || die $dbh->errstr;
    $sth->execute($rev) || die $dbh->errstr;
    my $ans = $sth->fetchrow_hashref();
    if (defined $ans->{rev_comment}) {
	$q->{Comment_len} = length($ans->{rev_comment});
    } else {
	$q->{Comment_len} = 0;
    }

    my $prob = vandalismZdModel($q);

    $r->content_type('text/plain');
    $r->headers_out->{'Cache-Control'} = "max-age=" . 3*60;
    $r->print($prob);
    return Apache2::Const::OK;
}

sub getSubfield {
    my ($info, $name) = @_;
    my $i = index($info, $name);
    confess "Missing field '$name'" if $i < 0;
    $i += length($name) + 1;
    my $j = index($info, ")", $i);
    return substr($info, $i, $j-$i);
}

sub are_users_the_same {
    my ($uid1, $uid2, $un1, $un2) = @_;
    return JSON::true if ($uid1 > 0 && $uid2 > 0 && ($un1 eq $un2));
    return JSON::true if ($uid1 == 0 && $uid2 == 0 && ($un1 eq $un2));
    return JSON::false;
}

sub get_hours {
    my ($t) = @_;
    my $h = substr($t, 8, 2) + 0;
    my $m = substr($t, 10, 2) + 0;
    my $s = substr($t, 12, 2) + 0;
    return ($h + ($m / 60) + ($s / 3600));
}

sub getQualityData {
    my ($page_title, $page_id,$rev_id, $dbh) = @_;

    my @fields = qw( page_id time_string user_id username
		quality_info overall_trust );

    my $sth = $dbh->prepare ("SELECT ".join(', ', @fields)." FROM "
      . "wikitrust_revision WHERE "
      . "revision_id = ?") || die $dbh->errstr;
    $sth->execute($rev_id) || die $dbh->errstr;
    if ($sth->rows() == 0 && defined $page_id && $page_id != 0) {
	# let's try to color, and then try again...
	mark_for_coloring($page_id, $page_title, $dbh);
	sleep(SLEEP_TIME);
	$sth->execute($rev_id) || die $dbh->errstr;
    }

    my $ans = $sth->fetchrow_hashref();
    die "No info on revision $rev_id\n" if !defined $ans;
    $ans->{N_judges} = getSubfield($ans->{quality_info}, "n_edit_judges")+0;
    $ans->{Judge_weight} = getSubfield($ans->{quality_info}, "judge_weight")+0;
    $ans->{Total_quality} = getSubfield($ans->{quality_info}, "total_edit_quality")+0;
    $ans->{Overall_trust} += 0;
    if ($ans->{Judge_weight} > 0.0) {
	$ans->{Avg_quality} = $ans->{Total_quality} / $ans->{Judge_weight};
    } else {
	$ans->{Avg_quality} = 0.0;
    }
    $ans->{Min_quality} = getSubfield($ans->{quality_info}, "min_edit_quality")+0;
    $ans->{Delta} = getSubfield($ans->{quality_info}, "delta")+0;
    my @hist = split(" ", getSubfield($ans->{quality_info}, "word_trust_histogram"));
    for (my $i = 0; $i < @hist; $i++) {
	$ans->{"Hist$i"} = $hist[$i]+0;
    }
    delete $ans->{quality_info};
    $ans->{user_id} += 0;

    @fields = qw( time_string user_id username quality_info );
    $sth = $dbh->prepare ("SELECT ".join(', ', @fields)." FROM "
      . "wikitrust_revision WHERE "
      . "page_id = ? AND time_string < ? "
      . "ORDER BY time_string DESC LIMIT 1") || die $dbh->errstr;
    $sth->execute($ans->{page_id}, $ans->{time_string}) || die $dbh->errstr;
    my $prev = $sth->fetchrow_hashref();
    $prev = {
	'user_id' => 0,
	'username' => '',
	'time_string' => $ans->{time_string},
	'quality_info' => '(word_trust_histogram(0 0 0 0 0 0 0 0 0 0))'
    } if !defined $prev;
    $ans->{prev_userid} = $prev->{user_id}+0;
    $ans->{prev_username} = $prev->{username};
    $ans->{prev_timestamp} = $prev->{time_string};
    @hist = split(" ", getSubfield($prev->{quality_info}, "word_trust_histogram"));
    for (my $i = 0; $i < @hist; $i++) {
	$ans->{"Prev_hist$i"} = $hist[$i]+0;
    }

    @fields = qw( time_string user_id username );
    $sth = $dbh->prepare ("SELECT ".join(', ', @fields)." FROM "
      . "wikitrust_revision WHERE "
      . "page_id = ? AND time_string > ? "
      . "ORDER BY time_string ASC LIMIT 1") || die $dbh->errstr;
    $sth->execute($ans->{page_id}, $ans->{time_string}) || die $dbh->errstr;
    my $next = $sth->fetchrow_hashref();
    $next = { } if !defined $next;
    $ans->{next_userid} = $next->{user_id} || 0;
    $ans->{next_userid} += 0;
    $ans->{next_username} = $next->{username} || '';
    $ans->{next_timestamp} = $next->{time_string} || strftime("%Y%m%d%H%M%S", gmtime());

    $sth = $dbh->prepare ("SELECT user_rep FROM "
      . "wikitrust_user WHERE "
      . "user_id = ?") || die $dbh->errstr;
    $sth->execute($ans->{user_id}) || die $dbh->errstr;
    my $u = $sth->fetchrow_hashref();
    $u = { user_rep => 0 } if !defined $u;
    $ans->{Reputation} = $u->{user_rep}+0;

    # Now build the composite signals
    my $prev_time = UnixDate(ParseDate($ans->{prev_timestamp}." UTC"), "%s");
    my $cur_time = UnixDate(ParseDate($ans->{time_string}." UTC"), "%s");
    my $next_time = UnixDate(ParseDate($ans->{next_timestamp}." UTC"), "%s");
    $ans->{Logtime_next} = log(1+abs($next_time - $cur_time));
    $ans->{Logtime_prev} = log(1+abs($cur_time-$prev_time));
    $ans->{Hour_of_day} = get_hours($ans->{time_string});
    $ans->{curtime_gmt} = $cur_time;
    $ans->{prevtime_gmt} = $prev_time;

    my $prev_length = 0;
    my $curr_length = 0;
    for (my $i = 0; $i < 10; $i++) {
	$prev_length += $ans->{"Prev_hist$i"};
	$curr_length += $ans->{"Hist$i"};
    }
    $ans->{Prev_length} = $prev_length;
    $ans->{Curr_length} = $curr_length;
    $ans->{Log_prev_length} = log(1 + $prev_length);
    $ans->{Log_length} = log(1 + $curr_length);

    if (($curr_length == 0) || ($prev_length == 0)) {
	$ans->{Risk} = 1.0;
    } else {
	$ans->{Risk} = max( $ans->{Delta}, abs($curr_length - $prev_length) ) /
	    ( 1.0 * max($curr_length, $prev_length) );
    }

    for (my $i = 0; $i < 10; $i++) {
	$ans->{"P_prev_hist$i"} = $ans->{"Prev_hist$i"} / (1 + $prev_length);
	$ans->{"L_delta_hist$i"} = $ans->{"Hist$i"} - $ans->{"Prev_hist$i"};
	my $d = $ans->{"Hist$i"} - $ans->{"Prev_hist$i"};
	my $log_d = 0.0;
	if ($d > 0) { $log_d = log(1 + $d); }
	if ($d < 0) { $log_d = -log(1 - $d); }
	$ans->{"L_delta_hist$i"} = $log_d;
    }

    $ans->{Anon} = ($ans->{user_id} == 0 ? JSON::true : JSON::false);
    $ans->{Next_anon} = ($ans->{next_userid} == 0 ? JSON::true : JSON::false);
    $ans->{Prev_anon} = ($ans->{prev_userid} == 0 ? JSON::true : JSON::false);

    $ans->{Next_same_author} = are_users_the_same($ans->{user_id}, $ans->{next_userid},
		$ans->{username}, $ans->{next_username});
    $ans->{Prev_same_author} = are_users_the_same($ans->{user_id}, $ans->{prev_userid},
		$ans->{username}, $ans->{prev_username});

    # Max_dissent is the maximum amount of editors who could have voted
    # with min_quality, if everybody else voted with +1.
    my $max_dissent = 0.0;
    if ($ans->{Min_quality} < 1.0) {
	$max_dissent = ($ans->{Judge_weight} - $ans->{Total_quality}) /
		(1 - $ans->{Min_quality});
    }
    $ans->{Max_dissent} = $max_dissent;
    # Max_revert is the max amount of editors who could have voted
    # with quality -1, if everybody else voted with +1.
    $ans->{Max_revert} = ($ans->{Judge_weight} - $ans->{Total_quality}) / 2.0;

    return $ans;
}

sub handle_selection {
    my ($dbh, $cgi, $r) = @_;
    my ($rev, $page, $user, $time, $page_title) = get_stdargs($cgi);

    my $num_winners_to_return = $cgi->param('winners') || 3;
    my $inv_discount_base = $cgi->param('invDiscountBase') || 200;


    if ($rev > 0) {
      $r->content_type('text/plain');
      $r->print('No revid allowed.');
      return Apache2::Const::OK;
    }

    my $sth = $dbh->prepare ("SELECT revision_id FROM " .
	    "wikitrust_revision WHERE " .
	    "page_id = ?" .
	    "ORDER BY time_string DESC LIMIT 100") || die $dbh->errstr;
    $sth->execute($page) || die $dbh->errstr;
    my @revids = ();
    while (my $ref = $sth->fetchrow_arrayref()) {
	push @revids, $ref->[0];
    }

    my @selection = ();
    my $num_past_revisions = 0;

    # use convoluted parsing of time, because OSX uses 1-Jan-1904
    # for the epoch time.  Using this construct should give us units
    # that matched how the time_string was parsed for each revision.
    my $current_time = UnixDate(ParseDate(
		scalar(localtime(time()))
	), "%s");;
    foreach my $rev (@revids) {
	$num_past_revisions++;
	my $q = getQualityData($page_title, $page, $rev, $dbh);
	my $quality = selectionModel($q);
	my $revision_age = $current_time - $q->{curtime_gmt};
	my $risk = $q->{Risk};
	my $discount = selection_compute_discount( $inv_discount_base,
		$num_past_revisions, $revision_age );
	# The Forced is the difference in discounts
	my $prev_revision_age = $current_time - $q->{prevtime_gmt};
	my $prev_discount = selection_compute_discount($inv_discount_base,
		$num_past_revisions+1, $prev_revision_age);
	my $forced = $discount - $prev_discount;
	my $discounted_quality = $quality * $discount;
	push @selection, [ $discounted_quality, 1-$risk, $rev,
	     $q->{time_string}, $quality, $risk, $forced, $discount,
	     $revision_age / (24 * 3600.0), $num_past_revisions ];
	@selection = sort selection_arraySort @selection;
	# If there is no hope of entering the top-N, stops.
	if (@selection >= $num_winners_to_return) {
	   my $threshold = $selection[-1]->[0];
	   last if $discount < $threshold;
	}
    }
    $#selection = $num_winners_to_return-1 if @selection > $num_winners_to_return;
    my @result = ();
    for (my $rank = 0; $rank < @selection; $rank++) {
	my $s = $selection[$rank];
	push @result, {
		'Page_id' => $page+0,
		'Revision_id' => $s->[2]+0,
		'Date' => $s->[3],
		'Quality' => $s->[4],
		'Risk' => $s->[5],
		'Forced' => $s->[6],
		'Discount' => $s->[7],
		'Days_ago' => $s->[8],
		'Revisions_ago' => $s->[9],
		'Rank' => $rank+1,
		'Url' => "http://en.wikipedia.org/w/index.php?oldid=" .
			$s->[2] . "&trust",
	};
    }

    $r->content_type('application/json');
    $r->headers_out->{'Cache-Control'} = "max-age=" . 30*60;
    $r->print(encode_json(\@result));
    return Apache2::Const::OK;
}

# Returns the probability that a revision is not vandalism.
# < 50% = vandalism, > 50% = regular
# Input is the quality data for a revision.
sub selectionModel {
    my $q = shift @_;
    my $total = 0.134;
    if ($q->{Min_quality} < -0.662) {
	$total += 0.891;
	if ($q->{L_delta_hist0} < 0.347) {
	    $total += -0.974;
	} else {
	    $total += 0.151;
	}
	if ($q->{Max_dissent} < -0.171) {
	    $total += -1.329;
	} else {
	    $total += 0.086;
if (0) {		# DEAD CODE: we don't have comment lengths
	    if ($q->{Next_comment_len} < 110.5) {
		$total += -0.288;
	    } else {
		$total += 0.169;
	    }
}
	}
    } else {
	$total += -1.203;
    }
    if ($q->{Reputation} < 0.049) {
	$total += 0.358;
    } else {
	$total += -1.012;
	if ($q->{P_prev_hist5} < 0.01) {
	    $total += 0.482;
	} else {
	    $total += -0.376;
	    if ($q->{Avg_quality} < 0.156) {
		$total += 0.5;
	    } else {
		$total += -2.625;
	    }
	    if ($q->{L_delta_hist2} > 0.347) {
		$total += -0.757;
	    } else {
		$total += 1.193;
	    }
	}
    }
    if ($q->{Logtime_next} < 2.74) {
	$total += 1.188;
    } else {
	$total += 0.045;
	if ($q->{Delta} < 3.741) {
	    $total += -0.255;
	} else {
	    $total += 0.168;
	}
    }
    my $prob = 1/(1+exp($total));
    return $prob;
}

sub selection_compute_discount {
    my ($inv_discount_base, $num_past_revisions, $revision_age) = @_;
    my $d = $inv_discount_base / ( $inv_discount_base + $num_past_revisions +
	($revision_age / AGE_REVISION_CONVERSION));
    return $d;
}

# specialized routine for sorting an array of tuples
sub selection_arraySort {
    for (my $i = 0; $i < @{$a}; $i++) {
	my $order = ($b->[$i] <=> $a->[$i]);
	return $order if $order != 0;
    }
    return 0;
}


1;
