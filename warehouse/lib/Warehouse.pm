# -*- mode: perl; perl-indent-level: 4; -*-

package Warehouse;

use Digest::MD5;
use MogileFS::Client;
use Cache::Memcached;
use LWP::UserAgent;
use HTTP::Request::Common;

do '/etc/warehouse/warehouse-client.conf'
    or die "Failed to load /etc/warehouse/warehouse-client.conf";
do '/etc/warehouse/memcached.conf.pl'
    or die "Failed to load /etc/warehouse/memcached.conf.pl";

=head1 NAME

Warehouse -- Client library for the storage warehouse.

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

 use Warehouse;

 my $whc = Warehouse->new;

 my $sample_content = "some binary data";

 # Store data
 my $filehash = $whc->store_block ($sample_content)
     or die "write failed: ".$whc->errstr;

 # Store a [possibly >64MB] file into multiple blocks
 $whc->write_start or die "Write failed";
 while(<>) {
     $whc->write_data ($_) or die "Write failed";
 }
 my @filehashes = $whc->write_finish or die "Write failed";

 # Retrieve data
 my $content = $whc->fetch_block ($filehash);

 # Retrieve data without verifying hash($content)==$filehash
 my $content = $whc->fetch_block ($filehash, 0);

 # Give a manifest a name in the warehouse
 $whc->store_manifest_name ($newkey, $oldkey, $name)
     or die "update failed";

 # Retrieve key of a named manifest
 my $key = $whc->fetch_manifest_key_by_name ($name);

 # Get a list of mapreduce jobs
 my $joblist = $whc->job_list;
 my $joblist = $whc->job_list (id_min => 123, id_max => 345);
 print map { "job ".$_->{id}." was a ".$_->{mrfunction}.".\n" } @$joblist;

=head1 METHODS

=head2 new

 my $whc = Warehouse->new( %OPTIONS );

Creates a new Warehouse object.  Returns the new object on success.
Dies on failure.

=head3 Options

=over

=item warehouse_servers

Comma-separted list of warehouse servers: host:port,host:port,...
Comes from warehouse-client.conf if not specified.

=item memcached_servers

Memcached servers (arrayref; see Cache::Memcached(3)).  Comes from
memcached.conf.pl if not specified.

=item mogilefs_trackers

Comma-separated list of MogileFS tracker hosts.  Comes from
warehouse-client.conf if not specified.

=item mogilefs_domain

MogileFS domain.  Comes from warehouse-client.conf if not specified.

=item mogilefs_directory_class

MogileFS class used for storing directory listings.  Comes from
warehouse-client.conf if not specified.

=item mogilefs_file_class

MogileFS class used for storing files.  Comes from
warehouse-client.conf if not specified.

=item memcached_size_threshold

Maximum data size to store in memcached.  Default is 1 megabyte.  Zero
means never use memcached for data.  Negative means never use
memcached for either data or mogilefs paths.

=back

=cut


sub new
{
    my $class = shift;
    my $self = { @_ };
    bless ($self, $class);
    return $self->_init();
}

