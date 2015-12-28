# ${license-info}
# ${developer-info}
# ${author-info}
# ${build-info}
#
#
# This module implement a rule-based editor that is used to modify the content
# of an existing file without taking care of the whole file. Each rule
# driving the edition process is applied to one matching line. The input for
# updating the file is the Quattor configuration and conditions can be defined
# based on the contents of this configuration.
#
#######################################################################

package NCM::Component::DPMLFC::RuleBasedEditor;

use strict;
use warnings;
use NCM::Component;
use vars qw(@ISA $EC);
@ISA = qw(NCM::Component);
$EC=LC::Exception::Context->new->will_store_all;

use EDG::WP4::CCM::Element;

use Readonly;

use CAF::FileEditor;

use Encode qw(encode_utf8);

local(*DTA);

# Constants use to format lines in configuration files
# Exported constants
use enum qw(LINE_FORMAT_PARAM=1
            LINE_FORMAT_ENVVAR
            LINE_FORMAT_XRDCFG
            LINE_FORMAT_XRDCFG_SETENV
            LINE_FORMAT_XRDCFG_SET
           );
use enum qw(LINE_VALUE_AS_IS
            LINE_VALUE_BOOLEAN
            LINE_VALUE_HOST_LIST
            LINE_VALUE_INSTANCE_PARAMS
            LINE_VALUE_ARRAY
            LINE_VALUE_HASH_KEYS
            LINE_VALUE_STRING_HASH
           );
use enum qw(LINE_VALUE_OPT_NONE
            LINE_VALUE_OPT_SINGLE
           );
# Internal constants
use constant LINE_FORMAT_DEFAULT => LINE_FORMAT_PARAM;
use constant LINE_QUATTOR_COMMENT => "\t\t# Line generated by Quattor";
use constant LINE_OPT_DEF_REMOVE_IF_UNDEF => 0;
use constant LINE_OPT_DEF_ALWAYS_RULES_ONLY => 0;


# Export constants used to build rules
Readonly my @RULE_CONSTANTS => ('LINE_FORMAT_PARAM',
                                'LINE_FORMAT_ENVVAR',
                                'LINE_FORMAT_XRDCFG',
                                'LINE_FORMAT_XRDCFG_SETENV',
                                'LINE_FORMAT_XRDCFG_SET',
                                'LINE_VALUE_AS_IS',
                                'LINE_VALUE_BOOLEAN',
                                'LINE_VALUE_HOST_LIST',
                                'LINE_VALUE_INSTANCE_PARAMS',
                                'LINE_VALUE_ARRAY',
                                'LINE_VALUE_HASH_KEYS',
                                'LINE_VALUE_STRING_HASH',
                                'LINE_VALUE_OPT_NONE',
                                'LINE_VALUE_OPT_SINGLE',
                               );
our @EXPORT_OK;
our %EXPORT_TAGS;
push @EXPORT_OK, @RULE_CONSTANTS;
$EXPORT_TAGS{rule_constants} = \@RULE_CONSTANTS;


# Backup file extension
use constant BACKUP_FILE_EXT => ".old";


=pod

=head1 DESCRIPTION

This module implements a rule-based editor. It has only one public method: B<updateConfigfile>.
Rules are passed as a hash.

See https://github.com/quattor/CAF/issues/123#issue-123702165 for details.

=head2 Private methods

=over

=item formatAttrValue

This function formats an attribute value based on the value format specified.

Arguments :
    attr_value : attribue value
    line_fmt : line format (see LINE_FORMAT_xxx constants)
    value_fmt : value format (see LINE_VALUE_xxx constants)

=cut

