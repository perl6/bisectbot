# Copyright © 2016-2017
#     Aleks-Daniel Jakimenko-Aleksejev <alex.jakimenko@gmail.com>
# Copyright © 2016
#     Daniel Green <ddgreen@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use File::Directory::Tree;
use IRC::Client::Message;
use IRC::Client;
use IRC::TextColor;
use JSON::Fast;
use Number::Denominate;
use Pastebin::Gist;
use Terminal::ANSIColor;
use Text::Diff::Sift4;

use Whateverable::Bits;
use Whateverable::Configurable;
use Whateverable::Config;
use Whateverable::Discordable;
use Whateverable::Heartbeat;
use Whateverable::Messages;
use Whateverable::Processing;

constant Message = IRC::Client::Message;

unit role Whateverable does IRC::Client::Plugin;

also does Helpful;
also does Whateverable::Configurable;
also does Whateverable::Discordable;

method TWEAK {
    # wrap around everything to catch exceptions
    once { # per class
        self.^lookup(‘irc-to-me’).wrap: sub ($self, $msg) {
            return if $msg.?channel and $msg.channel ne $CONFIG<cave>
                      and $msg.args[1].starts-with: ‘what:’;
            # ↑ ideally this check shouldn't be here, but it's much harder otherwise

            LEAVE sleep 0.02; # https://github.com/Raku/whateverable/issues/163
            try {
                my $result = callsame;
                return without $result;
                return $result but Reply($msg) if $result !~~ Promise;
                return start sub {
                    my $awaited = try await $result;
                    return handle-exception $_, $msg with $!;
                    return without $awaited;
                    return $awaited but Reply($msg);
                }()
            }
            handle-exception $!, $msg
        };

        self.^lookup(‘filter’).wrap: sub ($self, $response) {
            my &filter = nextcallee;
            try { return filter $self, $response }
            return ‘Ow! Where's a camcorder when ya need one?’ if $response ~~ Enough;
            try { return filter $self, handle-exception $!, $response.?msg }
            ‘Sorry kid, that's not my department.’
        };
    }
    # TODO roles should not have TWEAK method
}

#↓ STDIN reset
multi method irc-to-me(Message $msg where .text ~~
                       #↓ Matches only one space on purpose (for whitespace-only stdin)
                       /:i^ [stdin] [‘ ’|‘=’] [clear|delete|reset|unset] $/) {
    $CONFIG<stdin> = $CONFIG<default-stdin>;
    ‘STDIN is reset to the default value’
}
#↓ STDIN set
multi method irc-to-me(Message $msg where .text ~~ /:i^ [stdin] [‘ ’|‘=’] $<stdin>=.* $/) {
    my $file = process-code ~$<stdin>, $msg;
    $CONFIG<stdin> = $file.slurp;
    unlink $file;
    “STDIN is set to «{shorten $CONFIG<stdin>, 200}»” # TODO is 200 a good limit
}
#↓ Source
multi method irc-to-me(Message $    where .text ~~ /:i^ [source|url] ‘?’? \s* $/) { $CONFIG<source> }
#↓ Wiki
multi method irc-to-me(Message $    where .text ~~ /:i^ wiki ‘?’? \s* $/) { self.get-wiki-link }
#↓ Help
multi method irc-to-me(Message $msg where .text ~~ /:i^ [help|usage] ‘?’? \s* $/) {
    self.help($msg) ~ “ # See wiki for more examples: {self.get-wiki-link}”
}
#↓ Uptime
multi method irc-to-me(Message $msg where .text ~~ /:i^ uptime \s* $/) {
    use nqp;
    use Telemetry;
    (denominate now - $*INIT-INSTANT) ~ ‘, ’
    ~ T<max-rss>.fmt(‘%.2f’) ÷ 1024 ~ ‘MiB maxrss. ’
    ~ (with (nqp::getcomp("Raku") || nqp::getcomp("perl6")) {
        “This is {.implementation} version {.config<version>} ”
        ~ “built on {.backend.version_string} ”
        ~ “implementing {.language_name} {.language_version}.”
     })
}
#| Get the oldest commit DateTime for $*PROGRAM. Needs $*CWD to point to the whateverable git repository.
sub term:<birthday> {
    my $dates = run :out, ‘git’, ‘log’, ‘--follow’, ‘--date-order’, ‘--format=%aI’, $*PROGRAM.relative;
    try { $dates.out.lines(:close).tail.&{ DateTime.new($_) }.Date } \
        or fail ‘no birthday data available’
}
#| Proper answer to “how old are you?”
sub my-age is export {
    with birthday {
        “I was created on $_”
    }
    else {
        .exception.message
    }
}
#| Replying to age inquiry
multi method irc-to-me(Message $ where .text ~~ /:i^ [‘how old are you’|‘age’] /) {
    my-age
}
#| Replying to age inquiry
multi method irc-privmsg-channel($msg where .text ~~ /:i [‘how old are you’|‘age’] .* $($msg.server.current-nick) /) {
    my-age
}
#| You're welcome!
sub you're-welcome is export {
    «
    ‘You're welcome!’
    ‘I'm happy to help!’
    ‘Anytime!’
    ‘It's my pleasure!’
    ‘Thank you! You love me, you really love me!’
    ‘\o/’
    »
}
#| Replying to thanks
multi method irc-to-me(Message $msg where .text ~~ /:i^ [‘thank you’|‘thanks’] \s* /) {
    you're-welcome.pick
}
#| Replying to thanks
multi method irc-privmsg-channel($msg where .text ~~ /:i [‘thank you’|‘thanks’] .* $($msg.server.current-nick) /) {
    you're-welcome.pick
}
#↓ Notices
multi method irc-notice-me( $ --> Nil)                             {} # Issue #321
#↓ Private messages
method private-messages-allowed() { False }
multi method irc-privmsg-me($ where not $.private-messages-allowed) { # TODO issue #16
    ‘Sorry, it is too private here. You can join #whateverable channel instead’
}
#↓ Fallback
multi method irc-to-me($) {
    ‘I cannot recognize this command. See wiki for some examples: ’ ~ self.get-wiki-link
}
#↓ Notify watchdog on any event
multi method irc-all($) {
    # TODO https://github.com/zoffixznet/perl6-IRC-Client/issues/50
    I'm-alive;
    $.NEXT
}

