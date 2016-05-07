#!/usr/bin/perl
use strict;

use threads;
use threads::shared;

use IO::Socket::INET;
use Data::Dumper;
use File::Basename;

my $ledLabel   : shared = "LED is turned off";
my $ledFreq    : shared = 10;
my @ledHistory : shared;
my $startTime  : shared = time;
my $pattern    : shared = "50_50";
my $userFname  : shared;
my $userLname  : shared;
my $userAge    : shared;
my $userGender : shared;
my $userNotifs : shared;


# auto-flush on socket
$| = 1;
 
# creating a listening socket
my $server = new IO::Socket::INET (
    LocalHost => '0.0.0.0',
    LocalPort => '7777',
    Proto => 'tcp',
    Listen => 25,
    Reuse => 1
);
die "cannot create socket $!\n" unless $server;
print "server waiting for client connection on port 7777\n";
 

my @webmethods = (
  [ "menu", \&getMenu ],
  [ "pins", \&getPins ],
  [ "system/info", \&getSystemInfo ],
  [ "wifi/info", \&getWifiInfo ],
);
 
my $client;

while ($client = $server->accept())
{
   threads->create( sub {
       $client->autoflush(1);    # Always a good idea 
       close $server;
       
       my $httpReq = parse_http( $client );
       #print Dumper($httpReq);
       my $httpResp = process_http( $httpReq );
       #print Dumper($httpResp);

       my $data = "HTTP/1.1 " . $httpResp->{code} . " " . $httpResp->{text} . "\r\n";
       
       if( exists $httpResp->{fields} )
       {
         for my $key( keys %{$httpResp->{fields}} )
         {
           $data .= "$key: " . $httpResp->{fields}{$key} . "\r\n";
         }
       }
       $data .= "\r\n";
       if( exists $httpResp->{body} )
       {
         $data .= $httpResp->{body};
       }
 
       $client->send($data);
 
       if( $httpResp->{done} )
       {
         # notify client that response has been sent
         shutdown($client, 1);
       }
   } );
   close $client;        # Only meaningful in the client 
}

exit(0);

sub parse_http
{
  my ($client) = @_;
    # read up to 1024 characters from the connected client
    my $data = "";
    
    do{
      my $buf = "";
      $client->recv($buf, 1024);
      $data .= $buf;
    }while( $data !~ /\r\n\r\n/s );
 
    my %resp;
    
    my @lines = split /\r\n/, $data;
    my $head = shift @lines;
    
    if( $head =~ /(GET|POST) / )
    {
      $resp{method} = $1;
      $head =~ s/(GET|POST) //;
      if( $head =~ /^([^ ]+) HTTP\/\d\.\d/ )
      {
        my $args = $1;
        my $u = $args;
        $u =~ s/\?.*$//g;
        $args =~ s/^.*\?//g;
        my %arg = split /[=\&]/, $args;
        $resp{urlArgs} = \%arg;
        $resp{url} = $u;
        
        my %fields;
        while( my $arg = shift @lines )
        {
          if( $arg =~ /^([\w-]+): (.*)$/ )
          {
            $fields{$1} = $2;
          }
        }
        $resp{fields} = \%fields;
      }
      else
      {
        $resp{method} = 'ERROR';
        $resp{error} = 'Invalid HTTP request';
      }
      
      if( $resp{method} eq 'POST' )
      {
        my $remaining = join("\r\n", @lines);
        my $cnt_len = $resp{fields}{'Content-Length'};
     
        while( length($remaining) < $cnt_len )
        {
          my $buf = "";
          $client->recv($buf, 1024);
          $remaining .= $buf;
        }
        
        $resp{postData} = $remaining;
        my %pargs = split /[=\&]/, $remaining;
        $resp{postArgs} = \%pargs;
      }
    }
    else
    {
      $resp{method} = 'ERROR';
      $resp{error} = 'Invalid HTTP request';
    }
    
    return \%resp;
}

sub simple_response
{
  my ($code, $msg) = @_;

  my %resp;
  $resp{code} = $code;
  $resp{text} = $msg;
  $resp{fields} = {};
  $resp{done} = 1;
  
  return \%resp;
}

sub slurp
{
  my ($file) = @_;
  
  open IF, "<", $file or die "Can't read file: $!";
  my @fc = <IF>;
  close(IF);
  my $cnt = join("", @fc);
  return $cnt;
}

sub content_response
{
  my ($content, $url) = @_;
  
  my %resp;
  $resp{code} = 200;
  $resp{text} = "OK";
  $resp{done} = 1;
  $resp{body} = $content;
      
  $resp{fields} = {};
  $resp{fields}{'Content-Length'} = length($content);
      
  $resp{fields}{'Content-Type'} = "text/json";
  $resp{fields}{'Content-Type'} = "text/html; charset=UTF-8" if( $url =~ /\.html$/ );
  $resp{fields}{'Content-Type'} = "text/css" if( $url =~ /\.css$/ );
  $resp{fields}{'Content-Type'} = "text/javascript" if( $url =~ /\.js$/ );
  $resp{fields}{'Content-Type'} = "image/gif" if( $url =~ /\.ico$/ );
  $resp{fields}{'Connection'} = 'close';
      
  return \%resp;
}