sub formatAttributeValue {
  my $function_name = "formatAttributeValue";
  my ($self, $attr_value, $line_fmt, $value_fmt) = @_;

  unless ( defined($attr_value) ) {
    $self->error("$function_name: 'attr_value' argument missing (internal error)");
    return 1;
  }
  unless ( defined($line_fmt) ) {
    $self->error("$function_name: 'list_fmt' argument missing (internal error)");
    return 1;
  }
  unless ( defined($value_fmt) ) {
    $self->error("$function_name: 'value_fmt' argument missing (internal error)");
    return 1;
  }

  $self->debug(2,"$function_name: formatting attribute value >>>$attr_value<<< (line fmt=$line_fmt, value fmt=$value_fmt)");

  my $formatted_value;
  if ( $value_fmt == LINE_VALUE_HOST_LIST ) {    
    # Duplicates may exist as result of a join. Check it.
    # Some config files are sensitive to extra spaces : this code ensure that there is none.
    my @hosts = split /\s+/, $attr_value;
    my %hosts = map { $_ => '' } @hosts;
    $formatted_value = join(" ", sort keys %hosts);
    $self->debug(1,"Formatted hosts list : >>$formatted_value<<");

  } elsif ( $value_fmt == LINE_VALUE_BOOLEAN ) {
    $formatted_value = $attr_value ? 'yes' : 'no';

  } elsif ( $value_fmt == LINE_VALUE_INSTANCE_PARAMS ) {
    $formatted_value = '';          # Don't return undef if no matching attributes is found
    # Instance parameters are described in a nlist
    $formatted_value .= " -l $attr_value->{logFile}" if $attr_value->{logFile};
    $formatted_value .= " -c $attr_value->{configFile}" if $attr_value->{configFile};
    $formatted_value .= " -k $attr_value->{logKeep}" if $attr_value->{logKeep};
    
  } elsif ( $value_fmt == LINE_VALUE_ARRAY ) {
    $formatted_value = join " ", @$attr_value;

  } elsif ( $value_fmt == LINE_VALUE_HASH_KEYS ) {
    $formatted_value = join " ", sort keys %$attr_value;
    
  } elsif ( ($value_fmt == LINE_VALUE_AS_IS) || ($value_fmt == LINE_VALUE_STRING_HASH) ) {
    $formatted_value = $attr_value;
    
  } else {
    $self->error("$function_name: invalid value format ($value_fmt) (internal error)")    
  }

  # Quote value if necessary
  if ( ($line_fmt == LINE_FORMAT_PARAM) || ($line_fmt == LINE_FORMAT_ENVVAR) ) {
    if ( (($formatted_value =~ /\s+/) && ($formatted_value !~ /^".*"$/)) ||
         ($value_fmt == LINE_VALUE_BOOLEAN) ||
         ($formatted_value eq '') ) {
      $self->debug(2,"$function_name: quoting value '$formatted_value'");
      $formatted_value = '"' . $formatted_value . '"';
    }
  }
  
  $self->debug(2,"$function_name: formatted value >>>$formatted_value<<<");
  return $formatted_value;
}


=pod

=item formatConfigLine

This function formats a configuration line using keyword and value,
according to the line format requested. Values containing spaces are
quoted if the line format is not LINE_FORMAT_XRDCFG.

Arguments :
    keyword : line keyword
    value : keyword value (can be empty)
    line_fmt : line format (see LINE_FORMAT_xxx constants)

=cut

sub formatConfigLine {
  my $function_name = "formatConfigLine";
  my ($self, $keyword, $value, $line_fmt) = @_;

  unless ( $keyword ) {
    $self->error("$function_name: 'keyword' argument missing (internal error)");
    return 1;
  }
  unless ( defined($value) ) {
    $self->error("$function_name: 'value' argument missing (internal error)");
    return 1;
  }
  unless ( defined($line_fmt) ) {
    $self->error("$function_name: 'line_fmt' argument missing (internal error)");
    return 1;
  }

  my $config_line = "";

  if ( $line_fmt == LINE_FORMAT_PARAM ) {
    $config_line = "$keyword=$value";
  } elsif ( $line_fmt == LINE_FORMAT_ENVVAR ) {
    $config_line = "export $keyword=$value";
  } elsif ( $line_fmt == LINE_FORMAT_XRDCFG_SETENV ) {
    $config_line = "setenv $keyword = $value";
  } elsif ( $line_fmt == LINE_FORMAT_XRDCFG_SET ) {
    $config_line = "set $keyword = $value";
  } elsif ( $line_fmt == LINE_FORMAT_XRDCFG ) {
    $config_line = $keyword;
    $config_line .= " $value" if $value;
    # In trust (shift.conf) format, there should be only one blank between
    # tokens and no trailing spaces.
    $config_line =~ s/\s\s+/ /g;
    $config_line =~ s/\s+$//;
  } else {
    $self->error("$function_name: invalid line format ($line_fmt). Internal inconsistency.");
  }

  $self->debug(2,"$function_name: Configuration line : >>$config_line<<");
  return $config_line;
}