method get-wiki-link { $CONFIG<wiki> ~ self.^name }

#↓ Gistable output
multi method filter($response where
                    (.encode.elems > $CONFIG<message-limit>
                     or (!~$_ and # non-empty are not gisted unless huge
                         (?.?additional-files or $_ ~~ ProperStr)))) {
    # Here $response is a Str with a lot of stuff mixed in (possibly)
    my $description = ‘Whateverable’;
    my $text = colorstrip $response.?long-str // ~$response;
    my %files;
    %files<result> = $text if $text;
    %files.push: $_ with $response.?additional-files;

    if $response ~~ Reply {
        $description = $response.msg.server.current-nick;
        %files<query> = $_ with $response.?msg.?text;
        %files<query>:delete unless %files<query>;
    }
    my $url = upload %files, public => !%*ENV<DEBUGGABLE>, :$description;
    $url = $response.link-msg()($url) if $response ~~ PrettyLink;
    $url
}

#↓ Regular response (not a gist)
multi method filter($text is copy) {
    ansi-to-irc($text)
    .trans([“\r\n”] => [‘␍␤’])
    .trans:
        “\n” => ‘␤’,
        3.chr => 3.chr, 0xF.chr => 0xF.chr, # keep these for IRC colors
        |((^32)».chr Z=> (0x2400..*).map(*.chr)), # convert all unreadable ASCII crap
        127.chr => ‘␡’, /<:Cc>/ => ‘␦’
}

#↓ Gists %files and returns a link
sub upload(%files is copy, :$description = ‘’, Bool :$public = True) is export {
    if %*ENV<TESTABLE> {
        my $gists-path = %*ENV<TESTABLE_GISTS>;
        rmtree $gists-path if $gists-path.IO ~~ :d;
        mkdir $gists-path;
        spurt “$gists-path/{.key}”, .value for %files;
        return ‘https://whatever.able/fakeupload’;
    }

    %files = %files.pairs.map: { .key => %( ‘content’ => .value ) }; # github format

    my $gist = Pastebin::Gist.new(token => $CONFIG<github><access_token> || Nil);
    return $gist.paste: %files, desc => $description, public => $public
}

#↓ Sets things up and starts an IRC client
method selfrun($nick is copy, @alias?) {
    ensure-config;

    use Whateverable::Builds;
    ensure-cloned-repos;

    sleep rand × $CONFIG<join-delay> if none %*ENV<DEBUGGABLE TESTABLE>;

    $nick ~= ‘test’ if %*ENV<DEBUGGABLE>;
    .run with IRC::Client.new(
        :$nick
        :userreal($nick.tc)
        :username($nick.substr(0, 3) ~ ‘-able’)
        :password(?%*ENV<TESTABLE> ?? ‘’ !! $CONFIG<irc><login password>.join: ‘:’)
        :@alias
        # IPv4 address of chat.freenode.net is hardcoded so that we can double the limit ↓
        :host(%*ENV<TESTABLE> ?? ‘127.0.0.1’ !! <chat.freenode.net 195.154.200.232>.pick)
        :port(%*ENV<TESTABLE> ?? %*ENV<TESTABLE_PORT> !! 6667)
        :channels(%*ENV<DEBUGGABLE>
                  ?? $CONFIG<cave>
                  !! %*ENV<TESTABLE>
                     ?? “#whateverable_$nick”
                     !! (|$CONFIG<channels>, $CONFIG<cave>) )
        :debug(?%*ENV<DEBUGGABLE>)
        :plugins(self)
        :filters( -> |c { self.filter(|c) } )
    )
}

# vim: expandtab shiftwidth=4 ft=perl6