sub process_http
{
  my ($httpReq) = @_;
  if( $httpReq->{method} eq 'ERROR' )
  {
    return simple_response(400, $httpReq->{error});
  }
  
  if( $httpReq->{url} =~ /\.json$/ )
  {
    my $url = $httpReq->{url};
    $url =~ s/\.json$//;
    my $pth = dirname $0;
    
    if( -f "$pth/web-server/$url" )
    {
      return process_user_comm($httpReq);
    }
  }
  
  if( $httpReq->{method} eq 'GET' )
  {
    my $url = $httpReq->{url};
    $url =~ s/^\///;
    
    $url = "home.html" if ! $url;

    my $pth = dirname $0;
    
    if( -f "$pth/../html/$url" )
    {
      my $cnt = slurp( "$pth/../html/$url" );
      
      if( $url =~ /\.html$/ )
      {
        my $prep = slurp( "$pth/../html/head-" );
        $cnt = "$prep$cnt";
      }
      return content_response($cnt, $url); 
    }
    if( -f "$pth/web-server/$url" )
    {
      my $cnt = slurp( "$pth/web-server/$url" );
      
      if( $url =~ /\.html$/ )
      {
        my $prep = slurp( "$pth/head-user-" );
        $cnt = "$prep$cnt";
      }
      return content_response($cnt, $url); 
    }
    elsif( grep { $_->[0] eq $url } @webmethods )
    {
      my @mth = grep { $_->[0] eq $url } @webmethods;
      my $webm = $mth[0];
      
      return content_response( $webm->[1]->(), $url );
    }
    else
    {
      return simple_response(404, "File not found");
    }
  }
  
  return simple_response(400, "Invalid HTTP request");
}

sub getMenu
{
  my $out = sprintf(
    "{ " .
      "\"menu\": [ " .
        "\"Home\", \"/home.html\", " .
        "\"WiFi Station\", \"/wifi/wifiSta.html\", " .
        "\"WiFi Soft-AP\", \"/wifi/wifiAp.html\", " .
        "\"&#xb5;C Console\", \"/console.html\", " .
        "\"Services\", \"/services.html\", " .
#ifdef MQTT
        "\"REST/MQTT\", \"/mqtt.html\", " .
#endif
        "\"Debug log\", \"/log.html\", " .
        "\"Web Server\", \"/web-server.html\"" .
	"%s" .
      " ], " .
      "\"version\": \"%s\", " .
      "\"name\": \"%s\"" .
    " }", readUserPages(), "dummy", "dummy-esp-link");

  return $out;
}

sub getPins
{
  return '{ "reset":12, "isp":-1, "conn":-1, "ser":2, "swap":0, "rxpup":1 }';
}

sub getSystemInfo
{
  return '{ "name": "esp-link-dummy", "reset cause": "6=external", "size": "4MB:512/512", "upload-size": "3145728", "id": "0xE0 0x4016", "partition": "user2.bin", "slip": "disabled", "mqtt": "disabled/disconnected", "baud": "57600", "description": "" }';
}

sub getWifiInfo
{
  return '{"mode": "STA", "modechange": "yes", "ssid": "DummySSID", "status": "got IP address", "phy": "11n", "rssi": "-45dB", "warn": "Switch to <a href=\"#\" onclick=\"changeWifiMode(3)\">STA+AP mode</a>",  "apwarn": "Switch to <a href=\"#\" onclick=\"changeWifiMode(3)\">STA+AP mode</a>", "mac":"12:34:56:78:9a:bc", "chan":"11", "apssid": "ESP_012345", "appass": "", "apchan": "11", "apmaxc": "4", "aphidd": "disabled", "apbeac": "100", "apauth": "OPEN","apmac":"12:34:56:78:9a:bc", "ip": "192.168.1.2", "netmask": "255.255.255.0", "gateway": "192.168.1.1", "hostname": "esp-link", "staticip": "0.0.0.0", "dhcp": "on"}';
}

sub read_dir_structure
{
  my ($dir, $base) = @_;

  my @files;
  
  opendir my $dh, $dir or die "Could not open '$dir' for reading: $!\n";

  while (my $file = readdir $dh) {
    if ($file eq '.' or $file eq '..') {
      next;
    }

    my $path = "$dir/$file";
    if( -d "$path" )
    {
      my @sd = read_dir_structure($path, "$base/$file");
      push @files, @sd ;
    }
    else
    {
      push @files, "$base/$file";
    }
  }

  close( $dh );
  
  $_ =~ s/^\/// for(@files);
  return @files;
}

