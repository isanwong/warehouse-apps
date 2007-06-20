#!/usr/bin/perl

use strict;
use MogileFS::Client;
use Digest::MD5 'md5_hex';
use DBI;
use Time::HiRes qw(gettimeofday tv_interval);

do '/etc/polony-tools/config.pl';

my %opts = qw (quick 0);
while (@ARGV && $ARGV[0] =~ /^--?([^-].*?)(=(.*))?$/)
{
    if (defined ($2))
    {
	$opts{$1} = $3;
    }
    else
    {
	$opts{$1} = 1;
    }
    shift @ARGV;
}
my $keyprefix = shift @ARGV;

my @trackers = $main::mogilefs_trackers;
my @copyto_trackers = $main::copyto_mogilefs_trackers;

my $mogc = MogileFS::Client->new
    (domain => $main::mogilefs_default_domain,
     hosts => [@main::mogilefs_trackers]);

my $copyto_mogc = MogileFS::Client->new
    (domain => $main::copyto_mogilefs_default_domain,
     hosts => [@main::copyto_mogilefs_trackers]);

my $dbh = DBI->connect($main::mogilefs_dsn,
		       $main::mogilefs_username,
		       $main::mogilefs_password);

my $copyto_dbh = DBI->connect($main::copyto_mogilefs_dsn,
			      $main::copyto_mogilefs_username,
			      $main::copyto_mogilefs_password);

my $sth = $dbh->prepare("select dkey, md5 from file left join md5 on md5.fid=file.fid left join file_on on file.fid=file_on.fid where dkey like ? and file_on.fid is not null group by dkey order by binary dkey");

my $copyto_sth = $copyto_dbh->prepare("select dkey, md5 from file left join md5 on md5.fid=file.fid left join file_on on file.fid=file_on.fid where dkey like ? and file_on.fid is not null order by binary dkey");

my $md5_sth = $copyto_dbh->prepare ("insert into md5 (fid, md5) select fid, ? from file left join domain on domain.dmid=file.dmid where dkey=? and domain.namespace=?");

print "Getting local manifest.\n";
$sth->execute ($keyprefix . "%") or die;

print "Getting remote manifest.\n";
$copyto_sth->execute ($keyprefix . "%") or die;

my @row = $sth->fetchrow_array;
my @copyto_row = $copyto_sth->fetchrow_array;

my $txbytes = 0;
my $t0 = [gettimeofday];

print "Comparing manifests.\n";
while (@row)
{
    # if @copyto_row already has this dkey, fetch next copyto_row
    if (@copyto_row
	&& $row[0] eq $copyto_row[0]
	&& ($row[1] eq $copyto_row[1]
	    || !defined($row[1])
	    || !defined($copyto_row[1])))
    {
	printf ("skip    %s\n", $row[0])
	    if $opts{v};
    }
    # else, fetch from $mogc and inject in $copyto_mogc
    else
    {
	if (@copyto_row
	    && $row[0] eq $copyto_row[0])
	{
	    printf ("md5!!!! %-32s %s\n", $copyto_row[1], $copyto_row[0]);
	}
	printf ("copy    %-50s ", $row[0]);

	my ($dkey, $md5) = @row;
	my $content = $mogc->get_file_data ($dkey);
	my $ok = defined($content);
	if (!$ok)
	{
	    printf ("\nempty!! %-50s ", $row[0]);
	}
	if ($ok)
	{
	    $ok = $copyto_mogc->store_content
		($dkey,
		 $main::copyto_mogilefs_default_class,
		 $content);
	}
	if ($ok)
	{
	    $txbytes += length $$content;
	    if (!$opts{quick})
	    {
		$md5_sth->execute ($md5, $dkey, $main::copyto_mogilefs_default_domain);
	    }
	}
	my $speed = $txbytes / 1048576 / tv_interval($t0);
	printf ("%0.2f MB/s\n", $speed);
	if (!$ok)
	{
	    printf ("FAIL    %-32s\n", $row[0]);
	}
    }

    @row = $sth->fetchrow_array;
    while (@copyto_row && ($row[0] gt $copyto_row[0]))
    {
	@copyto_row = $copyto_sth->fetchrow_array;
    }
}

# arch-tag: 7d3f35aa-1df0-11dc-9207-0015f2b17887
