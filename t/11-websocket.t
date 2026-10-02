#!/usr/bin/env perl

use v5.38;
use Test::More;
use Future::AsyncAwait;
use JSON::PP qw(decode_json);
use PAGI::FastAPI;
use PAGI::Test::ConnectionState;

my $app = PAGI::FastAPI->new(title => 'WebSocket Test App');

# Simple echo WebSocket endpoint
$app->websocket('/ws/echo',
    handler => async sub ($ws, $deps) {
        await $ws->accept;

        while (my $msg = await $ws->receive_text) {
            await $ws->send_text("Echo: $msg");
        }
    }
);

# WebSocket endpoint with path params, JSON messaging, and explicit close
$app->websocket('/ws/chat/{room}',
    handler => async sub ($ws, $deps) {
        my $room = $ws->path_params->{room};
        await $ws->accept;

        my $data = await $ws->receive_json;
        if ($data->{action} eq 'ping') {
            await $ws->send_json({ room => $room, status => 'pong' });
        }

        await $ws->close(1000, "Done");
    }
);

my $pagi_app = $app->to_app;

# A hand-built websocket scope needs the pagi.connection object a PAGI Www
# 0.6 server provides; a peer disconnect is recorded on it before the
# application sees the event, as a server does.
sub ws_scope ($path) {
    my $conn = PAGI::Test::ConnectionState->new(websocket => 1);
    my $scope = {
        type              => 'websocket',
        path              => $path,
        query_string      => '',
        headers           => [],
        'pagi.connection' => $conn,
    };
    my $peer_closed = sub ($event) {
        if ($event->{type} eq 'websocket.disconnect') {
            $conn->_set_peer_close($event->{code} // 1005, $event->{reason} // '');
            $conn->_mark_complete;
        }
        return $event;
    };
    return ($scope, $peer_closed);
}

subtest 'Valid WebSocket Handshake and Echo Flow' => sub {
    my ($scope, $peer_closed) = ws_scope('/ws/echo');

    # Queue of incoming client events
    my @incoming_events = (
        { type => 'websocket.receive', text => 'Hello Perl' },
        { type => 'websocket.disconnect', code => 1000 },
    );

    my @sent_events;

    my $receive = async sub {
        return $peer_closed->(shift @incoming_events);
    };

    my $send = async sub ($event) {
        push @sent_events, $event;
    };

    # Resolve async execution with ->get
    $pagi_app->($scope, $receive, $send)->get;

    is scalar(@sent_events), 2, 'Received two outgoing events';
    is $sent_events[0]->{type}, 'websocket.accept', 'First event was websocket.accept';
    is $sent_events[1]->{type}, 'websocket.send', 'Second event was websocket.send';
    is $sent_events[1]->{text}, 'Echo: Hello Perl', 'Echo text payload is correct';
};

subtest 'WebSocket Route with Path Params, JSON Payload, and Handshake Close' => sub {
    my ($scope, $peer_closed) = ws_scope('/ws/chat/lobby');

    my @incoming_events = (
        { type => 'websocket.receive', text => '{"action":"ping"}' },
    );

    my @sent_events;

    my $receive = async sub {
        return $peer_closed->(shift @incoming_events // { type => 'websocket.disconnect', code => 1000 });
    };

    my $send = async sub ($event) {
        push @sent_events, $event;
    };

    $pagi_app->($scope, $receive, $send)->get;

    is scalar(@sent_events), 3, 'Received accept, json message, and close events';
    is $sent_events[0]->{type}, 'websocket.accept', 'Handshake accepted';

    is $sent_events[1]->{type}, 'websocket.send', 'JSON message event sent';
    my $data = decode_json($sent_events[1]->{text});
    is $data->{room}, 'lobby', 'Path parameter accessible in WebSocket handler';
    is $data->{status}, 'pong', 'JSON response payload is correct';

    is $sent_events[2]->{type}, 'websocket.close', 'Connection closed cleanly';
    is $sent_events[2]->{code}, 1000, 'Close code 1000 sent';
};

subtest 'Non-existent route refuses the handshake with HTTP 404' => sub {
    my ($scope, $peer_closed) = ws_scope('/ws/nonexistent');

    my @sent_events;

    my $receive = async sub { return { type => 'websocket.connect' } };
    my $send    = async sub ($event) {
        push @sent_events, $event;
    };

    $pagi_app->($scope, $receive, $send)->get;

    # PAGI Www 0.6: before accept the connection is still an HTTP exchange,
    # so it is refused with an HTTP response; websocket.close is not allowed.
    is $sent_events[0]->{type}, 'http.response.start', 'Handshake refused with an HTTP response';
    is $sent_events[0]->{status}, 404, 'Status 404 Not Found';
    ok !(grep { $_->{type} eq 'websocket.close' } @sent_events), 'No websocket.close before accept';
};

done_testing;
