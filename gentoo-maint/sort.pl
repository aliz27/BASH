#!/usr/bin/perl
sub versioncmp( $$ ) {
    my @A = ($_[0] =~ /([\-\.]|\d+|[^-.\d]+)/g);
    my @B = ($_[1] =~ /([\-\.]|\d+|[^-.\d]+)/g);

    my ($A, $B);
    while (@A and @B) {
        $A = shift @A;
        $B = shift @B;
        if ($A eq '-' and $B eq '-') {
            next;
        } elsif ( $A eq '-r' ) {
            return 1;
        } elsif ( $B eq '-r') {
            return -1;
        } elsif ($A eq '.' and $B eq '.') {
            next;
        } elsif ( $A eq '.' ) {
            return 1;
        } elsif ( $B eq '.' ) {
            return -1;
        } elsif ($A =~ /^\d+$/ and $B =~ /^\d+$/) {
            if ($A =~ /^0/ || $B =~ /^0/) {
#               return $A cmp $B if $A cmp $B;
                return lc($A) cmp lc($B) if lc($A) cmp lc($B);
            } else {
                return $A <=> $B if $A <=> $B;
            }
        } else {
            $A = uc $A;
            $B = uc $B;
            return lc($A) cmp lc($B) if lc($A) cmp lc($B);
#           return $A cmp $B if $A cmp $B;
        }
    }
    @A <=> @B;
}

foreach $r (split(" ", <STDIN>)) { push (@blah, "$r"); }
@l = sort { versioncmp($b, $a) } @blah;
printf "@l";
