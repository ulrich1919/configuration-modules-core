#${PMcomponent}

=head1 NAME

ncm-altlogrotate: configuration module to control the log rotate configuration.

=head1 DESCRIPTION

The I<altlogrotate> component manages the log rotate configuration files.
It replaced the original I<logrotate> which is no longer available.

=cut

use parent qw(NCM::Component CAF::Path);

our $EC = LC::Exception::Context->new->will_store_all;
our $NoActionSupported = 1;

use Readonly;

Readonly my $HEADER => "\n#\n# Generated by ncm-altlogrotate.\n#\n";

# <key> (if true)
# no<key> (if false)
Readonly::Array my @BOOLEANS => qw(
    compress copy copytruncate dateext delaycompress
    ifempty missingok sharedscripts
    );
# <key> <value>
Readonly::Array my @STRINGS => qw(
    compresscmd uncompresscmd compressext compressoptipons
    extension mail olddir rotate start size
    );
# <value>
Readonly::Array my @VALUES => qw(
    frequency
);

sub process_entry
{
    my ($self, $fh, $entry) = @_;

    print $fh "$entry->{pattern} {\n" if defined($entry->{pattern});

    foreach my $key (@BOOLEANS) {
        my $neg = $key eq 'ifempty' ? 'not' : 'no';
        print $fh ($entry->{$key} ? '' : $neg)."$key\n" if defined($entry->{$key});
    }

    foreach my $key (@STRINGS) {
        print $fh "$key $entry->{$key}\n" if defined($entry->{$key});
    }

    foreach my $key (@VALUES) {
        print $fh "$entry->{$key}\n" if defined($entry->{$key});
    }

    if ($entry->{create}) {
        my @create = qw(create);
        if (defined($entry->{createparams})) {
            push(@create, map {$entry->{createparams}->{$_}} qw(mode owner group));
        }
        print $fh join(' ', @create)."\n";
    } elsif (defined($entry->{create})) {
        print $fh "nocreate\n";
    }

    print $fh "mail$entry->{mailselect}\n" if $entry->{mailselect};

    print $fh "nomail\n" if $entry->{nomail};

    print $fh "noolddir\n" if ($entry->{noolddir} && !exists($entry->{olddir}));

    print $fh 'tabooext ', $entry->{taboo_replace} ? '' : '+ ', join(',', @{$entry->{tabooext}}), "\n"
        if defined($entry->{tabooext});

    if (defined($entry->{su})) {
        print $fh join(' ', 'su', $entry->{su}->{user}, $entry->{su}->{group}), "\n";
    }

    foreach my $name (sort keys %{$entry->{scripts} || {}}) {
        print $fh "$name\n\n", $entry->{scripts}->{$name}, "\n\nendscript\n";
    }

    if (defined($entry->{pattern})) {
        print $fh "}\n";
    } else {
        print $fh "include $entry->{include}\n" if defined($entry->{include});
    }

}

# simple wrapper for easier unittesting
# glob is one of those CORE functions you can't/shouldn't mess with
sub _glob
{
    shift;
    return glob(join(" ", @_));
}

sub Configure
{

    my ($self, $config) = @_;

    my $tree = $config->getTree($self->prefix);

    my $cfgfile = $tree->{configFile};
    my $cfgdir = $tree->{configDir};

    if (!$self->directory($cfgdir, owner => 0, mode => oct(755))) {
        $self->error("$cfgdir directory can't be made or isn't a directory: $self->{fail}");
        return;
    }

    # Collect the current entries in the logrotate.d directory.
    # NOTE: only those explicitly managed by the component are selected.
    #       except those that were overwritten (once)
    my @to_be_deleted = $self->_glob("$cfgdir/*.ncm-altlogrotate");

    # List with all files that are managed by this component
    # These files will not be deleted.
    my @managed;

    # Look for names that are related to the global config file
    my $overallglobal;
    my @globals;
    foreach my $name (sort keys %{$tree->{entries}}) {
        if ($name eq 'global') {
            $overallglobal = 1; # global config file will be re-created
            $self->verbose('entry name global found, processing it as first one');
        } elsif ($tree->{entries}->{$name}->{global}) {
            push @globals, $name;
            $self->verbose("entry name $name with global=true found");
        }
    }

    # Next process global config file
    if (@globals) {
        if ($overallglobal) {
            unshift @globals, 'global';

            my $fh = CAF::FileWriter->new($cfgfile, log => $self);
            print $fh $HEADER;

            foreach my $name (@globals) {
                $self->verbose("Adding entry $name to global $cfgfile");
                $self->process_entry($fh, $tree->{entries}->{$name});
            }

            $fh->close();
        } else {
            # entries with global flag, but without "overall" global set
            # This is now also prohibited by schema
            $self->error("Found @globals for global configuration file, ",
                         "but no entry for global config file defined: all settings ignored");
        }
    }

    # Next process all others
    foreach my $name (sort keys %{$tree->{entries}}) {
        # skip globals
        next if grep {$name eq $_} @globals;

        my $entry = $tree->{entries}->{$name};

        my $file = "$cfgdir/$name";
        # replace existing legacy logrotate file (if option 'overwrite'==true)?
        if ($entry->{overwrite} && $self->file_exists($file)) {
            $self->verbose("Entry $name with overwrite=1 and existing $file");
        } else {
            $file .= ".ncm-altlogrotate";
        }

        # Add to managed files, will not be deleted
        push(@managed, $file);

        my $fh = CAF::FileWriter->new($file, log => $self);
        print $fh $HEADER;
        $self->verbose("Creating entry $name with $file");
        $self->process_entry($fh, $entry);
        $fh->close();
    }

    # Delete non-managed files.  This should always be done as no entries
    # in the machine profile means that there should be no entries in
    # the directory either.
    foreach my $existing (@to_be_deleted) {
        next if grep {$existing eq $_} @managed;
        $self->warn("error ($self->{fail}) deleting file $existing") if (!$self->cleanup($existing))
    }

    return 1;
}



1;      # Required for PERL modules
