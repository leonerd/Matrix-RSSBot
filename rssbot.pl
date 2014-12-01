#!/usr/bin/perl

use strict;
use warnings;

use XML::RSS;

use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Net::Async::HTTP;

use DBI;

STDOUT->binmode( ":encoding(UTF-8)" );

my $loop = IO::Async::Loop->new;

$loop->add( my $rss_ua = Net::Async::HTTP->new );

my $dbh = DBI->connect( "dbi:SQLite:dbname=rssbot.db", "", "" )
   or die DBI->errstr;

my $select_feeds = $dbh->prepare( "SELECT url FROM feeds" );
my $update_feed  = $dbh->prepare( "UPDATE feeds SET title = ? WHERE url = ?" );

my $select_item_by_guid = $dbh->prepare( "SELECT guid FROM items WHERE guid = ?" );
my $insert_item         = $dbh->prepare( "INSERT INTO items ( guid ) VALUES ( ? )" );

$loop->add( IO::Async::Timer::Periodic->new(
   first_interval => 0,
   interval => 10*60,
   on_tick => \&fetch_feeds,
)->start );

$loop->run;


sub fetch_feeds
{
   $select_feeds->execute();

   my @f;

   while( my $row = $select_feeds->fetchrow_hashref ) {
      my $url = $row->{url};

      print STDERR "Fetching $url\n";

      push @f, $rss_ua->GET( $url )->then( sub {
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

            new_rss_item( $item, $channel );

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
   }

   $select_feeds->finish;

   $rss_ua->adopt_future( Future->needs_all( @f ) );
}

sub new_rss_item
{
   my ( $item, $channel ) = @_;

   print "New RSS item $item->{title} on channel $channel->{title}\n";
}
