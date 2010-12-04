# -*- Mode: perl; indent-tabs-mode: nil -*-
#
# The contents of this file are subject to the Mozilla Public
# License Version 1.1 (the "License"); you may not use this file
# except in compliance with the License. You may obtain a copy of
# the License at http://www.mozilla.org/MPL/
#
# Software distributed under the License is distributed on an "AS
# IS" basis, WITHOUT WARRANTY OF ANY KIND, either express or
# implied. See the License for the specific language governing
# rights and limitations under the License.
#
# The Original Code is the Bugzilla Bug Tracking System.
#
# The Initial Developer of the Original Code is Everything Solved, Inc.
# Portions created by the Initial Developer are Copyright (C) 2010 the
# Initial Developer. All Rights Reserved.
#
# Contributor(s):
#   Max Kanat-Alexander <mkanat@bugzilla.org>

use strict;
package Bugzilla::DB::Sqlite;
use base qw(Bugzilla::DB);

use Bugzilla::Constants;
use Bugzilla::Error;

use DateTime;
use POSIX ();

# SQLite only supports the SERIALIZABLE and READ UNCOMMITTED isolation
# levels. SERIALIZABLE is used by default and SET TRANSACTION ISOLATION
# LEVEL is not implemented.
use constant ISOLATION_LEVEL => undef;

# Since we're literally using Perl's regexes, we can use something
# simpler and more efficient than what Bugzilla::DB uses.
use constant WORD_START => '(?:^|\W)';
use constant WORD_END   => '(?:$|\W)';

####################################
# Functions Added To SQLite Itself #
####################################

# A case-insensitive, Unicode collation for SQLite. This allows us to
# make all comparisons and sorts case-insensitive (though unfortunately
# not accent-insensitive).
sub _sqlite_collate_ci { lc($_[0]) cmp lc($_[1]) }

sub _sqlite_now {
    my $now = DateTime->now(time_zone => Bugzilla->local_timezone);
    return $now->ymd . ' ' . $now->hms;
}

# SQL's POSITION starts its values from 1 instead of 0 (so we add 1).
sub _sqlite_position {
    my ($text, $fragment) = @_;
    if (!defined $text or !defined $fragment) {
        return undef;
    }
    my $pos = index $text, $fragment;
    return $pos + 1;
}

sub _sqlite_position_ci {
    my ($text, $fragment) = @_;
    return _sqlite_position(lc($text), lc($fragment));
}

###############
# Constructor #
###############

sub new {
    my ($class, $params) = @_;
    my $db_name = $params->{db_name};
    
    # Let people specify paths intead of data/ for the DB.
    if ($db_name and $db_name !~ m{[\\/]}) {
        # When the DB is first created, there's a chance that the
        # data directory doesn't exist at all, because the Install::Filesystem
        # code happens after DB creation. So we create the directory ourselves
        # if it doesn't exist.
        my $datadir = bz_locations()->{datadir};
        if (!-d $datadir) {
            mkdir $datadir or warn "$datadir: $!";
        }
        if (!-d "$datadir/db/") {
            mkdir "$datadir/db/" or warn "$datadir/db: $!";
        }
        $db_name = bz_locations()->{datadir} . "/db/$db_name";
    }

    # construct the DSN from the parameters we got
    my $dsn = "dbi:SQLite:dbname=$db_name";

    my $attrs = {
        # XXX Should we just enforce this to be always on?
        sqlite_unicode => Bugzilla->params->{'utf8'},
    };

    my $self = $class->db_new({ dsn => $dsn, user => '', 
                                pass => '', attrs => $attrs });
    # Needed by TheSchwartz
    $self->{private_bz_dsn} = $dsn;
    
    my %pragmas = (
        # Make sure that the sqlite file doesn't grow without bound.
        auto_vacuum => 1,
        encoding => "'UTF-8'",
        foreign_keys => 'ON',
        # We want the latest file format.
        legacy_file_format => 'OFF',
        # This guarantees that we get column names like "foo"
        # instead of "table.foo" in selectrow_hashref.
        short_column_names => 'ON',
        # The write-ahead log mode in SQLite 3.7 gets us better concurrency,
        # but breaks backwards-compatibility with older versions of
        # SQLite. (Which is important because people may also want to use
        # command-line clients to access and back up their DB.) If you need
        # better concurrency and don't need 3.6 compatibility, then you can
        # uncomment this line.
        #journal_mode => "'WAL'",
    );
    
    while (my ($name, $value) = each %pragmas) {
        $self->do("PRAGMA $name = $value");
    }
    
    $self->sqlite_create_collation('bugzilla', \&_sqlite_collate_ci);
    $self->sqlite_create_function('position', 2, \&_sqlite_position);
    $self->sqlite_create_function('iposition', 2, \&_sqlite_position_ci);
    # SQLite has a "substr" function, but other DBs call it "SUBSTRING"
    # so that's what we use, and I don't know of any way in SQLite to
    # alias the SQL "substr" function to be called "SUBSTRING".
    $self->sqlite_create_function('substring', 3, \&CORE::substr);
    $self->sqlite_create_function('now', 0, \&_sqlite_now);
    $self->sqlite_create_function('localtimestamp', 1, \&_sqlite_now);
    $self->sqlite_create_function('floor', 1, \&POSIX::floor);

    bless ($self, $class);
    return $self;
}