sub readUserPages
{
  my $pth = dirname $0;
  my @files = read_dir_structure( "$pth/web-server", "/" );
  
  @files = grep { $_ =~ /\.html$/ } @files;
  
  my $add = '';
  for my $f ( @files )
  {
    my $nam = $f;
    $nam =~ s/\.html$//;
    $nam =~ s/[^\/]*\///g;
    $add .= ", \"$nam\", \"$f\"";
  }
  
  return $add;
}

sub jsonString
{
  my ($text) = @_;
  return 'null' if ! defined $text;
  return "\"$text\"";
}

sub jsonNumber
{
  my ($num) = @_;
  return 'null' if ! defined $num;
  return $num + 0;
}

sub led_add_history
{
  my ($msg) = @_;
  pop @ledHistory if @ledHistory >= 10;
  
  my $elapsed = time - $startTime;
  my $secs = $elapsed % 60;
  my $mins = int($elapsed / 60) % 60;
  my $hours = int($elapsed / 3600) % 24;
  
  $secs = "0$secs" if length($secs) == 1;
  $mins = "0$mins" if length($mins) == 1;
  $hours = "0$hours" if length($hours) == 1;
  
  $msg = "$hours:$mins:$secs $msg";
  unshift @ledHistory, $msg;
}

sub process_user_comm_led
{
  my ($http) = @_;
  my $loadData = '';

  if( $http->{urlArgs}{reason} eq "button" )
  {
    my $btn = $http->{urlArgs}{id};
    
    if($btn eq "btn_on" )
    {
      $ledLabel = "LED is turned on";
      led_add_history("Set LED on");
    }
    elsif($btn eq "btn_blink" )
    {
      $ledLabel = "LED is blinking";
      led_add_history("Set LED blinking");
    }
    elsif($btn eq "btn_off" )
    {
      $ledLabel = "LED is turned off";
      led_add_history("Set LED off");
    }
  }
  elsif( $http->{urlArgs}{reason} eq "submit" )
  {
    if( exists $http->{postArgs}{frequency} )
    {
      $ledFreq = $http->{postArgs}{frequency};
      led_add_history("Set frequency to $ledFreq Hz");
    }
    if( exists $http->{postArgs}{pattern} )
    {
      $pattern = $http->{postArgs}{pattern};
      my $out = $pattern;
      $out =~ s/_/\% - /;
      $out .= "%";
      led_add_history("Set pattern to $out");
    }
    return simple_response(204, "OK");
  }
  elsif( $http->{urlArgs}{reason} eq "load" )
  {
    $loadData = ', "frequency": ' . $ledFreq . ', "pattern": "' . $pattern . '"'; 
  }

  my $list = ", \"led_history\": [" . join(", ", map { "\"$_\"" } @ledHistory ) . "]";
  my $r = '{"text": "' . $ledLabel . '"' . $list . $loadData . '}';
  return content_response($r, $http->{url});
}

sub process_user_comm_voltage
{
  my ($http) = @_;

  my $voltage = (((time - $startTime) % 60) - 30) / 30.0 + 4.0;
  $voltage = sprintf("%.2f V", $voltage);
  
  my $table = ', "table": [["Time", "Min", "AVG", "Max"], ["0s-10s", "1 V", "3 V", "5 V"], ["10s-20s", "1 V", "2 V", "3 V"]]';
  my $r = '{"voltage": "' . $voltage . '"' . $table . '}';
  return content_response($r, $http->{url});
}

sub process_user_comm_user
{
  my ($http) = @_;

  
  if( $http->{urlArgs}{reason} eq "submit" )
  {
    if( exists $http->{postArgs}{last_name} )
    {
      $userLname = $http->{postArgs}{last_name};
    }
    if( exists $http->{postArgs}{first_name} )
    {
      $userFname = $http->{postArgs}{first_name};
    }
    if( exists $http->{postArgs}{age} )
    {
      $userAge = $http->{postArgs}{age};
    }
    if( exists $http->{postArgs}{gender} )
    {
      $userGender = $http->{postArgs}{gender};
    }
    if( exists $http->{postArgs}{notifications} )
    {
      $userNotifs = $http->{postArgs}{notifications};
    }
    return simple_response(204, "OK");
  }
  elsif( $http->{urlArgs}{reason} eq "load" )
  {
    my $r = '{"last_name": '    . jsonString($userLname) .
           ', "first_name": '   . jsonString($userFname) .
           ', "age": '          . jsonNumber($userAge) .
           ', "gender": '       . jsonString($userGender) .
           ', "notifications":' . jsonString($userNotifs) . '}';
           
    return content_response($r, $http->{url});
  }
  
  return content_response("{}", $http->{url});
}

sub process_user_comm()
{
  my ($http) = @_;

  if( $http->{url} eq '/LED.html.json' )
  {
    return process_user_comm_led($http);
  }

  if( $http->{url} eq '/Voltage.html.json' )
  {
    return process_user_comm_voltage($http);
  }

  if( $http->{url} eq '/User.html.json' )
  {
    return process_user_comm_user($http);
  }
}
