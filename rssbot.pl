#!/usr/bin/perl

use strict;
use warnings;

use DBI;
use Future::Utils qw( fmap_void );
use Getopt::Long;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use IO::Socket::SSL qw(SSL_VERIFY_NONE);
use Net::Async::HTTP;
use Net::Async::Matrix;
use Net::Async::Matrix::Utils qw( build_formatted_message );
use String::Tagged;
use XML::RSS;
use YAML;

STDOUT->binmode( ":encoding(UTF-8)" );

my $loop = IO::Async::Loop->new;

ref $loop eq "IO::Async::Loop::Poll" and
   warn "Using SSL with IO::Poll causes known memory-leaks!!\n";

GetOptions(
   'C|config=s' => \my $CONFIG,
) or exit 1;

defined $CONFIG or die "Must supply --config\n";

my %CONFIG = %{ YAML::LoadFile( $CONFIG ) };

my %MATRIX_CONFIG = %{ $CONFIG{matrix} };
# No harm in always applying this
$MATRIX_CONFIG{SSL_verify_mode} = SSL_VERIFY_NONE;

my $matrix = Net::Async::Matrix->new(
   %MATRIX_CONFIG,
   on_error => sub {
      my ( undef, $failure, $name, @args ) = @_;
      print STDERR "Matrix failure: $failure\n";
      if( defined $name and $name eq "http" ) {
         my ($response, $request) = @args;
         print STDERR "HTTP failure details:\n" .
         "Requested URL: ${\$request->method} ${\$request->uri}\n" .
         "Response ${\$response->status_line}\n";
         print STDERR " | $_\n" for split m/\n/, $response->decoded_content;
      }
   },
);
$loop->add( $matrix );

$loop->add( my $rss_ua = Net::Async::HTTP->new );

my $dbh = DBI->connect( "dbi:SQLite:dbname=rssbot.db", "", "" )
   or die DBI->errstr;

my $select_feeds = $dbh->prepare( "SELECT url FROM feeds" );
my $update_feed  = $dbh->prepare( "UPDATE feeds SET title = ? WHERE url = ?" );

my $select_item_by_guid = $dbh->prepare( "SELECT guid FROM items WHERE guid = ?" );
my $insert_item         = $dbh->prepare( "INSERT INTO items ( guid ) VALUES ( ? )" );

my $select_rooms_by_feed = $dbh->prepare( "SELECT room FROM feed_room WHERE url = ?" );

$loop->add( my $timer = IO::Async::Timer::Periodic->new(
   first_interval => 0,
   interval => 10*60,
   on_tick => \&fetch_feeds,
) );

$matrix->login( %{ $CONFIG{"matrix-bot"} } )->then( sub {
   $matrix->start;
})->get;

print "Logged in to Matrix...\n";

$timer->start;

$loop->run;


sub fetch_feeds
{
   $select_feeds->execute();

   my $f = fmap_void {
      my ( $row ) = @_;
      my $url = $row->{url};

      print STDERR "Fetching $url\n";

      $rss_ua->GET( $url )->then( sub {
         my ( $response ) = @_;
         my $content = $response->decoded_content;

         # Matrix feed seems to have some nonprintables in it. Throw them out. Remember
         # not to throw out \x0a
         $content =~ s/[\x00-\x09\x0b-\x1f]//g;

         my $rss = XML::RSS->new->parse( $content );

         my $channel = $rss->{channel};

         $update_feed->execute( $channel->{title}, $url );
         $update_feed->finish;

         foreach my $item ( @{ $rss->{items} } ) {
            my $guid = $item->{guid};

            $select_item_by_guid->execute( $guid );
            next if $select_item_by_guid->fetchrow_hashref;

            new_rss_item( $item, $channel, $url );

            $insert_item->execute( $guid );
            $insert_item->finish;
         }

         $select_item_by_guid->finish;

         Future->done;
      })->else( sub {
         my ( $failure ) = @_;

         print STDERR "Feed $url failed: $failure\n";

         Future->done;
      });
   } generate => sub {
      my $row = $select_feeds->fetchrow_hashref;
      $row ? ( $row ) : (); # empty list on done
   },
     concurrent => 10;

   return $rss_ua->adopt_future(
      $f->on_done(
         sub { $select_feeds->finish }
      )
   );
}

sub new_rss_item
{
   my ( $item, $channel, $url ) = @_;

   print "New RSS item $item->{title} on channel $channel->{title}\n";

   my $message = String::Tagged->new
      ->append_tagged( $channel->{title}, i => 1 )
      ->append       ( " posted a new article: " )
      ->append       ( $item->{title} );

   $select_rooms_by_feed->execute( $url );
   while( my $row = $select_rooms_by_feed->fetchrow_hashref ) {
      my $roomname = $row->{room};

      my $f = $matrix->join_room( $roomname )->then( sub {
         my ( $room ) = @_;

         $room->send_message(
            type => "m.text",
            %{ build_formatted_message( $message ) },
         )
      });

      $matrix->adopt_future( $f );
   }
}
