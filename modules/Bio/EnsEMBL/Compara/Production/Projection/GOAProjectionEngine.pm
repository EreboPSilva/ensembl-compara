#
# You may distribute this module under the same terms as perl itself
#

=pod

=head1 NAME

Bio::EnsEMBL::Compara::Production::Projection::GOAProjectionEngine

=head1 DESCRIPTION

This is an extension of the ProjectionEngine object which provides methods
for filtering according to rules discussed with the GOA team at the EBI.

=head1 FILTERS

=head2 DBEntry Filtering

DBEntry objects are filtered based on the following

=over 8

=item The DB name equals GO

=item DBEntry is defined and isa OntologyXref

=item The GO term has one of the following evidence tags; IDA IEP IGI IMP IPI

=back

=head2 Homology Filtering

Homology objects are filtered accordingly

=over 8

=item The description field is set to ortholog_one2one, 
      ortholog_one2many or ortholog_many2many
      
=item Percentage identity of both homologous pepetides is greater than 40%

=back

=cut

package Bio::EnsEMBL::Compara::Production::Projection::GOAProjectionEngine;

use strict;
use warnings;

use base qw( Bio::EnsEMBL::Compara::Production::Projection::ProjectionEngine );

use Bio::EnsEMBL::Utils::Scalar qw(assert_ref check_ref);
use Bio::EnsEMBL::Utils::Argument qw(rearrange);

use Bio::EnsEMBL::Compara::Production::Projection::FakeXrefHolder;

use Data::Predicate::ClosurePredicate;
use Data::Predicate::Predicates qw(:all);

=head2 new()

  Arg[-dbentry_types] : The DBEntry database name to use. Defaults to GO
  Description : New method used for a new instance of the given object. 
                Required fields are indicated accordingly. Fields are specified
                using the Arguments syntax (case insensitive).

=cut

sub new {
  my ( $class, @args ) = @_;
  my $self = $class->SUPER::new(@args);
  
  my ($dbentry_types) = rearrange([qw(dbentry_types)], @args);
  
  $dbentry_types = $self->_dbentry_types_builder() if ! defined $dbentry_types;
  assert_ref( $dbentry_types, 'ARRAY' );
  $self->{dbentry_types} = $dbentry_types;
  
  return $self;
}

=head2 dbentry_types()

  Description : Getter. Percentage identity in the source
  Can be customised by overriding C<_dbentry_types_builder>(). Defaults to
  an arrayref containing GO and PO by default.

=cut

sub dbentry_types {
  my ($self) = @_;
  return $self->{dbentry_types};
}

=head2 excluded_terms()

Used to remove terms from the projected items which are deemed as not-useful.
This defaults to GO:0005515 (protein binding)

=cut

sub excluded_terms {
  my ($self) = @_;
  return [qw(GO:0005515)];
}

=head2 dbentry_source_object()

Override of the method from the super engine which uses the FakeXrefHolder
object to get Xrefs quickly. The class returned responds to the
C<get_all_DBEntries()> subroutine call returning all of those Translation
based DBEntry objects.

=cut

sub dbentry_source_object {
  my ($self, $member) = @_;
  return Bio::EnsEMBL::Compara::Production::Projection::FakeXrefHolder->build_peptide_dbentries_from_Member($member);
}

###### BUILDERS

sub _dbentry_types_builder {
  my ($self) = @_;
  return ['GO'];
}

sub _homology_predicate_builder {
  my ($self) = @_;
  
  $self->log()->debug('Creating default Homology predicate');
  
  my @types = qw(ortholog_one2one ortholog_one2many ortholog_many2many);
  
  my $type_predicate = p_or(map { p_string_equals($_, 'description') } @types);
  
  my $percentage_identity_predicate = Data::Predicate::ClosurePredicate->new(closure => sub {
    my ($homology) = @_;
    my ($member_attribute_a, $member_attribute_b) = @{$homology->get_all_Member_Attribute()};
    return $member_attribute_a->[1]->perc_id() >= 40 && $member_attribute_b->[1]->perc_id() >= 40;
  }, description => 'Filtering of homology where both members had >= 40% identity');
  
  return p_and($type_predicate, $percentage_identity_predicate);
}

sub _dbentry_predicate_builder {
  my ($self) = @_;
  
  $self->log()->debug('Creating default DBEntry predicate');
  
  #Only accept if it is defined, was blessed, dbname == GO || PO & is a OntologyXref object
  my $entry_type_predicate = p_or(map { p_string_equals($_, 'dbname') } @{$self->dbentry_types()});
  my $correct_type_predicate = p_and(p_defined(), p_blessed(), $entry_type_predicate, p_isa('Bio::EnsEMBL::OntologyXref'));
  
  #Allowed linkage types; can be any of these so it's an OR
  #  IC Inferred by curator
  #  IDA Inferred from direct assay
  #  IEA Inferred from electronic annotation
  #  IGI Inferred from genetic interaction
  #  IMP Inferred from mutant phenotype
  #  IPI Inferred from physical interaction
  #  ISS Inferred from sequence or structural similarity
  #  NAS Non-traceable author statement
  #  ND No biological data available
  #  RCA Reviewed computational analysis
  #  TAS Traceable author statement
  # check the $_->type() method
  my $allowed_linkage_predicate = p_or(map { p_string_equals($_) } qw(IDA IEP IGI IMP IPI));
  
  #Quick closure predicate which asserts that all the linkage types from a DBEntry can be found
  my $dbentry_has_allowed_linkage_predicate = Data::Predicate::ClosurePredicate->new(closure => sub {
    my ($dbentry) = @_;
    return $allowed_linkage_predicate->all_true($dbentry->get_all_linkage_types());
  });
  
  #Filter the excluded terms (defaults to protein_binding GO:0005515)
  my $excluded_terms = $self->excluded_terms();
  my @excluded_terms_predicates = map { p_string_equals($_, 'primary_id') } @{$excluded_terms};
  my $go_term_removal_predicate = p_not(p_or(@excluded_terms_predicates));
  
  #Build it together & return
  return p_and($correct_type_predicate, $go_term_removal_predicate, $dbentry_has_allowed_linkage_predicate);
}

=pod

Override to provide more specific rules about allowing go xref transfer
based on evidence tags.

=cut

sub _transfer_dbentry_by_targets {
  my ($self, $source, $targets) = @_;
  
  my $source_ref = ref($source);
  
  my $link_join = sub {
    my ($xref) = @_;
    return join(q{}, sort @{$source->get_all_linkage_types()});
  };
  
  foreach my $target_xref (@{$targets}) {
    
    next unless check_ref($target_xref, $source_ref);
    
    #Reject if it was the same
    if ( $source->dbname() eq $target_xref->dbname() &&
	    $source->primary_id() eq $target_xref->primary_id() &&
	    $link_join->($source) eq $link_join->($target_xref)) {
      return 0;
    }

    # if a GO term with the same accession, but IEA evidence code, exists, also don't project, as this
    # will lead to duplicates when the projected term has its evidence code changed to IEA after projection
    if ($target_xref->primary_id() eq $target_xref->primary_id()) {
      foreach my $evidence_code (@{$target_xref->get_all_linkage_types()}) {
	     return 0 if ($evidence_code eq "IEA");
      }
    }
  }
}


1;