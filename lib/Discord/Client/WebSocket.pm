package Discord::Client::WebSocket;

use Discord::Constants::OPCodes;
use Discord::Constants::CloseCodes;
use Discord::Loader as => 'Role';
use Discord::Client::WebSocket::Session;
use Discord::Client::WebSocket::Session::User;
use Discord::Common::Throttler;
use JSON::XS qw(encode_json decode_json);
use Compress::Zlib;
use Mojo::UserAgent;
use Unicode::UTF8;

with 'Discord::Client::WebSocket::Events';
with 'Discord::Client::WebSocket::Events::Errors';

has 'seq'       => ( is => 'rw' );
has 'tx'        => ( is => 'rw' );
has 'session'   => ( is => 'rw' );
has 'throttle'  => (
    is => 'ro',
    default => sub {
        Discord::Common::Throttler->new(frequency => 1)
    }
);

method init_socket {
	# store the base name of the package using our library
	my $base = $self->base_name;

    $self->session(
        Discord::Client::WebSocket::Session->new(disc => $self)
    );

	# create the gateway URL, appending the api version and encoding type
	my $url = $self->gateway_url .
        '?v=' . $self->api_version . '&encoding=' . $self->encoding;

    my $ua = Mojo::UserAgent->new;

    #$ua->transactor->name('p5-Discord');
  	$ua->websocket($url => sub {
        my ($ua, $tx) = @_;

        # check to make sure we have a valid websocket
        # if not, run the cleanup event
        unless ($tx->is_websocket) {
            $self->on_cleanup;
            return;
        }

        # store the transaction object and send identify payload
        $self->tx($tx);

        # when the connection is closed
        $tx->on(finish => sub {
            my ($tx, $code, $reason) = @_;
            if($base->can('discord_error')) {
            		# Pipe the error code through handle_error,
            	  # returning a reason relevant to the error code
            		my $reason = $self->handle_error($code);
            		$base->discord_error($self, $code, $reason);
            }
            if (exists $self->_events->{disconnected}) {
          	    $self->_events->{disconnected}->($code, $reason);
            }

            $self->on_cleanup;
        });

        # this starts the main loop, checking for messages from the server
        $tx->on(message => sub {
            my ($tx, $json) = @_;
            my $message = eval { (Unicode::UTF8::valid_utf8($json)) ?
                $json : uncompress($json); };

            if ($message) {
                # decode the json from the server into a perl HASH
                $message = eval { decode_json(Unicode::UTF8::encode_utf8($message)) };

                # if the eval returns an error (invalid json) then
                # we don't want to try and handle the data
                unless ($@) {
                    # filter the message through the on_receive event
                    $self->on_receive($message);

                    # if the user has a discord_data method, then pass
                    # the discord object and decoded message to them
                    if ($base->can('discord_data')) {
                        $base->discord_data($self, $message->{d});
                    }

                    # handle all the events from discord
                    $self->handle_events($message);
                }
            }
        });
    });

	Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
}

method send_heartbeat {
	$self->heartbeat->{'check'}++;
	$self->_send({
    	op => Discord::Constants::OPCodes::HEARTBEAT,
    	d  => $self->seq,
    });

    say "<- Sent heartbeat" if $ENV{DISCORD_DEBUG};
}

method _send ($payload) {
	# convert the payload from a perl HASH to json string
	# then send it to the server
	 $self->throttle->apply(sub {
        my $enc_pay = encode_json($payload);
        $self->tx->send($enc_pay);
    });
}

method identify {
	say "<- Sent ident" if $ENV{DISCORD_DEBUG};
	$self->_send({
		op => Discord::Constants::OPCodes::IDENTIFY,
		d  => {
		    "token" => $self->token,
		    "properties" => {
		        '$os'				=> $^O,
		        '$browser'			=> "p5-Discord",
		        '$device'			=> "p5-Discord",
		        '$referrer'			=> "",
		        '$referring_domain'	=> ""
		    },
		    "compress" => \1,
		    "large_threshold" => 50,
		},
	});
}

1;
__END__
