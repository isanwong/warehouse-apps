#!/usr/bin/perl

use strict;
use DBI;
use Warehouse;

my $Qrevision = escapeHTML($q->param('revision'));
my $Qmrfunction = escapeHTML($q->param('mrfunction'));
my $Qnodelist = escapeHTML($q->param('nodelist'));
print qq{
<html>
<head>
<title>mapreduce jobs / new</title>
</head>
<body>
<h2><a href="mrindex.cgi">mapreduce jobs</a> / new (2)</h2>

<form method=get action="mrnew3.cgi">
<input type=hidden name=revision value="$Qrevision">
Revision: $Qrevision<br>
<input type=hidden name=mrfunction value="$Qmrfunction">
Map/reduce function: $Qmrfunction<br>
<input type=hidden name=nodelist value="$Qnodelist">
Nodes: $Qnodelist<br>
Input manifest:<br>
};

my $whc = new Warehouse;

my @manifest = $whc->list_manifests or htmlcroak ($whc->errstr);

print q{<select multiple name=key size=16 style="font-family: monospace;">};

foreach (@manifest)
{
  my ($key, $name) = @$_;
  next if !$key;
  print "<option value=\"".escapeHTML($key."=".$name)."\">$key $name</option>\n";
}
print q{
</select>
<br>
<input type=submit value="Next">
</form>
</table>
</body>
</html>
};

sub htmlcroak
{
  print "<h1>error</h1>".join("<P>",map { escapeHTML($_) } @_);
  exit 0;
}
