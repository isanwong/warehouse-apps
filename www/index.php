<?php

require_once '/etc/polony-tools/config.php';
require_once 'functions.php';
require_once 'connect.php';

echo "<h1>".trim(`hostname`)."</h1>\n";

echo "<table border=0>\n";
echo "<tr>
  <td valign=bottom>dataset</td>
  <td valign=bottom align=right>reports</td>
  <td valign=bottom align=right>frames</td>
  <td valign=bottom align=right>complete<br>cycles</td>
  <td valign=bottom align=right>imagesets</td>
  <td valign=bottom align=right>#files</td>
  <td valign=bottom align=right>#bytes</td>
</tr>
";

$totalbytes = 0;
$q = mysql_query("select dataset.*, count(report.rid) as nreports from dataset
 left outer join report on report.dsid=dataset.dsid
 group by dataset.dsid
 order by dataset.dsid");
while ($dataset = mysql_fetch_assoc ($q))
{
  $dsid = $dataset[dsid];
  $ccomplete = mysql_one_value("select
   count(*) from cycle
   where dsid='$dsid'
   and nfiles=4*'$dataset[nframes]'");
  $cyclesum = mysql_one_assoc("select
   count(*) ncycles,
   sum(nfiles) nfiles,
   sum(nbytes) nbytes
   from cycle
   where dsid='$dsid'");
  echo "<tr><td><a href=\"dataset.php?dsid=$dsid\">$dsid</a></td>"
    ."<td align=right>".($dataset[nreports]?$dataset[nreports]:"")."</td>"
    ."<td align=right>".$dataset[nframes]."</td>"
    ."<td align=right>".$ccomplete."</td>"
    ."<td align=right>".addcommas($cyclesum[ncycles])."</td>"
    ."<td align=right>".addcommas($cyclesum[nfiles])."</td>"
    ."<td align=right>".addcommas($cyclesum[nbytes])."</td>"
    ."</tr>\n";
  $totalbytes += $cyclesum[nbytes];
}
echo "<tr><td/><td/><td/><td/><td/><td/><td>".addcommas($totalbytes)."</td></tr>\n";
echo "</table>\n";

echo "<p><a href=\"datasetcopy.php\">Copy datasets to other clusters...</a>\n";

?>

<iframe src="installrevision.php" width=800 height=300></iframe>

<pre><?=htmlspecialchars(`mogadm check`)?></pre>
