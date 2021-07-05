use File::Directory::Tree;
use IRC::Client;
use Test;

my regex sha    is export { <.xdigit>**7..10 }
my regex me($t) is export { $($t.our-nick)   }

sub bot-gist-dir($bot) { “/tmp/whateverable/tist/$bot”.IO }

class Testable {
    has $.bot;
    has $.our-nick;
    has $.bot-nick;

    has $!server-proc;
    has $!bot-proc;
    has $!irc-client;
    has $!bridge-client;
    has $.messages;

    has $!first-test;
    has $!delay-channel;

    submethod BUILD(:$bot, :$our-nick = ‘testable’) {
        $!bot = $bot;
        my $ready  = Channel.new;
        $!messages = Channel.new;

        my $sig-compat = SIGUSR1;
        # ↓ Fragile platform-specific hack
        $sig-compat = SIGBUS if v2018.04 ≤ $*PERL.compiler.version ≤ v2018.05;
        $!delay-channel = signal($sig-compat).Channel;

        use Whateverable::Config;
        ensure-config ‘config-default.json’.IO.open;
        use Whateverable::Builds;
        ensure-cloned-repos;

        my $self = self;

        my $host = ‘localhost’;
        my $port = (1024..65535).pick; # will do for now
        $!server-proc = Proc::Async.new: <3rdparty/miniircd/miniircd>,
                                         “--listen=$host”, “--ports=$port”;
        END .kill with $!server-proc;
        %*ENV<TESTABLE_PORT> = $port;
        %*ENV<TESTABLE_GISTS> = bot-gist-dir $!bot;
        my $started = $!server-proc.start;
        sleep 1;
        if $started.status ~~ Broken {
            die “Can't start miniircd, did you clone with --recurse-submodules ?\n”
              ~ ‘if not, you can do that now with: git submodule update --init --recursive’
        }
        note “# IRC test server on $host:$port”;

        $!irc-client = IRC::Client.new(
            :nick($our-nick ~ (^999999 .pick))
            :host<127.0.0.1>
            :$port
            :channels(“#whateverable_{$bot.lc}6”)
            :plugins(
                class {
                    method irc-privmsg-channel($m) {
                        $self.messages.send: $m.args[1] if $m.nick eq $self.bot-nick;
                        Nil
                    }
                    method irc-join($m) {
                        $ready.send: $m.nick if $++ == 1
                    }
                }
            )
        );
        start $!irc-client.run;
        # The bridge client might be needed later. We don't start it yet.
        $!bridge-client = IRC::Client.new(
            :nick<raku-bridge>
            :host<127.0.0.1> :$port
            :channels(“#whateverable_{$bot.lc}6”)
        );

        my $executable = ‘./xbin/’ ~ $bot ~ ‘.p6’;
        run :env(|%*ENV, PERL6LIB => ‘lib’), <perl6 -c -->, $executable; # precompahead
        $!bot-proc = Proc::Async.new: <perl6 -->, $executable;
        END .kill with $!bot-proc;
        $!bot-proc.bind-stdin: ‘config.json’.IO.open || ‘config-default.json’.IO.open;
        start react {
            whenever $!bot-proc.start(:ENV(|%*ENV, PERL6LIB => ‘lib’)) {
                note “# Bot process finished (exit code={.exitcode}, signal={.signal})”
            }
        }

        my $bot-pid = await $!bot-proc.ready;
        note “# Bot pid: $bot-pid”;

        start { sleep 20; $ready.send: False }
        $!bot-nick = $ready.receive;
        $!our-nick = $!irc-client.servers.values[0].current-nick;
        ok ?$!bot-nick, ‘bot joined the channel’;
        is $!bot-nick, “{$bot.lc}6”, ‘bot nickname is expected’
    }

    method !start-bridge {
        my Promise $connected .= new;
        $!bridge-client.plugins.push: class {
            method irc-connected (|c) { $connected.keep }
        }
        start $!bridge-client.run;
        await Promise.anyof: $connected, Promise.in(10);
        ok $connected.status ~~ Kept, ‘bridge client connected’;
    }

    method test(|c ($description, :$both = True, |rest)) {
        $!first-test = c without $!first-test;
        self!do-test($description, |rest);
        self!do-test($description ~ " (bridged)", :bridge, |rest) if $both;
    }

    method !do-test(|c ($description, $command, *@expected, :$timeout is copy = 25, :$delay = 0.5, :$bridge = False)) {
        $timeout ×= 1.5 if %*ENV<HARNESS_ACTIVE>; # expect some load (relevant for parallelized tests)

        my $gists-path = bot-gist-dir $!bot;
        rmtree $gists-path if $gists-path.IO ~~ :d;

        my @got;
        my $start = now;

        state $started-bridge = 0;
        if $bridge {
            self!start-bridge unless $started-bridge++;
            $!bridge-client.send: :where(“#whateverable_$!bot-nick”) :text("<$!our-nick> $command");
        }
        else {
            $!irc-client.send: :where(“#whateverable_$!bot-nick”) :text($command);
        }
        sleep $delay if @expected == 0; # make it possible to check for no replies
        my $lock-delay = 0;
        for ^@expected {
            my $message = $!messages.poll;
            if not defined $message {
                $lock-delay += 0.5 while $!delay-channel.poll;
                if now - $start - $lock-delay > $timeout {
                    diag “Failed to get expected result in {now - $start} seconds ($timeout nominal)”;
                    last
                }
                sleep 0.1;
                redo
            }
            @got.push: $message
        }
        cmp-ok @got, &[~~], @expected, $description
    }

    method test-gist($description, %files) {
        for %files.kv -> $file, $tests {
            my $path = bot-gist-dir($!bot).add: $file;
            ok $path.IO ~~ :f, “gist file $file exists”;
            cmp-ok slurp($path), &[~~], $_, “gist file {$file}: $description” for @$tests;
        }
    }

    method last-test {
        self.test(|$!first-test);

        my $answer;
        self.test(‘total uptime’, “{$.bot-nick}: uptime”, {$answer=$_; True});
        mkdir ‘logs/tests’;
        my $logfile = sprintf “%s_uptime_%04d-%02d-%02d_%02d%02d.log”, $.bot.lc,
                      .year, .month, .day, .hour, .minute with now.DateTime;
        “logs/tests/$logfile”.IO.spurt: $answer;
    }

    method end {
        $!bot-proc.kill;
        $!irc-client.quit;
        sleep 2;
        $!server-proc.kill;
        sleep 1
    }

    method common-tests(:$help) {
        temp $!first-test;

        self.test(‘source link’,
                  “$.bot-nick: Source   ”,
                  “$.our-nick, https://github.com/Raku/whateverable”);

        self.test(‘source link’,
                  “$.bot-nick:   sourcE?  ”,
                  “$.our-nick, https://github.com/Raku/whateverable”);

        self.test(‘source link’,
                  “$.bot-nick:   URl ”,
                  “$.our-nick, https://github.com/Raku/whateverable”);

        self.test(‘source link’,
                  “$.bot-nick:  urL?   ”,
                  “$.our-nick, https://github.com/Raku/whateverable”);

        self.test(‘source link’,
                  “$.bot-nick: wIki”,
                  “$.our-nick, https://github.com/Raku/whateverable/wiki/$.bot”);

        self.test(‘source link’,
                  “$.bot-nick:   wiki? ”,
                  “$.our-nick, https://github.com/Raku/whateverable/wiki/$.bot”);


        self.test(‘help message’,
                  “$.bot-nick, helP”,
                  “$.our-nick, $help # See wiki for more examples: ”
                      ~ “https://github.com/Raku/whateverable/wiki/$.bot”);

        self.test(‘help message’,
                  “$.bot-nick,   HElp?  ”,
                  “$.our-nick, $help # See wiki for more examples: ”
                      ~ “https://github.com/Raku/whateverable/wiki/$.bot”);

        self.test(‘usage message’,
                  “$.bot-nick, usage”,
                  “$.our-nick, $help # See wiki for more examples: ”
                      ~ “https://github.com/Raku/whateverable/wiki/$.bot”);

        self.test(‘usage message’,
                  “$.bot-nick,   usage?  ”,
                  “$.our-nick, $help # See wiki for more examples: ”
                      ~ “https://github.com/Raku/whateverable/wiki/$.bot”);

        self.test(‘typoed name’,
                  “z{$.bot-nick.substr: 1}: source”, # mangle it just a little bit
                  “$.our-nick, https://github.com/Raku/whateverable”);

        self.test(‘no space after name (semicolon delimiter)’,
                  “{$.bot-nick}:url”,
                  “$.our-nick, https://github.com/Raku/whateverable”);

        self.test(‘no space after name (comma delimiter)’,
                  “$.bot-nick,url”,
                  “$.our-nick, https://github.com/Raku/whateverable”);

        self.test(‘age inquiry (directly)’,
                  “$.bot-nick, how old are you?”,
                  /^“{$.our-nick}, ” ‘I was created on ’ [ \d**4 ‘-’ \d**2 ‘-’ \d**2 ] /);

        self.test(‘age inquiry (indirectly)’,
                  “age, {$.bot-nick}?”,
                  /^“{$.our-nick}, ” ‘I was created on ’ [ \d**4 ‘-’ \d**2 ‘-’ \d**2 ] /);

        use Whateverable;
        self.test(‘thank you (directly)’,
                  “$.bot-nick: thank you!”,
                  /^“{$.our-nick}, ”@(you're-welcome)/);

        self.test(‘thank you (indirectly)’,
                  “thanks, $.bot-nick!”,
                  /^“{$.our-nick}, ”@(you're-welcome)/);

        self.test(‘uptime’,
                  “{$.bot-nick}: uptime”,
                  /^“{$.our-nick}”‘, ’\d+‘ second’s?‘, ’\d+[‘.’\d+]?
                    ‘MiB maxrss. This is Rakudo version ’
                    <[\dabcdefg.-]>+‘ built on MoarVM version ’
                    <[\dabcdefg.-]>+‘ implementing ’[Perl|Raku]‘ 6.’\w‘.’$/);
    }

    method shortcut-tests(@yes, @no) {
        temp $!first-test;

        for @yes {
            self.test(““$_” shortcut”,
                      “{$_}url”,
                      “$.our-nick, https://github.com/Raku/whateverable”);
            self.test(““$_ ” shortcut”,
                      “$_ url”,
                      “$.our-nick, https://github.com/Raku/whateverable”);
        }
        for @no {
            self.test(““$_” shortcut does not work”,
                      “$_ url”);
        }
    }
}

# vim: expandtab shiftwidth=4 ft=perl6
