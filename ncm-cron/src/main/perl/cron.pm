# ${license-info}
# ${developer-info}
# ${author-info}


#######################################################################
#                 /etc/cron.conf
#######################################################################

package NCM::Component::cron;

use strict;
use NCM::Component;
use vars qw(@ISA $EC);
@ISA = qw(NCM::Component);
$EC=LC::Exception::Context->new->will_store_all;
use NCM::Check;
use File::Copy;

use EDG::WP4::CCM::Element;

use LC::Check;

use Encode qw(encode_utf8);

local(*DTA);


##########################################################################
sub Configure($$@) {
##########################################################################
    
    my ($self, $config) = @_;

    # Define paths for convenience. 
    my $base = "/software/components/cron";

    # Define some defaults
    my $crond = "/etc/cron.d";
    my $date = "date --iso-8601=seconds --utc";
    my $cron_entry_extension_prefix = ".ncm-cron";
    my $cron_entry_extension = $cron_entry_extension_prefix . ".cron";
    my $cron_log_extension = $cron_entry_extension_prefix . ".log";
    my $cron_entry_regexp = $cron_entry_extension;
    $cron_entry_regexp =~ s/\./\\./g;
    
    # Load ncm-cron configuration into a hash
    my $cron_config = $config->getElement($base)->getTree();
    my $cron_entries = $cron_config->{entries};

    # Collect the current entries managed by ncm-cron in the cron.d directory.
    opendir DIR, $crond;
    my @files = grep /$cron_entry_regexp$/, map "$crond/$_", readdir DIR;
    closedir DIR;

    # Actually delete them.  This should always be done as no entries
    # in the profile indicates that there should be no entries in the
    # cron.d directory either. 
    foreach my $to_unlink (@files) {
	# Untainted to_unlink to work with tainted perl mode (-T option)
        if ($to_unlink =~ /^(.*)$/) {
                $to_unlink = $1;                     # $to_unlink is now untainted
        } else {
                $self->error("Bad data in $to_unlink"); 
        }

	unlink $to_unlink;
        $self->log("error ($?) deleting file $_") if $?;
    }

    # Only continue if the entries line is defined. 
    unless ($cron_entries) {
        return 1;
    }

    # Loop through all of the entries creating one cron file for each
    for my $entry (@{$cron_entries}) {
        my $name = $entry->{name};
        unless ($name) {
            $self->error("Undefined name for cron entry; skipping");
            next;
        }
        $self->info("Checking cron entry $name...");
        my $file = "$crond/$name.ncm-cron.cron";
  
        # User: use root if not specified.
        my $user = 'root';
        if ( $entry->{user}) {
            $user = $entry->{user};
        }
        my $uid = getpwnam($user);
        unless (defined($uid) ) {
            $self->error("Undefined user ($user) for entry $name; skipping");
            next;
        }
  
        # Group : use the primary group of the user if not specified.
        my $group = undef;
        my $gid = undef;
        if ( $entry->{group}) {
            $group = $entry->{group};
        } else {
            $gid = (getpwnam($user))[3];
            if ( defined($gid) ) {
                $group = getgrgid($gid);
            } else {
                $self->error("Unable to determine default group for entry $name; skipping");
                next;            
            }
        }
        unless ( defined($gid) ) {
            $gid = getgrnam($group);        
        }
        unless ( defined($gid) ) {
            $self->error("Undefined group ($group) for entry $name; skipping");
            next;
        }
  
        
        # Log file name, owner and mode.
        # If specified log file name is not an absolute path, create it in /Var/log
        my $log_name = "/var/log/$name$cron_log_extension";
        my $log_owner = undef;
        my $log_group = undef;
        my $log_mode = 0640;
        
        my $log_params = $entry->{log};
        if ( $log_params->{name} ) {
            $log_name = $log_params->{name};
            unless ( $log_name =~ /^\s*\// ) {
              $log_name = '/var/log/' . $log_name;
            }
        }
        if ( $log_params->{owner} ) {
            my $owner_group = $log_params->{owner};
            ($log_owner, $log_group) = split /:/, $owner_group;
        }
        unless ( $log_owner ) {
            $log_owner = $user;
        }
        unless ( $log_group ) {
            $log_group = $group;
        }
        if ( $log_params->{mode} ) {
            $log_mode = oct($log_params->{mode});
        }
  
        # Frequency of the cron entry.
        # May contain AUTO for the minutes field : in this case, substitute AUTO
        # with a random value. This only works in the minutes field of the frequence. 
        my $frequency = undef;
        if ( $entry->{frequency}) {
            $frequency = $entry->{frequency};
        } else {
            $self->error("Undefined frequency for entry $name; skipping");
            next;
        }
        $frequency =~ s/AUTO/int(rand(60))/eg;
  
        # Extract the mandatory command.  If it isn't provided,
        # then skip to next entry.
        my $command = undef;
        if ( $entry->{command}) {
            $command = $entry->{command};
        } else {
            $self->error("Undefined frequency for entry $name; skipping");
            next;
        }
  
        # Pull out the optional comment.  Will be added just after
        # the generic autogenerated file warning.
        # Split the comment by line.  Prefix each line with a hash.
        my $comment = '';
        if ( $entry->{comment}) {
            $comment = $entry->{comment};
            my @lines = split /\n/m, $comment;
            $comment = '';
            foreach (@lines) {
                $comment .= "# " . $_ . "\n";
            }
        }
  
        # Determine if there is an environment to set.  If so,
        # extract the key value pairs.
        my $cronenv = '';
        my $env_entries = $entry->{env};
        if ( $env_entries ) {
            foreach (sort keys %{$env_entries}) {
                $cronenv .= "$_=" . $env_entries->{$_} . "\n";
            }
        }
  
  
        # Generate the contents of the cron entry and write the output file.
        # Ensure permissions are appropriate for execution by cron (permission x must not be set) 
        my $contents = "#\n# File generated by ncm-cron. DO NOT EDIT.\n#\n";
        $contents .= $comment;
        $contents .= $cronenv;
        $contents .= "$frequency $user ($date; $command) >> $log_name 2>&1\n";

        my $changes = LC::Check::file("$file",
                                      contents => encode_utf8($contents),
                                      mode => 0644,
                                     );
        if ( $changes < 0 ) {
            $self->error("Error updadating cron file $file");
        }
  
        # Create the log file and change the owner if necessary.
        if ( -f $log_name ) {
            $changes = LC::Check::status($log_name,
                                         owner => $log_owner,
                                         group => $log_group,
                                         mode => $log_mode,
                                        );
            if ( $changes < 0 ) {
                $self->error("Error setting owner/permissions on log file $log_name");
            }          
        } else {
            $changes = LC::Check::file($log_name,
                                       contents => '',
                                       owner => $log_owner,
                                       group => $log_group,
                                       mode => $log_mode,
                                      );
            if ( $changes < 0 ) {
                $self->warn("Error creating log file $log_name");
            }
        }
        
    }
    
    return 1;
}

1;      # Required for PERL modules