sub _init
{
    my Warehouse $self = shift;
    my $attempts = 0;

    $self->{warehouse_servers} = $warehouse_servers
	if !defined $self->{warehouse_servers};

    $self->{memcached_size_threshold} = 1048576
	if !defined $self->{memcached_size_threshold};

    $self->{memcached_servers} = $memcached_servers_arrayref
	if !defined $self->{memcached_servers};

    $self->{mogilefs_trackers} = $mogilefs_trackers
	if !defined $self->{mogilefs_trackers};

    $self->{mogilefs_domain} = $mogilefs_domain
	if !defined $self->{mogilefs_domain};

    $self->{mogilefs_directory_class} = $mogilefs_directory_class
	if !defined $self->{mogilefs_directory_class};

    $self->{mogilefs_file_class} = $mogilefs_file_class
	if !defined $self->{mogilefs_file_class};

    $self->{mogilefs_size_threshold} = 0
	if !defined $self->{mogilefs_size_threshold};

    $self->{debug_mogilefs_paths} = 0
	if !defined $self->{debug_mogilefs_paths};

    $self->{timeout} = 10
	if !defined $self->{timeout};

    $self->{rand01} = int(rand 2);

    $self->{stats_time_created} = time;
    $self->{stats_read_bytes} = 0;
    $self->{stats_read_blocks} = 0;
    $self->{stats_read_attempts} = 0;
    $self->{stats_wrote_bytes} = 0;
    $self->{stats_wrote_blocks} = 0;
    $self->{stats_wrote_attempts} = 0;
    $self->{stats_memread_bytes} = 0;
    $self->{stats_memread_blocks} = 0;
    $self->{stats_memread_attempts} = 0;
    $self->{stats_memwrote_bytes} = 0;
    $self->{stats_memwrote_blocks} = 0;
    $self->{stats_memwrote_attempts} = 0;

    $self->{ua} = LWP::UserAgent->new;
    $self->{ua}->timeout ($self->{timeout});

    while (!$self->{mogc} && ++$attempts <= 5)
    {
	$self->{mogc} = eval {
	    MogileFS::Client->new
		(hosts => [split(",", $self->{mogilefs_trackers})],
		 domain => $self->{mogilefs_domain},
		 timeout => $self->{timeout});
	  };
	last if $self->{mogc};
	print STDERR "MogileFS connect failure #$attempts: $@\n";
	    sleep $attempts;
    }
    die "Can't connect to MogileFS" if !$self->{mogc};

    if (@{$self->{memcached_servers}} &&
	$self->{memcached_size_threshold} >= 0)
    {
	$self->{memc} = new Cache::Memcached {
	    'servers' => $self->{memcached_servers},
	    'debug' => 0,
	};
	$self->{memc}->enable_compress (0);
    }

    if ($self->{memcached_size_threshold} + 1
	< $self->{mogilefs_size_threshold})
    {
	warn("Warehouse: Blocks with "
	     .$self->{memcached_size_threshold}
	     ." < size < "
	     .$self->{mogilefs_size_threshold}
	     ." will not be stored in either memcached or mogilefs!\n");
    }

    return $self;
}


=head2 store_block

 my $hash = $whc->store_block ($data)

Store a <= 64MB chunk of data.  On success, returns a hash which can
be used to retrieve the data.  On failure, returns undef.

=cut


sub store_block
{
    my $self = shift;
    my $dataarg = shift;
    my $dataref = ref $dataarg ? $dataarg : \$dataarg;

    my $mogilefs_class = shift || $self->{mogilefs_file_class};
    my $hash = Digest::MD5::md5_hex ($$dataref);

    my $alreadyhave = $self->fetch_block ($hash, 1, 1);
    if (defined $alreadyhave && $$dataref eq $alreadyhave)
    {
	return $hash;
    }

    if (length $$dataref <= $self->{memcached_size_threshold})
    {
	$self->{stats_memwrote_attempts} ++;
	$self->{stats_memwrote_blocks} ++;
	$self->{stats_memwrote_bytes} += length $$dataref;
	$self->{memc}->set ($hash, $$dataref);
    }

    if (length $$dataref >= $self->{mogilefs_size_threshold})
    {
	eval
	{
	    $self->_mogilefs_write ($hash, $dataref, $mogilefs_class);
	}
	or eval
	{
	    $self->_mogilefs_write ($hash, $dataref, $mogilefs_class);
	}
	or do
	{
	    $self->{errstr} = $@;
	    return undef;
	}
    }

    return $hash;
}



sub _mogilefs_write
{
    my $self = shift;
    my $hash = shift;
    my $dataref = shift;
    my $class = shift;
    $self->{stats_wrote_attempts} ++;
    my $mogfh = $self->{mogc}->new_file ($hash, $class);
    if (!print $mogfh $$dataref)
    {
	close $mogfh;
	die "MogileFS write failed: $!";
    }
    if (!close $mogfh)
    {
	die "MogileFS write failed: $!";
    }
    $self->{stats_wrote_bytes} += length $$dataref;
    $self->{stats_wrote_blocks} ++;
    1;
}



=head2 write_start

 $whc->write_start;

