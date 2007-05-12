#!/usr/bin/perl

use strict;
use MogileFS::Client;
use Digest::MD5 'md5_hex';
use DBI;

do '/etc/polony-tools/config.pl';

my @trackers = qw(localhost:6001);
my $hdr;
my $boundary;
my $lastboundary;
my $mogc;
my %part;
my %param = (domain => $mogilefs_default_domain);

my $dbh = DBI->connect($main::mogilefs_dsn,
		       $main::mogilefs_username,
		       $main::mogilefs_password);

print "Content-type: text/plain\n\n";

while(<>)
{
    if (!defined ($boundary))
    {
	$boundary = $_;
	s/(\r?\n)/--$1/;
	$lastboundary = $_;
	$hdr = 1;
    }
    elsif ($_ eq $boundary || $_ eq $lastboundary)
    {
	$part{content} =~ s/\r?\n$//;
	if (defined($part{filename}))
	{
	    if (!defined ($mogc))
	    {
		$mogc = MogileFS::Client->new (domain => $param{domain},
					       hosts => [@trackers]);
	    }
	    if ($mogc->store_content($part{filename},
				     $param{class},
				     $part{content})
		== length($part{content}))
	    {
		print STDERR "$part{filename} $param{class} $param{domain}\n";
		my $md5 = md5_hex($part{content});
		$dbh->do("insert delayed into md5 select fid, "
			 . $dbh->quote($md5)
			 . " from file"
			 . " left join domain on domain.dmid=file.dmid"
			 . " where dkey="
			 . $dbh->quote($part{filename})
			 . " and domain.namespace="
			 . $dbh->quote($param{domain}));
	    }
	    else
	    {
		$mogc->delete($part{filename});
		print STDERR "$part{filename} DELETED\n";
	    }
	}
	else
	{
	    $param{$part{name}} = $part{content};
	}
	$hdr = 1;
	%part = ();
    }
    elsif ($hdr)
    {
	if (/^\r\n/)
	{
	    $hdr = 0;
	}
	elsif (/^Content-disposition:/i)
	{
	    if (/ name=\"(.*?)\"/)
	    {
		$part{name} = $1;
	    }
	    if (/ filename=\"(.*?)\"/)
	    {
		$part{filename} = $1;
	    }
	}
    }
    else
    {
	$part{content} .= $_;
    }
}

do { } while (-1 != wait);

# arch-tag: 89ed3513-fe5d-11db-9207-0015f2b17887