=pod

=item buildLinePattern

This function builds a pattern that will match an existing configuration line for
the configuration parameter specified. The pattern built takes into account the line format.
Every whitespace in the pattern (configuration parameter) are replaced by \s+.
If the line format is LINE_FORMAT_XRDCFG, no whitespace is
imposed at the end of the pattern, as these format can be used to write a configuration
directive as a keyword with no value.

Arguments :
    config_param: parameter to update
    line_fmt: line format (see LINE_FORMAT_xxx constants)
    config_value: when defined, make it part of the pattern (used when multiple lines
                  with the same keyword are allowed)

=cut

sub buildLinePattern {
  my $function_name = "buildLinePattern";
  my ($self, $config_param, $line_fmt, $config_value) = @_;

  unless ( $config_param ) {
    $self->error("$function_name: 'config_param' argument missing (internal error)");
    return undef;
  }
  unless ( defined($line_fmt) ) {
    $self->error("$function_name: 'line_fmt' argument missing (internal error)");
    return undef;
  }
  if ( defined($config_value ) ) {
    $self->debug(2,"$function_name: configuration value '$config_value' will be added to the pattern");
    $config_value =~ s/\\/\\\\/g;
    $config_value =~ s/([\-\+\?\.\*\[\]()\^\$])/\\$1/g;
    $config_value =~ s/\s+/\\s+/g;
  } else {
    $config_value = "";
  }

  # config_param is generally a keyword and in this case it contains no whitespace.
  # A special case is when config_param (the rule keyword) is used to match a line
  # without specifying a rule: in this case it may contains whitespaces. Remove strict
  # matching of them (match any type/number of whitespaces at the same position). 
  # Look at %trust_config_rules in ncm-dpmlfc Perl module for an example.
  $config_param =~ s/\s+/\\s+/g;

  my $config_param_pattern;
  if ( $line_fmt == LINE_FORMAT_PARAM ) {
    $config_param_pattern = "#?\\s*$config_param=".$config_value;
  } elsif ( $line_fmt == LINE_FORMAT_ENVVAR ) {
    $config_param_pattern = "#?\\s*export $config_param=".$config_value;
  } elsif ( $line_fmt == LINE_FORMAT_XRDCFG_SETENV ) {
    $config_param_pattern = "#?\\s*setenv\\s+$config_param\\s*=\\s*".$config_value;
  } elsif ( $line_fmt == LINE_FORMAT_XRDCFG_SET ) {
    $config_param_pattern = "#?\\s*set\\s+$config_param\\s*=\\s*".$config_value;
  } elsif ( $line_fmt == LINE_FORMAT_XRDCFG ) {
    $config_param_pattern = "#?\\s*$config_param";
    # Avoid adding a whitespace requirement if there is no config_value
    if ( $config_value ne "" ) {
      $config_param_pattern .= "\\s+" . $config_value;
    }
  } else {
    $self->error("$function_name: invalid line format ($line_fmt). Internal inconsistency.");
    return undef;
  }

  return $config_param_pattern
}


=pod

=item removeConfigLine

This function comments out a configuration line matching the configuration parameter.
Match operation takes into account the line format.

Arguments :
    fh : a FileEditor object
    config_param: parameter to update
    line_fmt : line format (see LINE_FORMAT_xxx constants)

=cut

