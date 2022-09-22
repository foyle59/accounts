#!/usr/bin/perl

#use Tie::IxHash;
use DBI;

$dbname  = "billing";
$dbuser  = "billing";
$dbpass  = "xxxxx";
$dbhost  = "aaa.bbb.ccc.ddd";
$raddb   = "radius";
$raduser = "radius";
$radpass = "xxxxxx";

$dbh = '';
#tie %rejected, "Tie::IxHash";
#tie %remained, "Tie::IxHash";
#tie %customerid, "Tie::IxHash";
@string = ();
%usernew = ();
%userold = ();
$tarif = 'Отключен'

($sec,$min,$hour,$day,$month,$year, $trash) = localtime(time);
$year += 1900;
$month++;

$addr = $id = $trash = '';
$first = $sec = $third = $lastbyte = '';
#$dbh = DBI->connect("dbi:Pg:dbname=$dbname;host=$dbhost", $dbuser, $dbpass, {AutoCommit => 0});
$dbh = DBI->connect("dbi:Pg:dbname=$dbname", $dbuser, $dbpass, {AutoCommit => 0});
# add IPs to firewall who has not money on their account
#$sth = $dbh->prepare("SELECT ipaddr FROM ipaddress a, report3_view b, plan c, client1 d
#  WHERE a.id=b.code AND b.plan=c.name AND a.id=d.code 
#  AND (b.account + d.credit < -0.05*c.monthly OR c.id=127) AND b.mustcheck");
#$sth->execute();
#$dbh->commit or die $dbh->errstr;
#system("/usr/local/sbin/ipset -F debt");
#while (@row = $sth->fetchrow_array) {
#  system("/usr/local/sbin/ipset -A debt $row[0]");
#}

# если у клиента нет денег, присвоить ему тариф "Отключен", таким образом уйти от эскалации задолженности
# in case a customer has no money assign a plan 'uncheck' to him to prevent a debt escalation
$rv = $dbh->do("UPDATE client1 SET plan='Отключен' WHERE code IN (SELECT a.code
  FROM report3_view a, client1 b, plan c, acc d
  WHERE a.code=b.code AND a.plan=c.name AND a.mustcheck AND b.plan <> 'Отключен'
  AND a.account + b.credit < -0.05*c.monthly
  AND dot=current_date AND d.id=a.code AND traf_rcd = 0)");
$dbh->commit or die $dbh->errstr;

# есть ли уже кто в newplans?
# does anybody changed his plan?
$sth = $dbh->prepare("SELECT id, plan FROM newplans");
$sth->execute();
$dbh->commit or die $dbh->errstr;
while (@row = $sth->fetchrow_array) {
  $plan{$row[0]} = $row[1];
}

# если клиент успел сегодня попользоваться интернетом (например, у него была синяя полоска, но он, повидла гадкая,
# так и не платит за услуги, и ему полоску сняли), то оставить на сегодня текущий тариф, 
# а новый ("Отключен") включить ему завтра
# in case a customer user service today (for example he had blue backgound but he still did not pay for service and his free access declined)
# then remain current plan for today and new one (Rejected) should be in action tomorrow
$sth = $dbh->prepare("SELECT a.code, a.plan FROM report3_view a, client1 b, plan c, acc d
  WHERE a.code=b.code AND a.plan=c.name AND a.mustcheck AND a.plan <> 'Отключен'
  AND a.account + b.credit < -0.05*c.monthly AND dot=current_date AND d.id=a.code AND traf_rcd > 0");
$sth->execute();
$dbh->commit or die $dbh->errstr;
while (@row = $sth->fetchrow_array) {
  if ($plan{$row[0]}) {
    next if ($plan{$row[0]} eq $tarif);
    $rv = $dbh->do("DELETE FROM newplans WHERE id=$row[0]");
    $dbh->commit or die $dbh->errstr;
  }
  $rv = $dbh->do("INSERT INTO newplans (id, plan,dot) 
    VALUES ($row[0], '$tarif', (current_date + '1 day'::interval)::date)");
  $dbh->commit or die $dbh->errstr;
}

# если у клиента уже есть деньги на счету, а у него план "Отключен", восстановить предыдущий план
# in case a customer paid for service but he had Rejected plan then to reestablish his previous plan
$sth = $dbh->prepare("SELECT a.id, a.plan FROM acc a,
  (SELECT id, max(dot) AS lastday FROM acc WHERE plan <> 'Отключен' AND id IN
  (SELECT code FROM report3_view WHERE plan = 'Отключен' AND account > 0 AND mustcheck)
  GROUP BY id) b WHERE a.id=b.id AND dot=lastday");
$sth->execute();
#print "tut\n";
$dbh->commit or die $dbh->errstr;
while (@row = $sth->fetchrow_array) {
#  print "$row[1] \t $row[0]\n";
  $rv = $dbh->do("UPDATE client1 SET plan='$row[1]' WHERE code=$row[0]");
  $dbh->commit or die $dbh->errstr;
}

# выбрать всех, кому можно в инет и кому нельзя - true, false - соответственно
# choose everybody who can use service
$sth = $dbh->prepare("SELECT login, CASE WHEN NOT a.mustcheck THEN true
  WHEN a.account+b.credit < -0.05*c.monthly OR c.id = 127 THEN false
  ELSE true END AS allowed FROM report3_view a, client1 b, plan c
  WHERE a.code=b.code AND a.plan=c.name");
$sth->execute();
$dbh->commit or die $dbh->errstr;
while (@row = $sth->fetchrow_array) {
  $usernew{$row[0]} = $row[1];
}
$dbh->disconnect;

# выбрать старые permissions для клиентов
# choosr old permissions for customers
$dbh = DBI->connect("dbi:Pg:dbname=$raddb", $raduser, $radpass, {AutoCommit => 0});
$sth = $dbh->prepare("SELECT username, allowed FROM usernas");
$sth->execute();
$dbh->commit or die $dbh->errstr;
while (@row = $sth->fetchrow_array) {
  $userold{$row[0]} = $row[1];
}

# сравнить старые и новые допуски и изменить, если они изменились
# compare old an new permissions and change in case they are changed
foreach $user (keys %usernew) {
  next if ($usernew{$user} eq $userold{$user});
#  print "$user\t $usernew{$user}\n";
  $rv = $dbh->do("UPDATE usernas SET allowed='$usernew{$user}' WHERE username='$user'");
  $dbh->commit or die $dbh->errstr;
}