Prepares to store a file (possibly more than 64M bytes) in the
warehouse.  Analogous to open(2).

=cut


sub write_start
{
    my $self = shift;
    my $is_directory = shift;
    $self->{output_buffer} = "";
    $self->{hashes_written} = [];
    $self->{write_class} = ($is_directory
			    ? $self->{mogilefs_directory_class}
			    : $self->{mogilefs_file_class});
    1;
}


=head2 write_data

 $whc->write_data ($data) or die "Write failed.";

Appends some data to a file in the warehouse.  Analogous to write(2).
Returns true on success.  Returns undef on failure.

=cut


sub write_data
{
    my $self = shift;
    my $data_arg = shift;
    my $dataref = ref $data_arg ? $data_arg : \$data_arg;
    $self->{output_buffer} .= $$dataref;
    while (length ($self->{output_buffer}) >= $blocksize)
    {
	my $hash = $self->store_block (substr ($self->{output_buffer},
					       0, $blocksize),
				       $self->{write_class});
	if (!$hash)
	{
	    return undef;
	}
	push @{$self->{hashes_written}}, "$hash-0";
	substr ($self->{output_buffer}, 0, $blocksize) = "";
    }
    1;
}


=head2 write_finish

 my @hashes = $whc->write_finish or die "Write failed";

Writes to disk all remaining data from previous write_data() calls.
Analogous to close(2).  Returns a list of hashes on success.  Returns
undef on failure.

=cut


sub write_finish
{
    my $self = shift;
    if (length ($self->{output_buffer}) > 0)
    {
	my $hash = $self->store_block ($self->{output_buffer},
				       $self->{write_class});
	if (!$hash)
	{
	    return undef;
	}
	my $blocklength = length $self->{output_buffer};
	push @{$self->{hashes_written}}, ($blocklength == $blocksize
					  ? "$hash-0"
					  : "$hash+$blocklength");
	$self->{output_buffer} = "";
    }
    if (wantarray)
    {
      return @{$self->{hashes_written}};
    }
    else
    {
      # return hash list as a manifest key (comma-separated, without
      # block size hints)
      return join (",",
		   map {
		     /^(-\d+ )?([0-9a-f]{32})/;
		     $2;
		   } @{$self->{hashes_written}});
    }
}


=head2 fetch_block

 foreach my $hash (@hashes)
 {
     my $data = $whc->fetch_block ($hash) or die "Read failed";
     print $data;
 }

Retrieves content previously stored using L</store_block> or
L</write_data>.  Returns binary data on success.  Returns undef on
failure.

=cut