sub removeConfigLine {
  my $function_name = "removeConfigLine";
  my ($self, $fh, $config_param, $line_fmt) = @_;

  unless ( $fh ) {
    $self->error("$function_name: 'fh' argument missing (internal error)");
    return 1;
  }
  unless ( $config_param ) {
    $self->error("$function_name: 'config_param' argument missing (internal error)");
    return 1;
  }
  unless ( defined($line_fmt) ) {
    $self->error("$function_name: 'line_fmt' argument missing (internal error)");
    return 1;
  }

  # Build a pattern to look for.
  my $config_param_pattern = $self->buildLinePattern($config_param,$line_fmt);

  $self->debug(1,"$function_name: commenting out lines matching pattern >>>".$config_param_pattern."<<<");
  # All matching lines must be commented out, except if they are already commented out.
  # The code used is a customized version of FileEditor::replace() that lacks support for backreferences
  # in the replacement value (here we want to rewrite the same line commented out but we don't know the
  # current line contents, only a regexp matching it).
  my @lns;
  my $line_count = 0;
  $fh->seek_begin();
  while (my $l = <$fh>) {
    if ($l =~ qr/^$config_param_pattern/ && $l !~ qr/^\s*#/) {
        $self->debug(2,"$function_name: commenting out matching line >>>".$l."<<<");
        $line_count++;
        push (@lns, '#'.$l);
    } else {
        push (@lns, $l);
    }
  }
  if ( $line_count == 0 ) {
    $self->debug(1, "$function_name: No line found matching the pattern");
  } else {
    $self->debug(1, "$function_name: $line_count lines commented out");
  }
  $fh->set_contents (join("", @lns));
 
}


=pod

=item updateConfigLine

This function do the actual update of a configuration line after doing the final
line formatting based on the line format.

Arguments :
    fh : a FileEditor object
    config_param: parameter to update
    config_value : parameter value (can be empty)
    line_fmt : line format (see LINE_FORMAT_xxx constants)
    multiple : if true, multiple lines with the same keyword can exist (D: false)

=cut

sub updateConfigLine {
  my $function_name = "updateConfigLine";
  my ($self, $fh, $config_param, $config_value, $line_fmt, $multiple) = @_;

  unless ( $fh ) {
    $self->error("$function_name: 'fh' argument missing (internal error)");
    return 1;
  }
  unless ( $config_param ) {
    $self->error("$function_name: 'config_param' argument missing (internal error)");
    return 1;
  }
  unless ( defined($config_value) ) {
    $self->error("$function_name: 'config_value' argument missing (internal error)");
    return 1;
  }
  unless ( defined($line_fmt) ) {
    $self->error("$function_name: 'line_fmt' argument missing (internal error)");
    return 1;
  }
  unless ( defined($multiple) ) {
    $multiple = 0;
  }

  my $newline;
  my $config_param_pattern;
  $newline = $self->formatConfigLine($config_param,$config_value,$line_fmt);

  # Build a pattern to look for.
  if ( $multiple ) {
    $self->debug(2,"$function_name: 'multiple' flag enabled");
    $config_param_pattern = $self->buildLinePattern($config_param,$line_fmt,$config_value);    
  } else {
    $config_param_pattern = $self->buildLinePattern($config_param,$line_fmt);
  }
  if ( ($line_fmt == LINE_FORMAT_XRDCFG) && !$multiple ) {
    if ( $config_value ) {
      $config_param_pattern .= "\\s+";    # If the value is defined in these formats, impose a whitespace at the end
    }
  }

  # Update the matching configuration lines
  if ( $newline ) {
    my $comment = "";
    if ( ($line_fmt == LINE_FORMAT_PARAM) || ($line_fmt == LINE_FORMAT_ENVVAR) ) {
      $comment = LINE_QUATTOR_COMMENT;
    }
    $self->debug(1,"$function_name: checking expected configuration line ($newline) with pattern >>>".$config_param_pattern."<<<");
    $fh->add_or_replace_lines(qr/^\s*$config_param_pattern/,
                              qr/^\s*$newline$/,
                              $newline.$comment."\n",
                              ENDING_OF_FILE,
                             );      
  }
}


=pod

=back

=head2 Public methods

=over

=item updateConfigfile

Update configuration file content,  applying configuration rules.

Arguments :
    file_name: name of the file to update
    config_rules: config rules corresponding to the file to build
    config_options: configuration parameters used to build actual configuration
    options: a hash setting options to modify the behaviour of this function

Supported entries for options hash:
    always_rules_only: if true, apply only rules with ALWAYS condition (D: false)
    remove_if_undef: if true, remove maatching configuration line is rule condition is not met (D: false)

=cut

