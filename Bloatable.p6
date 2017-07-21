#!/usr/bin/env perl6
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

use lib ‘.’;
use Misc;
use Whateverable;

use IRC::Client;

unit class Bloatable does Whateverable;

method help($msg) {
    “Like this: {$msg.server.current-nick}: d=compileunits 292dc6a,HEAD”
}

multi method irc-to-me($msg where /^ :r [ [ ‘d=’ | ‘-d’ \s* ] $<sources>=[\S+] \s ]?
                                    \s* $<config>=<.&commit-list> $/) {
    my $value = self.process: $msg, ~$<config>, ~($<sources> // ‘compileunits’);
    return without $value;
    return $value but Reply($msg)
}

multi method bloaty($sources, %prev, %cur) {
    self.run-smth: :backend<moarvm>, %prev<full-commit>, -> $prev-path {
        !“$prev-path/lib/libmoar.so”.IO.e
        ?? “No libmoar.so file in build %prev<short-commit>”
        !! self.run-smth: :backend<moarvm>, %cur<full-commit>, -> $cur-path {
            !“$cur-path/lib/libmoar.so”.IO.e
            ?? “No libmoar.so file in build %cur<short-commit>”
            !! self.get-output: ‘bloaty’, ‘-d’, $sources, ‘-n’, ‘50’,
                                “$cur-path/lib/libmoar.so”, ‘--’, “$prev-path/lib/libmoar.so”
        }
    }
}

multi method bloaty($sources, %prev) {
    self.run-smth: :backend<moarvm>, %prev<full-commit>, -> $prev-path {
        !“$prev-path/lib/libmoar.so”.IO.e
        ?? “No libmoar.so file in build %prev<short-commit>”
        !! self.get-output: ‘bloaty’, ‘-d’, $sources, ‘-n’, ‘100’,
                            “$prev-path/lib/libmoar.so”
    }
}

method did-you-mean($out) {
    return if $out !~~ Associative;
    return if $out<exit-code> == 0;
    if $out<output> ~~ /(‘no such data source:’ .*)/ {
        return $0.tc ~ ‘ (Did you mean one of these: ’
               ~ self.get-output(‘bloaty’, ‘--list-sources’)<output>.lines.join(‘ ’)
               ~ ‘ ?)’
    }
    Nil
}

method process($msg, $config, $sources is copy) {
    my $old-dir = $*CWD;

    my ($commits-status, @commits) = self.get-commits: $config, repo => MOARVM;
    return $commits-status unless @commits;

    my %files;

    my @processed;
    for @commits -> $commit {
        my %prev = @processed.tail if @processed;
        my %cur;
        # convert to real ids so we can look up the builds
        %cur<full-commit> = self.to-full-commit: $commit, repo => MOARVM;
        if not defined %cur<full-commit> {
            %cur<error> = “Cannot find revision $commit”;
            my @options = <HEAD v6.c releases all>;
            %cur<error> ~= “ (did you mean “{self.get-short-commit: self.get-similar: $commit, @options, repo => MOARVM}”?)”
        } elsif not self.build-exists: %cur<full-commit>, :backend<moarvm> {
            %cur<error> = ‘No build for this commit’
        }
        %cur<short-commit> = self.get-short-commit: $commit;
        %cur<short-commit> ~= “({self.get-short-commit: %cur<full-commit>})” if $commit eq ‘HEAD’;
        if %prev {
            my $filename = “result-{(1 + %files).fmt: ‘%05d’}”;
            my $result = “Comparing %prev<short-commit> → %cur<short-commit>\n”;
            if %prev<error> {
                $result ~= “Skipping because of the error with %prev<short-commit>:\n”;
                $result ~= %prev<error>
            } elsif %cur<error> {
                $result ~= “Skipping because of the error with %cur<short-commit>:\n”;
                $result ~= %cur<error>
            } elsif %prev<full-commit> eq %cur<full-commit> {
                $result ~= “Skipping because diffing the same commit is pointless.”;
            } else {
                my $out = self.bloaty: $sources, %prev, %cur;
                return $_ with self.did-you-mean: $out;
                $result ~= $out<output> // $out;
            }
            %files{$filename} = $result
        }
        @processed.push: %cur
    }

    if @commits == 1 {
        my %prev = @processed.tail;
        return %prev<error> if %prev<error>;
        my $out = self.bloaty: $sources, %prev;
        return $_ with self.did-you-mean: $out;
        return ($out<output> // $out) but ProperStr(“%prev<short-commit>\n{$out<output> // $out}”)
    } elsif @commits == 2 and (@processed[*-2]<error> or @processed[*-1]<error>) {
        # print obvious problems without gisting the whole thing
        return @processed[*-2]<error> || @processed[*-1]<error>;
        # TODO this does not catch missing libmoar.so files
    } else {
        return ‘’ but FileStore(%files);
    }

    LEAVE {
        chdir $old-dir;
    }
}

Bloatable.new.selfrun: ‘bloatable6’, [ /‘bloat’ y?6?/, fuzzy-nick(‘bloatable6’, 2) ]

# vim: expandtab shiftwidth=4 ft=perl6
