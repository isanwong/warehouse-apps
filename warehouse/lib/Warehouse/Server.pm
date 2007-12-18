# -*- mode: perl; perl-indent-level: 4; -*-

package Warehouse::Server;

use HTTP::Daemon;
use HTTP::Response;
use Crypt::GpgME;
use Digest::MD5;
use DBI;

=head1 NAME

Warehouse::Server -- Controller for the storage warehouse.

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

 use Warehouse::Server;

 my $whs = Warehouse::Server->new;
 $whs->run;

=head1 METHODS

=head2 new

 my $whs = Warehouse::Server->new( %OPTIONS );

Creates a new server.  Returns the new object on success.  Dies on
failure.

=head3 Options

=over

=item DatabaseDSN

Reference to an array with database connection info, for example:

  [ "DBI:mysql:database=warehouse;host=dbhost",
    "whserver",
    "DBPASSWORDHERE" ]

=item ListenAddress

IP address to listen on.  Default is "0.0.0.0".

=item ListenPort

Port number to listen on.  Default is 24848.

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
    my Warehouse::Server $self = shift;

    $self->{ListenAddress} = "0.0.0.0"
	if !defined $self->{ListenAddress};

    $self->{ListenPort} = "24848"
	if !defined $self->{ListenPort};

    $self->{daemon} = new HTTP::Daemon
	( LocalAddr => $self->{ListenAddress},
	  LocalPort => $self->{ListenPort} );

    $self->{daemon} or die "HTTP::Daemon::new failed";

    $self->_reconnect;

    return $self;
}

sub _reconnect
{
    my $self = shift;
    $self->{dbh} = DBI->connect (@ { $self->{DatabaseDSN} });
    $self->{dbh} or die DBI->errstr;
}


=head2 url

  my $url = $whs->url;

Returns the base url of the server (eg. http://1.2.3.4:1234/).

=cut


sub url
{
    my $self = shift;
    return $self->{daemon}->url;
}


=head2 run

  $whs->run;

Listens for connections, and handles requests from clients.

=cut


my $kill = 0;

sub run
{
    my $self = shift;
    local $SIG{INT} = sub { $Warehouse::Server::kill = 1; };
    local $SIG{TERM} = sub { $Warehouse::Server::kill = 1; };
    local $| = 1;
    while (my $c = $self->{daemon}->accept)
    {
	while (my $r = $c->get_request)
	{
	    print(scalar (localtime) .
		  " " . $c->peerhost() .
		  " R" .
		  " " . $r->method .
		  " " . (map { s/[^\/\w_]/_/g; $_; } ($r->url->path))[0] .
		  "\n");

	    $self->_reconnect if !$self->{dbh}->ping;

	    if ($r->method eq "GET" and $r->url->path eq "/list")
	    {
		my $resp = HTTP::Response->new (200, "OK", []);
		$resp->{sth} = $self->{dbh}->prepare
		    ("select mkey, name from manifests order by name")
		    or die DBI->errstr;
		$resp->{sth}->execute()
		    or die DBI->errstr;
		$resp->{md5_ctx} = Digest::MD5->new;
		$resp->{sth_finished} = 0;
		$resp->content (sub { _callback_manifest($resp) });
		$c->send_response ($resp);
	    }
	    elsif ($r->method eq "POST" and $r->url->path eq "/get")
	    {
		my $sql = "select mkey from manifests where name=?";
		my $sth = $self->{dbh}->prepare ($sql)
		    or die DBI->errstr;
		my $result = "";
		foreach my $name (split ("\n", $r->content))
		{
		    if (0 < length $name)
		    {
			$sth->execute ($name)
			    or die DBI->errstr;
			my ($key) = $sth->fetchrow;
			if ($key)
			{
			    $result .= "200 $key $name\n";
			}
			else
			{
			    $result .= "404  $name\n";
			}
		    }
		}
		my $resp = HTTP::Response->new (200, "OK", [], $result);
		$c->send_response ($resp);
	    }
	    elsif ($r->method eq "GET" and $r->url->path eq "/ping")
	    {
		my $resp = HTTP::Response->new (200, "OK", [], "ack\n");
		$c->send_response ($resp);
	    }
	    elsif ($r->method eq "POST" and $r->url->path eq "/put")
	    {
		my $result;
		my $signedmessage = $r->content;

		# XXX verify signature here XXX
		$signedmessage =~ /-----BEGIN PGP SIGNED MESSAGE-----\n.*?\n\n(.*?)\n-----BEGIN PGP SIGNATURE/s;
		my $plainmessage = $1;
		my $verified = $plainmessage =~ /\S/;

		if (!$verified)
		{
		    my $resp = HTTP::Response->new
			(401, "SigFail",
			 [], "Signature verification failed.\n");
		    $c->send_response ($resp);
		    last;
		}

		my $ok = 1;
		foreach my $put (split ("\n", $plainmessage))
		{
		    my ($newkey, $oldkey, $name) = split (/ /, $put, 3);
		    print(scalar (localtime) .
			  " " . $c->peerhost() .
			  " T" .
			  " " . $newkey .
			  " " . $oldkey .
			  " " . $name .
			  "\n");

		    my $sth;
		    my $ok;
		    if ($oldkey eq "NULL")
		    {
			$sth = $self->{dbh}->prepare
			    ("insert into manifests (mkey, name) values (?, ?)");
			$ok = $sth->execute ($newkey, $name);
		    }
		    elsif ($newkey eq "NULL")
		    {
			$sth = $self->{dbh}->prepare
			    ("delete from manifests where name=? and mkey=?");

			$ok = $sth->execute ($name, $oldkey)
			    && $sth->rows == 1;
		    }
		    else
		    {
			$sth = $self->{dbh}->prepare
			    ("update manifests set mkey=? where mkey=? and name=?");
			$ok = $sth->execute ($newkey, $oldkey, $name)
			    && $sth->rows == 1;
		    }

		    if ($ok)
		    {
			$result .= "200 $newkey $oldkey $name\n";
		    }
		    else
		    {
			$result .= "500 $newkey $oldkey $name\n";
			$ok = 0;
		    }
		}
		my $resp = HTTP::Response->new
		    ($ok ? 200 : 500,
		     $ok ? "OK" : "Error",
		     [], $result);
		$c->send_response ($resp);
	    }
	    else
	    {
		my $resp = HTTP::Response->new
		    (501, "Not implemented",
		     [], "Not implemented.\n");
		$c->send_response ($resp);
	    }
	    last if $kill;
	}
	$c->close;
	last if $kill;
    }
}

sub _callback_manifest
{
    my $self = shift;
    if ($self->{sth_finished})
    {
	return undef;
    }
    elsif (my @row = $self->{sth}->fetchrow_array)
    {
	my $data = "@row\n";
	$self->{md5_ctx}->add ($data);
	return $data;
    }
    else
    {
	$self->{sth_finished} = 1;
	return $self->{md5_ctx}->hexdigest . "\n";
    }
}

1;