sub updateConfigFile {
  my $function_name = "updateConfigFile";
  my ($self, $file_name, $config_rules, $config_options, $parser_options) = @_;

  unless ( $file_name ) {
    $self->error("$function_name: 'file_name' argument missing (internal error)");
    return 1;
  }
  unless ( $config_rules ) {
    $self->error("$function_name: 'config_rules' argument missing (internal error)");
    return 1;
  }
  unless ( $config_options ) {
    $self->error("$function_name: 'config_options' argument missing (internal error)");
    return 1;
  }
  unless ( defined($parser_options) ) {
    $self->debug(2,"$function_name: 'parser_options' undefined");
    $parser_options = {};
  }
  if ( defined($parser_options->{always_rules_only}) ) {
    $self->debug(1,"$function_name: 'always_rules_only' option set to ".$parser_options->{always_rules_only});
  } else {
    $self->debug(1,"$function_name: 'always_rules_only' option not defined: assuming ".LINE_OPT_DEF_ALWAYS_RULES_ONLY);
    $parser_options->{always_rules_only} = LINE_OPT_DEF_ALWAYS_RULES_ONLY;
  }
  if ( defined($parser_options->{remove_if_undef}) ) {
    $self->debug(1,"$function_name: 'remove_if_undef' option set to ".$parser_options->{remove_if_undef});
  } else {
    $self->debug(1,"$function_name: 'remove_if_undef' option not defined: assuming ".LINE_OPT_DEF_REMOVE_IF_UNDEF);
    $parser_options->{remove_if_undef} = LINE_OPT_DEF_REMOVE_IF_UNDEF;
  }

  my $fh = CAF::FileEditor->new($file_name,
                                backup => BACKUP_FILE_EXT,
                                log => $self);
  $fh->seek_begin();

  # Check that config file has an appropriate header
  my $intro_pattern = "# This file is managed by Quattor";
  my $intro = "# This file is managed by Quattor - DO NOT EDIT lines generated by Quattor";
  $fh->add_or_replace_lines(qr/^$intro_pattern/,
                            qr/^$intro$/,
                            $intro."\n#\n",
                            BEGINNING_OF_FILE,
                           );
  
  # Loop over all config rule entries.
  # Config rules are stored in a hash whose key is the variable to write
  # and whose value is the rule itself.
  # If the variable name start with a '-', this means that the matching configuration
  # line must be commented out unconditionally.
  # Each rule format is '[condition->]attribute:option_set[,option_set,...];line_fmt' where
  #     condition: either a role that must be enabled or ALWAYS if the rule must be applied 
  #                when 'always_rules_only' is true. A role is enabled if 'role_enabled' is
  #                true in the corresponding option set.
  #     option_set and attribute: attribute in option set that must be substituted
  #     line_fmt: the format to use when building the line
  # An empty rule is valid and means that the keyword part must be
  # written as is, using the line_fmt specified.
  
  my $rule_id = 0;
  foreach my $keyword (sort keys %{$config_rules}) {
    my $rule = $config_rules->{$keyword};
    $rule_id++;

    # Initialize remove_if_undef flag according the default for this file
    my $remove_if_undef = $parser_options->{remove_if_undef};

    # Check if the keyword is prefixed by:
    #     -  a '-': in this case the corresponding line must be unconditionally 
    #               commented out if it is present
    #     -  a '*': in this case the corresponding line must be commented out if
    #               it is present and the option is undefined
    my $comment_line = 0;
    if ( $keyword =~ /^-/ ) {
      $keyword =~ s/^-//;
      $comment_line = 1;
    } elsif ( $keyword =~ /^\?/ ) {
      $keyword =~ s/^\?//;
      $remove_if_undef = 1;
      $self->debug(2,"$function_name: 'remove_if_undef' option set for the current rule");
    }

    # Split different elements of the rule
    ($rule, my $line_fmt, my $value_fmt) = split /;/, $rule;
    unless ( $line_fmt ) {
      $line_fmt = LINE_FORMAT_DEFAULT;
    }
    my $value_opt;
    if ( $value_fmt ) {
      ($value_fmt, $value_opt) = split /:/, $value_fmt;
    }else {
      $value_fmt = LINE_VALUE_AS_IS;
    }
    unless ( defined($value_opt) ) {
      $value_opt = LINE_VALUE_OPT_NONE;      
    }

    (my $condition, my $tmp) = split /->/, $rule;
    if ( $tmp ) {
      $rule = $tmp;
    } else {
      $condition = "";
    }
    $self->debug(1,"$function_name: processing rule ".$rule_id."(variable=>>>".$keyword.
                      "<<<, comment_line=".$comment_line.", condition=>>>".$condition."<<<, rule=>>>".$rule."<<<, fmt=".$line_fmt.")");

    # Check if only rules with ALWAYS conditions must be applied 
    if ( $parser_options->{always_rules_only} ) {
      if ( $condition eq "ALWAYS" ) {
        $condition = '';
      } else {
        $self->debug(1,"$function_name: rule ignored (ALWAYS condition not set)");
        next;
      }
    }

    # If the keyword was "negated", remove (comment out) configuration line if present and enabled
    if ( $comment_line ) {
      $self->debug(1,"$function_name: keyword '$keyword' negated, removing configuration line");
      $self->removeConfigLine($fh,$keyword,$line_fmt);
      next;
    }

    # Check if rule condition is met if one is defined
    unless ( $condition eq "" ) {
      $self->debug(1,"$function_name: checking condition >>>$condition<<<");

      # Condition may be negated if it starts with a !
      my $negate = 0;
      if ( $condition =~ /^!/ ) {
        $negate = 1;
        $condition =~ s/^!//;
      }
      my ($cond_attribute,$cond_option_set) = split /:/, $condition;
      unless ( $cond_option_set ) {
        $cond_option_set = $cond_attribute;
        $cond_attribute = "";
      }
      $self->debug(2,"$function_name: condition option set = '$cond_option_set', ".
                         "condition attribute = '$cond_attribute', negate=$negate");
      my $cond_satisfied = 1;
      if ( $cond_attribute ) {
        # Due to an exists() flaw, testing directly exists($config_options->{$cond_option_set}->{$cond_attribute}) will spring
        # into existence $config_options->{$cond_option_set} if it doesn't exist.
        if ( $negate ) {
          $cond_satisfied = 0 if exists($config_options->{$cond_option_set}) && 
                                 exists($config_options->{$cond_option_set}->{$cond_attribute});          
        } else {          
          $cond_satisfied = 0 unless exists($config_options->{$cond_option_set}) &&
                                     exists($config_options->{$cond_option_set}->{$cond_attribute});
        }
      } elsif ( $cond_option_set ) {
        if ( $negate ) {
          $cond_satisfied = 0 if exists($config_options->{$cond_option_set});
        } else {         
          $cond_satisfied = 0 unless exists($config_options->{$cond_option_set});
        }
      }
      # Remove (comment out) configuration line if present and enabled
      # and if option remove_if_undef is set
      unless ( $cond_satisfied  || !$remove_if_undef ) {
        $self->debug(1,"$function_name: condition met but negated, removing configuration line");
        $self->removeConfigLine($fh,$keyword,$line_fmt);
        next;
      }
    }

    my @option_sets;
    (my $attribute, my $option_sets_str) = split /:/, $rule;
    if ( $option_sets_str ) {
      @option_sets = split /\s*,\s*/, $option_sets_str;
    }

    # Build the value to be substitued for each option set specified.
    # option_set=GLOBAL is a special case indicating a global option instead of an
    # attribute in a specific option set.
    my $config_value = "";
    my $attribute_present = 1;
    my $config_updated = 0;
    if ( $attribute ) {
      foreach my $option_set (@option_sets) {
        my $attr_value;
        if ( $option_set eq "GLOBAL" ) {
          if ( exists($config_options->{$attribute}) ) {
            $attr_value = $config_options->{$attribute};
          } else {
            $self->debug(1,"$function_name: attribute '$attribute' not found in global option set");
            $attribute_present = 0;
          }
        } else {
          # Due to an exists() flaw, testing directly exists($config_options->{$cond_option_set}->{$cond_attribute}) will spring
          # into existence $config_options->{$cond_option_set} if it doesn't exist.
          if ( exists($config_options->{$option_set}) && exists($config_options->{$option_set}->{$attribute}) ) {
            $attr_value = $config_options->{$option_set}->{$attribute};
          } else {
            $self->debug(1,"$function_name: attribute '$attribute' not found in option set '$option_set'");
            $attribute_present = 0;
          } 
        }

        # If attribute is not defined in the present configuration, check if there is a matching
        # line in the config file for the keyword and comment it out. This requires option 
        # remove_if_undef to be set.
        # Note that this will never match instance parameters and will not remove entries
        # no longer part of the configuration in a still existing LINE_VALUE_ARRAY or
        # LINE_VALUE_STRING_HASH.
        unless ( $attribute_present ) {
          if ( $remove_if_undef ) {
            $self->debug(1,"$function_name: attribute '$attribute' undefined, removing configuration line");
            $self->removeConfigLine($fh,$keyword,$line_fmt);
          }
          next;
        }
    
        # Instance parameters are specific, as this is a nlist of instance
        # with the value being a nlist of parameters for the instance.
        # Also the variable name must be updated to contain the instance name.
        # One configuration line must be written/updated for each instance.
        if ( $value_fmt == LINE_VALUE_INSTANCE_PARAMS ) {
          foreach my $instance (sort keys %{$attr_value}) {
            my $params = $attr_value->{$instance};
            $self->debug(1,"$function_name: formatting instance '$instance' parameters ($params)");
            $config_value = $self->formatAttributeValue($params,
                                                        $line_fmt,
                                                        $value_fmt,
                                                       );
            my $config_param = $keyword;
            my $instance_uc = uc($instance);
            $config_param =~ s/%%INSTANCE%%/$instance_uc/;
            $self->debug(2,"New variable name generated: >>>$config_param<<<");
            $self->updateConfigLine($fh,$config_param,$config_value,$line_fmt);
          }
          $config_updated = 1;
        } elsif ( $value_fmt == LINE_VALUE_STRING_HASH ) {
          # With this value format, several lines with the same keyword are generated,
          # one for each key/value pair.
          foreach my $k (sort keys %$attr_value) {
            my $v = $attr_value->{$k};
            # Value is made by joining key and value as a string
            # Keys may be escaped if they contain characters like '/': unescaping a non-escaped
            # string is generally harmless.
            my $tmp = unescape($k)." $v";
            $self->debug(1,"$function_name: formatting (string hash) attribute '$attribute' value ($tmp, value_fmt=$value_fmt)");
            $config_value = $self->formatAttributeValue($tmp,
                                                        $line_fmt,
                                                        $value_fmt,
                                                       );
            $self->updateConfigLine($fh,$keyword,$config_value,$line_fmt,1);
          }
          $config_updated = 1;
        } elsif ( ($value_fmt == LINE_VALUE_ARRAY) && ($value_opt == LINE_VALUE_OPT_SINGLE) ) {
          # With this value format, several lines with the same keyword are generated,
          # one for each array value (if value_opt is not LINE_VALUE_OPT_SINGLE, all
          # the values are concatenated on one line).
          foreach my $val (@$attr_value) {
            $self->debug(1,"$function_name: formatting (array) attribute '$attribute' value ($val, value_fmt=".LINE_VALUE_AS_IS.")");
            $config_value = $self->formatAttributeValue($val,
                                                        $line_fmt,
                                                        LINE_VALUE_AS_IS,
                                                       );
            $self->updateConfigLine($fh,$keyword,$config_value,$line_fmt,1);            
          }
          $config_updated = 1;
        } else {
          $self->debug(1,"$function_name: formatting attribute '$attribute' value ($attr_value, value_fmt=$value_fmt)");
          $config_value .= $self->formatAttributeValue($attr_value,
                                                       $line_fmt,
                                                       $value_fmt);
          $self->debug(2,"$function_name: adding attribute '".$attribute."' from option set '".$option_set.
                                                                "' to value (config_value=".$config_value.")");
        }
      }
    } else {
      # $attribute empty means an empty rule : in this case,just write the configuration param.
      $self->debug(1,"$function_name: no attribute specified in rule '$rule'");
    }

    # Instance parameters, string hashes have already been written
    if ( !$config_updated && $attribute_present ) {
      $self->updateConfigLine($fh,$keyword,$config_value,$line_fmt);
    }  
  }

  # Update configuration file if content has changed
  $self->debug(1,"$function_name: actually updating the file...");
  my $changes = $fh->close();

  return $changes;
}

=pod

=back

=cut

1;      # Required for PERL modules