sub fetch_block
{
    my $self = shift;
    my $hash = shift;
    my $verifyflag = shift;
    $verifyflag = 1 if !defined $verifyflag;
    my $nowarnflag = shift;

    my $sizehint;
    if ($hash =~ s/^(-(\d+) )//)
    {
	$sizehint = $blocksize - $2;
    }
    elsif ($hash =~ s/\+(\d+)$//)
    {
	$sizehint = $1;
    }
    elsif ($hash =~ s/-(\d+)$//)
    {
	$sizehint = $blocksize - $1;
    }

    my $data;
    if ((defined $sizehint ? $sizehint : 1)
	<= $self->{memcached_size_threshold})
    {
	$self->{stats_memread_attempts} ++;
	$data = $self->{memc}->get ($hash);
    }
    if (defined $data)
    {
	$self->{stats_memread_bytes} += length $data;
	$self->{stats_memread_blocks} ++;
	if (!$verifyflag || $hash eq Digest::MD5::md5_hex ($data))
	{
	    return $data;
	}
	$self->{memc}->delete ($hash);
	warn "Memcached get($hash) failed verify; deleted"
	    unless $nowarnflag;
    }

    $self->{stats_read_attempts} ++;
    my $dataref = $self->_get_file_data ($hash, $verifyflag);
    if (!defined $dataref)
    {
	warn "_get_file_data ($hash) failed: ".$self->{errstr}
	    unless $nowarnflag;
	return undef;
    }
    $self->{stats_read_bytes} += length $$dataref;
    $self->{stats_read_blocks} ++;

    if (length $$dataref <= $self->{memcached_size_threshold})
    {
	$self->{stats_memwrote_attempts} ++;
	$self->{stats_memwrote_blocks} ++;
	$self->{stats_memwrote_bytes} += length $$dataref;
	$self->{memc}->set ($hash, $$dataref);
    }

    return $$dataref;
}



=head2 fetch_manifest_by_key

 my $manifest = $whc->fetch_manifest_by_key ($key);

Retrieve a manifest with the given key.

Note: If the manifest is large, this is not an efficient way to read
it.  Better to fetch one block at a time.

=cut

sub fetch_manifest
{
  my $self = shift;
  my $key = shift;
  return join ("", map { $self->fetch_block ($_) } split (",", $key));
}



=head2 store_manifest_by_name

 $whc->store_manifest_by_name ($newkey, $oldkey, $name)
     or die "failed";

=cut


sub store_manifest_by_name
{
    my $self = shift;
    my ($newkey, $oldkey, $name) = @_;

    if (!defined $oldkey)
    {
	$oldkey = "NULL";
    }
    my $reqtext = "$newkey $oldkey $name";

    # fake signature -- server won't notice anyway
    my $signedreq = "-----BEGIN PGP SIGNED MESSAGE-----\n"
	. "Faked\n\n"
	. $reqtext
	. "\n-----BEGIN PGP SIGNATURE-----\n"
	. "Faked\n";

    my $url = "http://".$self->{warehouse_servers}."/put";
    my $req = HTTP::Request->new (POST => $url);
    $req->header ('Content-Length' => length $signedreq);
    $req->content ($signedreq);
    my $r = $self->{ua}->request ($req);

    if ($r->is_success)
    {
	if ($r->content =~ /^200 \Q$reqtext\E/)
	{
	    return 1;
	}
	else
	{
	    $self->{errstr} = "Server returned success but response was not in expected format: ".$r->content;
	}
    }
    else
    {
	$self->{errstr} = "http request failed: ".$r->status_line;
    }
    return undef;
}



=head2 fetch_manifest_key_by_name

 my $key = $whc->fetch_manifest_key_by_name ($name);

Looks up a named (signed) manifest.

Returns a key, which can be used to retrieve the manifest with
L</fetch_block>.  On failure, returns undef.

=cut


sub fetch_manifest_key_by_name
{
    my $self = shift;
    my $name = shift;

    my $url = "http://".$self->{warehouse_servers}."/get";
    my $req = HTTP::Request->new (POST => $url);
    $req->header ('Content-Length' => length $name);
    $req->content ($name);
    my $r = $self->{ua}->request ($req);

    if ($r->is_success)
    {
	my ($status, $key, $checkname) = split (" ", $r->content, 3);
	chomp $checkname;
	if ($status ne "200")
	{
	    $self->{errstr} = "server returned success but status $status != 200";
	    return undef;
	}
	if ($checkname ne $name)
	{
	    $self->{errstr} = "server sent wrong name ($checkname instead of $name)";
	    return undef;
	}
	return $key;
    }
    else
    {
	$self->{errstr} = "http request failed: ".$r->status_line;
	return undef;
    }
}



=head2 list_manifests

 my @manifest = $whc->list_manifests;
 foreach (@manifest)
 {
   my ($key, $name) = @$_;
   ...
 }

=cut

sub list_manifests
{
  my $self = shift;

  my $url = "http://".$self->{warehouse_servers}."/list";
  my $req = HTTP::Request->new (GET => $url);
  my $r = $self->{ua}->request ($req);

  my @ret;
  if ($r->is_success)
  {
    foreach (split ("\n", $r->content))
    {
      my ($key, $name) = split (/ /);
      last if (!defined $name);	# XXX should check md5 of entire response here
      push @ret, [$key, $name];
    }
  }
  else
  {
    $self->{errstr} = $r->status_line;
    return undef;
  }

  return @ret;
}



=head2 job_list

    my $joblist = $whc->job_list;
    my $joblist = $whc->job_list (id_min => 123, id_max => 345);

=cut

sub job_list
{
    my $self = shift;
    my %what = @_;
    my $url = "http://".$self->{warehouse_servers}."/job/list";
    $url .= "?".$what{id_min}."-".$what{id_max}
	if $what{id_min} || $what{id_max};
    my $resp = $self->{ua}->get ($url);
    if ($resp->is_success)
    {
	my @ret;
	foreach (split /\n\n/, $resp->content)
	{
	    my %h;
	    foreach (split /\n/)
	    {
		my ($k, $v) = split /=/, $_, 2;
		$h{$k} = $v;
	    }
	    push @ret, \%h;
	}
	return \@ret;
    }
    else
    {
	return undef;
    }
}



=head2 iostats

 print $whc->iostats;

Returns a human-readable summary of blocks and bytes sent to and
received from the warehouse, as well as average I/O bandwidth since
the client object was created.

=cut


sub iostats
{
    my $self = shift;
    my $elapsed = time - $self->{stats_time_created};
    if ($elapsed <= 0) { $elapsed = 1 };
    return sprintf
	("Mem In: %d bytes in %d/%d ops. Out: %d bytes in %d/%d ops.\n"
	 . "Mem In: %d Mbps. Out: %d Mbps. Total: %d Mbps.\n"
	 . "Disk In: %d bytes in %d/%d ops. Out: %d bytes in %d/%d ops.\n"
	 . "Disk In: %d Mbps. Out: %d Mbps. Total: %d Mbps.\n",
	 (map { $self->{$_} } qw(stats_memread_bytes
				 stats_memread_blocks
				 stats_memread_attempts
				 stats_memwrote_bytes
				 stats_memwrote_blocks
				 stats_memwrote_attempts)),
	 $self->{stats_memread_bytes} * 8 / $elapsed / 1000000,
	 $self->{stats_memwrote_bytes} * 8 / $elapsed / 1000000,
	 ($self->{stats_memread_bytes} +
	  $self->{stats_memwrote_bytes}) * 8 / $elapsed / 1000000,
	 (map { $self->{$_} } qw(stats_read_bytes
				 stats_read_blocks
				 stats_read_attempts
				 stats_wrote_bytes
				 stats_wrote_blocks
				 stats_wrote_attempts)),
	 $self->{stats_read_bytes} * 8 / $elapsed / 1000000,
	 $self->{stats_wrote_bytes} * 8 / $elapsed / 1000000,
	 ($self->{stats_read_bytes} +
	  $self->{stats_wrote_bytes}) * 8 / $elapsed / 1000000);
}


sub _get_file_data
{
    my $self = shift;
    my $hash = shift;
    my $verifyflag = shift;

    $self->{errstr} = "No paths found for $hash";
    foreach my $trycache (1, 0)
    {
	my $pathref;
	if ($trycache)
	{
	    $pathref = $self->{memc}->get
		($hash."\@".$self->{mogilefs_trackers})
		unless $self->{memcached_size_threshold} < 0;
	    next if !$pathref;
	}
	else
	{
	    my @paths = $self->{mogc}->get_paths ($hash, { noverify => 1 });
	    $pathref = \@paths;
	    $self->{memc}->set
		($hash."\@".$self->{mogilefs_trackers}, $pathref)
		unless $self->{memcached_size_threshold} < 0;
	}
	if ($self->{rand01} && @$pathref > 1)
	{
	    splice @$pathref, 0, 0, (splice @$pathref, 1);
	}
	foreach (@$pathref)
	{
	    my $r = $self->{ua}->get ($_);
	    if ($r->is_success)
	    {
		print STDERR "Read $hash from $_\n"
		    if $self->{debug_mogilefs_paths};
		my $data = $r->content;
		if (!$verifyflag ||
		    $hash eq Digest::MD5::md5_hex ($data))
		{
		    return \$data;
		}
		else
		{
		    $self->{errstr} = "Checksum failed: $hash $_";
		    print STDERR $self->{errstr}."\n";
		}
	    }
	    else
	    {
		$self->{errstr} = $r->status_line;
	    }
	}
    }
    return undef;
}



sub errstr
{
    my $self = shift;
    return $self->{errstr};
}

1;
