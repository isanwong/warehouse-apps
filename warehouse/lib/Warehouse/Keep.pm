# -*- mode: perl; perl-indent-level: 4; -*-

package Warehouse::Keep;

use HTTP::Daemon;
use HTTP::Response;
use Digest::MD5;
use Warehouse;
use Fcntl;

=head1 NAME

Warehouse::Keep -- Long term storage daemon.  Two supported actions:
(1) PUT /md5 --> store data with specified md5
(2) GET /md5 --> retrieve data
(3) DELETE /md5 --> delete data (yet unimplemented; only controller can do it)

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

 use Warehouse::Keep;

 my $daemon = Warehouse::Keep->new;
 $daemon->run;

=head1 METHODS

=head2 new

 my $daemon = Warehouse::Keep->new( %OPTIONS );

Creates a new server.  Returns the new object on success.  Dies on
failure.

=head3 Options

=over

=item Directories

Reference to an array of directories where files may be stored.  For
example:

  [ "/sda3/keep",
    "/sdb3/keep",
    "/sdc1/keep" ]

=item ListenAddress

IP address to listen on.  Default is "0.0.0.0".

=item ListenPort

Port number to listen on.  Default is 25107.

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
    my Warehouse::Keep $self = shift;
    
    ref $self->{Directories} eq "ARRAY" or die "No Directories specified";

    $self->{ListenAddress} = "0.0.0.0"
	if !defined $self->{ListenAddress};

    $self->{ListenPort} = "25107"
	if !defined $self->{ListenPort};

    $self->{Reuse} = 1
	if !defined $self->{Reuse};

    $self->{daemon} = new HTTP::Daemon
	( LocalAddr => $self->{ListenAddress},
	  LocalPort => $self->{ListenPort},
	  Reuse => $self->{Reuse} );

    $self->{daemon} or die "HTTP::Daemon::new failed: $!";

    $self->{whc} = new Warehouse;

    return $self;
}



=head2 url

  my $url = $daemon->url;