###############
# SQL Methods #
###############

sub sql_position {
    my ($self, $fragment, $text) = @_;
    return "POSITION($text, $fragment)";
}

sub sql_iposition {
    my ($self, $fragment, $text) = @_;
    return "IPOSITION($text, $fragment)";
}

# SQLite does not have to GROUP BY the optional columns.
sub sql_group_by {
    my ($self, $needed_columns, $optional_columns) = @_;
    my $expression = "GROUP BY $needed_columns";
    return $expression;
}

# XXX SQLite does not support sorting a GROUP_CONCAT, so $sort is unimplemented.
sub sql_group_concat {
    my ($self, $column, $separator, $sort) = @_;
    $separator = $self->quote(', ') if !defined $separator;
    # In SQLite, a GROUP_CONCAT call with a DISTINCT argument can't
    # specify its separator, and has to accept the default of ",".
    if ($column =~ /^DISTINCT/) {
        return "GROUP_CONCAT($column)";
    }
    return "GROUP_CONCAT($column, $separator)";
}

sub sql_istring {
    my ($self, $string) = @_;
    return $string;
}

sub sql_regexp {
    my ($self, $expr, $pattern, $nocheck, $real_pattern) = @_;
    $real_pattern ||= $pattern;

    $self->bz_check_regexp($real_pattern) if !$nocheck;

    return "$expr REGEXP $pattern";
}

sub sql_not_regexp {
    my $self = shift;
    my $re_expression = $self->sql_regexp(@_);
    return "NOT($re_expression)";
}

sub sql_limit {
    my ($self, $limit, $offset) = @_;

    if (defined($offset)) {
        return "LIMIT $limit OFFSET $offset";
    } else {
        return "LIMIT $limit";
    }
}

sub sql_from_days {
    my ($self, $days) = @_;
    return "DATETIME($days)";
}

sub sql_to_days {
    my ($self, $date) = @_;
    return "JULIANDAY($date)";
}

sub sql_date_format {
    my ($self, $date, $format) = @_;
    $format = "%Y.%m.%d %H:%M:%s" if !$format;
    $format =~ s/\%i/\%M/g;
    return "STRFTIME(" . $self->quote($format) . ", $date)";
}

sub sql_date_math {
    my ($self, $date, $operator, $interval, $units) = @_;
    # We do the || thing (concatenation) so that placeholders work properly.
    return "DATETIME($date, '$operator' || $interval || ' $units')";
}

sub sql_string_until {
    my ($self, $string, $substring) = @_;
    my $position = $self->sql_position($substring, $string);
    return "SUBSTR($string, 1, $position - 1)"
}

# XXX This needs to be implemented.
sub bz_explain { }

1;

__END__

=head1 NAME

Bugzilla::DB::Sqlite - Bugzilla database compatibility layer for SQLite

=head1 DESCRIPTION

This module overrides methods of the Bugzilla::DB module with a
SQLite-specific implementation. It is instantiated by the Bugzilla::DB module
and should never be used directly.

For interface details see L<Bugzilla::DB> and L<DBI>.