Returns the base url of the server (eg. http://1.2.3.4:25107/).

=cut


sub url
{
    my $self = shift;
    return $self->{daemon}->url;
}


=head2 run

  $daemon->run;

Listens for connections, and handles requests from clients.

=cut


my $kill = 0;

sub run
{
    my $self = shift;
    local $SIG{INT} = sub { $Warehouse::Keep::kill = 1; };
    local $SIG{TERM} = sub { $Warehouse::Keep::kill = 1; };
    local $| = 1;
    while (my $c = $self->{daemon}->accept)
    {
	while (my $r = $c->get_request)
	{
	    print(scalar (localtime) .
		  " " . $c->peerhost() .
		  " R" .
		  " " . $r->method .
		  " " . (map { s/[^\/\w_]/_/g; $_; } ($r->url->path_query))[0] .
		  "\n");

	    if ($r->method eq "GET")
	    {
		my ($md5) = $r->url->path =~ /^\/([0-9a-f]{32})$/;
		if (!$md5)
		{
		    $c->send_response (HTTP::Response->new
				       (400, "Bad request",
					[], "Bad request\n"));
		    last;
		}
		my $dataref = $self->_fetch ($md5);
		if (!$dataref)
		{
		    $c->send_response (HTTP::Response->new
				       (404, "Not found", [], "Not found\n"));
		    last;
		}
		$c->send_response (HTTP::Response->new
				   (200, "OK", [], $$dataref));
	    }
	    elsif ($r->method eq "PUT")
	    {
		my ($md5) = $r->url->path =~ /^\/([0-9a-f]{32})$/;
		if (!$md5)
		{
		    $c->send_response (HTTP::Response->new
				       (400, "Bad request",
					[], "Bad request\n"));
		    last;
		}

		# XXX verify signature here XXX
		$r->content =~ /(-----BEGIN PGP SIGNED MESSAGE-----\n.*?\n\n(.*?)\n-----BEGIN PGP SIGNATURE.*?-----END PGP SIGNATURE-----\n)(.*)$/s;
		my $signedmessage = $1;
		my $plainmessage = $2;
		my $newdata = $3;

		if ($newdata eq "")
		{
		    if (!$self->{whc})
		    {
			$c->send_response (HTTP::Response->new
					   (500, "No client object",
					    [], "No client object\n"));
			next;
		    }
		    if (!defined ($newdata = $self->{whc}->fetch_block ($md5)))
		    {
			$c->send_response (HTTP::Response->new
					   (404, "Data not found in cache",
					    [], "Data not found in cache\n"));
			next;
		    }
		}

		my $verified = $plainmessage =~ /\S/;
		my ($checktime, $checkmd5) = split (/ /, $plainmessage, 2);
		$checktime += 0;
		if (!$verified ||
		    time - $checktime > 300 ||
		    time - $checktime < -300 ||
		    $checkmd5 ne $md5)
		{
		    my $resp = HTTP::Response->new
			(401, "SigFail",
			 [], "Signature verification failed.\n");
		    $c->send_response ($resp);
		    last;
		}

		my $dataref = $self->_fetch ($md5);
		if ($dataref && $$dataref eq $newdata)
		{
		    $c->send_response (HTTP::Response->new
				       (200, "OK",
					[], "$md5\n"));
		    next;
		}

		if ($dataref)
		{
		    $c->send_response (HTTP::Response->new
				       (400, "Collision",
					[], "$md5\n"));
		    next;
		}

		my $metadata = "remote_addr=".$c->peerhost()."\n"
		    . "time=".$checktime."\n"
		    . "\n"
		    . "$signedmessage";

		if (!$self->_store ($md5, \$newdata, \$metadata))
		{
		    $c->send_response (HTTP::Response->new
				       (500, "Fail",
					[], $self->{errstr}));
		    next;
		}
		$c->send_response (HTTP::Response->new
				   (200, "OK",
				    [], "$md5\n"));
	    }
	    else
	    {
		$c->send_response (HTTP::Response->new
				   (501, "Not implemented",
				    [], "Not implemented.\n"));
	    }
	    last if $kill;
	}
	$c->close;
	last if $kill;
    }
    warn "Stopping";
}


sub _fetch
{
    my $self = shift;
    my $md5 = shift;
    my $dirs = $self->{Directories};
    for my $dir (@$dirs)
    {
	sysopen (F, "$dir/$md5", O_RDONLY) or next;
	local $/ = undef;
	my $data = <F>;
	close F;
	return \$data;
    }
    $self->{errstr} = "Not found: $md5";
    return undef;
}


sub _store
{
    my $self = shift;
    my $md5 = shift;
    my $dataref = shift;
    my $metaref = shift;
    my @errstr;
    my $errstr;
    my $dirs = $self->{Directories};
    for (0..$#$dirs)
    {
	my $dir = $dirs->[0];
	if (!sysopen (F, "$dir/$md5", O_WRONLY|O_CREAT|O_EXCL))
	{
	    $errstr = "can't create $dir/$md5: $!";
	    next;
	}
	if (!print F $$dataref)
	{
	    $errstr = "can't write $dir/$md5: $!";
	    close F;
	    unlink "$dir/$md5";
	    next;
	}
	if (!close F)
	{
	    $errstr = "error closing $dir/$md5: $!";
	    unlink "$dir/$md5";
	    next;
	}
	if (sysopen (M, "$dir/$md5.meta", O_RDWR|O_CREAT))
	{
	    sysseek (M, 0, 2);
	    print M $$metaref;
	    close M;
	}
	return $md5;
    }
    continue
    {
	push @errstr, $errstr;
	push @$dirs, shift @$dirs;
    }
    $self->{errstr} = join (", ", @errstr);
    return undef;
}

1;
