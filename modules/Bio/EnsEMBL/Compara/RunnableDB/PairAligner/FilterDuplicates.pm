=head1 LICENSE

  Copyright (c) 1999-2012 The European Bioinformatics Institute and
  Genome Research Limited.  All rights reserved.

  This software is distributed under a modified Apache license.
  For license details, please see

    http://www.ensembl.org/info/about/code_licence.html

=head1 CONTACT

  Please email comments or questions to the public Ensembl
  developers list at <dev@ensembl.org>.

  Questions may also be sent to the Ensembl help desk at
  <helpdesk@ensembl.org>.

=head1 NAME

Bio::EnsEMBL::Compara::RunnableDB::PairAligner::FilterDuplicates

=cut

=head1 SYNOPSIS

=cut

=head1 DESCRIPTION

This analysis/RunnableDB is designed to run after all GenomicAlignBlock entries for a 
specific MethodLinkSpeciesSet has been completed and filters out all duplicate entries
which can result from jobs being rerun or from regions of overlapping chunks generating
the same HSP hits.  It takes as input (on the input_id string) 

=cut

=head1 APPENDIX

The rest of the documentation details each of the object methods.
Internal methods are usually preceded with a _

=cut

package Bio::EnsEMBL::Compara::RunnableDB::PairAligner::FilterDuplicates;

use strict;
use Time::HiRes qw(time gettimeofday tv_interval);

use Bio::EnsEMBL::DBSQL::DBAdaptor;
use Bio::EnsEMBL::DBLoader;

use Bio::EnsEMBL::Compara::Production::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Compara::Production::DnaFragChunk;
use Bio::EnsEMBL::Compara::Production::DnaFragChunkSet;
use Bio::EnsEMBL::Compara::GenomicAlignBlock;

use Bio::EnsEMBL::Hive::DBSQL::AnalysisJobAdaptor;

use Bio::EnsEMBL::Analysis::RunnableDB;

use base ('Bio::EnsEMBL::Compara::RunnableDB::BaseRunnable');

=head2 fetch_input

    Title   :   fetch_input
    Usage   :   $self->fetch_input
    Function:   prepares global variables and DB connections
    Returns :   none
    Args    :   none

=cut

sub fetch_input {
  my( $self) = @_;

  unless (defined $self->param('window_size')) {
      $self->param('window_size',1000000);  
  }

  my $meta_container = $self->compara_dba->get_MetaContainer;

  #Read chunk_size from meta table
  unless (defined $self->param('chunk_size')) {
      my $key = "chunk_" . $self->param('method_link_species_set_id');
      my @option_list = $meta_container->list_value_by_key($key);
      my $option = $option_list[0][0];
      my $chunks = eval $option;
      $self->param('chunks', $chunks);

      #Awful hack for now to retrieve the correct chunk
      if ($self->analysis->logic_name() eq "query_filter_duplicates") {
	  $self->param('chunk_size', $chunks->{'ref'}{'chunk_size'});
	  $self->param('overlap', $chunks->{'ref'}{'overlap'});
      } else {
	  $self->param('chunk_size', $chunks->{'non_ref'}{'chunk_size'});
	  $self->param('overlap', $chunks->{'non_ref'}{'overlap'});
      }

  }

  throw("No dnafrag_id specified") unless defined($self->param('dnafrag_id'));
  throw("Window size (".$self->param('window_size').")must be > 0") if (!$self->param('window_size') or $self->param('window_size') <= 0);
  $self->print_params;

  $self->compara_dba->dbc->disconnect_when_inactive(0);
    
  return 1;
}


sub run
{
  my $self = shift;
  $self->filter_duplicates;
  return 1;
}


sub write_output 
{
  my $self = shift;

  my $output_id = $self->input_id;

  print("output_id = $output_id\n");
  #$self->input_id($output_id);
  return 1;
}


######################################
#
# subroutines
#
#####################################


sub print_params {
  my $self = shift;

  print(" params:\n");
  print("   method_link_species_set_id : ", $self->param('method_link_species_set_id'),"\n");
}


sub filter_duplicates {
  my $self = shift;

  my $overlap = $self->param('overlap');
  my $chunk_size = $self->param('chunk_size');
  my $window_size = $self->param('window_size');
  $self->param('overlap_count', 0);
  $self->param('identical_count', 0);
  $self->param('gab_count', 0);
  $self->param('truncate_count', 0);
  $self->param('not_truncate_count', 0);
  $self->param('delete_hash', {}); #all the genomic_align_blocks that need to be deleted

  my $mlss = $self->compara_dba->get_MethodLinkSpeciesSetAdaptor->fetch_by_dbID($self->param('method_link_species_set_id'));
#  my ($gdb1, $gdb2) = @{$mlss->species_set};
#  if($gdb1->dbID > $gdb2->dbID) {
#    my $tmp = $gdb1; $gdb1=$gdb2; $gdb2=$tmp;
#  }

  my $GAB_DBA = $self->compara_dba->get_GenomicAlignBlockAdaptor;
  # create a list of dnafrag here in case we want to make this runnable working with an input_id 
  # containing a list of dnafrag_ids
  my $dnafrag_list = [$self->compara_dba->get_DnaFragAdaptor->fetch_by_dbID($self->param('dnafrag_id'))];

  foreach my $dnafrag (@{$dnafrag_list}) {
    my $seq_region_start = $self->param('seq_region_start');
    $seq_region_start = 1 unless (defined $seq_region_start);
    #printf("dnafrag (%d)%s:%s len=%d\n", $dnafrag->dbID, $dnafrag->coord_system_name, $dnafrag->name, $dnafrag->length);
    my $seq_region_end = $self->param('seq_region_end');
    $seq_region_end = $dnafrag->length unless (defined $seq_region_end);

    if ($dnafrag->is_reference) {
	#find identical matches over all the dnafrag
	$self->find_identical_matches($seq_region_start, $seq_region_end, $window_size, $mlss, $dnafrag);
	
	#find edge artefacts only in the overlap regions
	if (defined $overlap && $overlap > 0) {
	    $self->find_edge_artefacts($seq_region_start, $seq_region_end, $overlap, $chunk_size, $mlss, $dnafrag);
	}
    } else {
	#get correct start and end if non_reference eg haplotype. 
	#NB cannot overwrite by defining seq_region_start and seq_region_end
	if (!$dnafrag->is_reference) {
	    my $slice_adaptor = $dnafrag->genome_db->db_adaptor->get_SliceAdaptor;
	    my $slices = $slice_adaptor->fetch_by_region_unique($dnafrag->coord_system_name, $dnafrag->name);
	    foreach my $slice (@$slices) {
		my $seq_region_start = $slice->start;
		my $seq_region_end = $slice->end;

		#find identical matches over all the dnafrag
		$self->find_identical_matches($seq_region_start, $seq_region_end, $window_size, $mlss, $dnafrag);
		
		#find edge artefacts only in the overlap regions
		if (defined $overlap && $overlap > 0) {
		    $self->find_edge_artefacts($seq_region_start, $seq_region_end, $overlap, $chunk_size, $mlss, $dnafrag);
		}
	    }
	}
    }
    
  }

  my @del_list = values(%{$self->param('delete_hash')});

  my $sql_ga = "delete ignore from genomic_align where genomic_align_id in ";
  my $sql_gab = "delete ignore from genomic_align_block where genomic_align_block_id in ";

  for (my $i=0; $i < scalar @del_list; $i=$i+1000) {
      my (@gab_ids, @ga_ids);
      for (my $j = $i; ($j < scalar @del_list && $j < $i+1000); $j++) {
	  my $gab = $del_list[$j];
	  push @gab_ids, $gab->dbID;
	  foreach my $ga (@{$gab->genomic_align_array}) {
	      push @ga_ids, $ga->dbID;
	  }
      }
      my $sql_gab_to_exec = $sql_gab . "(" . join(",", @gab_ids) . ")";
      my $sql_ga_to_exec = $sql_ga . "(" . join(",", @ga_ids) . ")";
      
      foreach my $sql ($sql_ga_to_exec,$sql_gab_to_exec) {
 	  my $sth = $self->compara_dba->dbc->prepare($sql);
 	  $sth->execute;
 	  $sth->finish;
       }
  }

#   foreach my $gab (@del_list) {
#     #print("DELETE "); print_gab($gab);
#     foreach my $ga (@{$gab->genomic_align_array}) {
#       $sth_genomic_align_group->execute($ga->dbID);
#       $sth_genomic_align->execute($ga->dbID);
#     }
#     $sth_genomic_align_block->execute($gab->dbID);
#   }

#   $sth_genomic_align_group->finish;
#   $sth_genomic_align->finish;
#   $sth_genomic_align_block->finish;

  printf("%d gabs to delete\n", scalar(keys(%{$self->param('delete_hash')})));
  printf("found %d equal GAB pairs\n", $self->param('identical_count'));
  printf("found %d overlapping GABs\n", $self->param('overlap_count'));
  printf("%d GABs loadled\n", $self->param('gab_count'));
  printf("%d TRUNCATE gabs\n", $self->param('truncate_count'));
  printf("%d not TRUNCATE gabs\n", $self->param('not_truncate_count'));
}

#Remove identical matches over all the dnafrag to remove matches either from 
#overlaps or because a job has been run more than once
sub find_identical_matches {
    my ($self, $region_start, $seq_region_end, $window_size, $mlss, $dnafrag) = @_;

    my $GAB_DBA = $self->compara_dba->get_GenomicAlignBlockAdaptor;

    while($region_start <= $seq_region_end) {
	my  $region_end = $region_start + $window_size;

	my $genomic_align_block_list = $GAB_DBA->fetch_all_by_MethodLinkSpeciesSet_DnaFrag
	  ($mlss, $dnafrag, $region_start, $region_end);
	
	printf STDERR "IDENTICAL MATCHES: dnafrag %s %s %d:%d has %d GABs\n", $dnafrag->coord_system_name, $dnafrag->name, 
	      $region_start, $region_end, scalar(@$genomic_align_block_list);

	if ($self->debug) {
	    foreach my $gab (@{$genomic_align_block_list}) {
		$self->assign_jobID_to_genomic_align_block($gab);
	    }
	}

	my $sort_time = time();
	# first sort the list for processing
	my @sorted_GABs = sort sort_alignments @$genomic_align_block_list;
	$self->param('gab_count', $self->param('gap_count')+scalar(@sorted_GABs));
	
	# remove all the equal duplicates from the list
	$self->removed_equals_from_genomic_align_block_list(\@sorted_GABs);
	
        $region_start = $region_end;
    }
}

#Remove matches spanning the overlap using "in_chunk_overlap" mode which 
#checks just the region of the overlap and not the whole dnafrag
sub find_edge_artefacts {
    my ($self, $region_start, $seq_region_end, $overlap, $chunk_size, $mlss, $dnafrag) = @_;

    my $GAB_DBA = $self->compara_dba->get_GenomicAlignBlockAdaptor;

    $region_start += $chunk_size - $overlap;
    while($region_start <= $seq_region_end) {
       my $region_end = $region_start + $overlap - 1;

       my $genomic_align_block_list = $GAB_DBA->fetch_all_by_MethodLinkSpeciesSet_DnaFrag
        ($mlss, $dnafrag, $region_start, $region_end);
       
       printf STDERR "EDGE ARTEFACTS: dnafrag %s %s %d:%d has %d GABs\n", $dnafrag->coord_system_name, $dnafrag->name, $region_start, $region_end, scalar(@$genomic_align_block_list);
       
       if ($self->debug) {
	   foreach my $gab (@{$genomic_align_block_list}) {
	       $self->assign_jobID_to_genomic_align_block($gab);
	   }
       }

       # first sort the list for processing
       my @sorted_GABs = sort sort_alignments @$genomic_align_block_list;
       $self->param('gab_count', $self->param('gab_count')+scalar(@sorted_GABs));

       # now process remaining list (still sorted) for overlaps
       $self->remove_edge_artifacts_from_genomic_align_block_list(\@sorted_GABs, $region_start, $region_end);
       
        $region_start += $chunk_size - $overlap;
    }

}

sub sort_alignments{
  # $a,$b are GenomicAlignBlock objects
  my $a_ref = $a->reference_genomic_align;
  my ($a_other) = @{$a->get_all_non_reference_genomic_aligns};
  my $b_ref = $b->reference_genomic_align;
  my ($b_other) = @{$b->get_all_non_reference_genomic_aligns};

  return 
    ($a_other->dnafrag_id <=> $b_other->dnafrag_id) ||
    ($a_ref->dnafrag_strand <=> $b_ref->dnafrag_strand) ||
    ($a_other->dnafrag_strand <=> $b_other->dnafrag_strand) ||
    ($a_ref->dnafrag_start <=> $b_ref->dnafrag_start) ||
    ($a_ref->dnafrag_end <=> $b_ref->dnafrag_end) ||
    ($a_other->dnafrag_start <=> $b_other->dnafrag_start) ||
    ($a_other->dnafrag_end <=> $b_other->dnafrag_end) ||
    ($a->score <=> $b->score) ||
    ($a->dbID <=> $b->dbID);
}


sub assign_jobID_to_genomic_align_block {
  my $self = shift;
  my $gab = shift;

  my $sql = "SELECT analysis_job_id FROM genomic_align_block_job_track ".
                  "WHERE genomic_align_block_id=?";
  my $sth = $self->compara_dba->prepare($sql);
  $sth->execute($gab->dbID);
  my ($job_id) = $sth->fetchrow_array();
  $sth->finish;
  $gab->{'analysis_job_id'} = $job_id;
}


sub remove_deletes_from_list {
  my $self = shift;
  my $genomic_align_block_list = shift;

  my @new_list;  
  foreach my $gab (@$genomic_align_block_list) {
    push @new_list, $gab unless($self->param('delete_hash')->{$gab->dbID});
  }
  @$genomic_align_block_list = @new_list;
  return $genomic_align_block_list; 
}


sub removed_equals_from_genomic_align_block_list {
  my $self = shift;
  my $genomic_align_block_list = shift;
  my $region_start = shift;
  my $region_end = shift;
  
  return unless(scalar(@$genomic_align_block_list));
  if($self->debug > 2) {
    for(my $index=0; $index<(scalar(@$genomic_align_block_list)); $index++) {
      my $gab1 = $genomic_align_block_list->[$index];
      print_gab($gab1);
    }
  }
  for(my $index=0; $index<(scalar(@$genomic_align_block_list)); $index++) {
    my $gab1 = $genomic_align_block_list->[$index];
    next if($self->param('delete_hash')->{$gab1->dbID}); #already deleted so skip it
    
    for(my $index2=$index+1; $index2<(scalar(@$genomic_align_block_list)); $index2++) {
      my $gab2 = $genomic_align_block_list->[$index2];
      last if($gab2->reference_genomic_align->dnafrag_start > 
              $gab1->reference_genomic_align->dnafrag_start);

      next if($self->param('delete_hash')->{$gab2->dbID}); #already deleted so skip it

      if(genomic_align_blocks_identical($gab1, $gab2)) {
        if ($self->debug) {
          if($gab1->{'analysis_job_id'} == $gab2->{'analysis_job_id'}) {
            printf("WARNING!!!!!! identical GABs dbID:%d,%d  SAME JOB:%d,%d\n", 
                   $gab1->dbID, $gab2->dbID, 
                   $gab1->{'analysis_job_id'},$gab2->{'analysis_job_id'},);
            print("  "); print_gab($gab1);
            print("  "); print_gab($gab2);
          }
        }
        if($gab1->dbID < $gab2->dbID) {
          $self->param('delete_hash')->{$gab2->dbID} = $gab2;
        } else {
          $self->param('delete_hash')->{$gab1->dbID} = $gab1;
        }
        $self->param('identical_count', $self->param('identical_count')+1);        
        
        if($self->debug > 1) {
          if($gab1->{'analysis_job_id'} == $gab2->{'analysis_job_id'}) {
            printf("  EQUAL - SAME JOB (gab_ids %d %d) (jobs %d,%d)\n", 
                 $gab1->dbID, $gab2->dbID, 
                 $gab1->{'analysis_job_id'},$gab2->{'analysis_job_id'},);         
          }
          else {
            printf("  EQUAL - DIFFERENT JOB (gab_ids %d %d) (jobs %d,%d)\n",
                 $gab1->dbID, $gab2->dbID, 
                 $gab1->{'analysis_job_id'},$gab2->{'analysis_job_id'},);         
          }
          print("      "); print_gab($gab1);
          print("  del "); print_gab($gab2);
        }
      }
    }
  }

  $self->remove_deletes_from_list($genomic_align_block_list);
}


sub remove_edge_artifacts_from_genomic_align_block_list {
  my $self = shift;
  my $genomic_align_block_list = shift;
  my $region_start = shift;
  my $region_end = shift;
  
  return unless(scalar(@$genomic_align_block_list));
  
  for(my $index=0; $index<(scalar(@$genomic_align_block_list)); $index++) {
    my $gab1 = $genomic_align_block_list->[$index];
    next if($self->param('delete_hash')->{$gab1->dbID}); #already deleted so skip it

    for(my $index2=$index+1; $index2<(scalar(@$genomic_align_block_list)); $index2++) {
      my $gab2 = $genomic_align_block_list->[$index2];
      last if($gab2->reference_genomic_align->dnafrag_start > 
              $gab1->reference_genomic_align->dnafrag_end);
      next if($self->param('delete_hash')->{$gab2->dbID}); #already deleted so skip it

      if(genomic_align_blocks_overlap($gab1, $gab2)) {
        $self->param('overlap_count', $self->param('overlap_count')+1);

        unless($self->process_overlap_for_chunk_edge_truncation($gab1, $gab2, $region_start, $region_end)) {
          if($self->debug) {
            if($gab1->{'analysis_job_id'} == $gab2->{'analysis_job_id'}) {
              printf("SAME JOB overlaping GABs %d %d\n", $gab1->dbID, $gab2->dbID);
            }
            else {
              printf("DIFFERENT JOB overlaping GABs %d %d\n", $gab1->dbID, $gab2->dbID);
            }
            print("  "); print_gab($gab1);
            print("  "); print_gab($gab2);
          }
        }
      } 
    }
  }
  #printf("found %d identical, %d overlapping GABs\n", $self->param('identical_count'), $self->param('overlap_count'));  

  $self->remove_deletes_from_list($genomic_align_block_list);
}


sub print_gab {
  my $gab = shift;
  
  my ($gab_1, $gab_2) = @{$gab->genomic_align_array};
  printf(" id(%d)  %s:(%d)%d-%d    %s:(%d)%d-%d  score=%d\n", 
         $gab->dbID,
         $gab_1->dnafrag->name, $gab_1->dnafrag_strand, $gab_1->dnafrag_start, $gab_1->dnafrag_end,
         $gab_2->dnafrag->name, $gab_2->dnafrag_strand, $gab_2->dnafrag_start, $gab_2->dnafrag_end,
         $gab->score);
}


sub genomic_align_blocks_identical {
  my ($gab1, $gab2) = @_;
  
  my ($gab1_1, $gab1_2) = sort {$a->dnafrag_id <=> $b->dnafrag_id} @{$gab1->genomic_align_array};
  my ($gab2_1, $gab2_2) = sort {$a->dnafrag_id <=> $b->dnafrag_id} @{$gab2->genomic_align_array};

  return 0 if(($gab1_1->dnafrag_id != $gab2_1->dnafrag_id) or ($gab1_2->dnafrag_id != $gab2_2->dnafrag_id));
  return 0 if(($gab1_1->dnafrag_strand != $gab2_1->dnafrag_strand) or ($gab1_2->dnafrag_strand != $gab2_2->dnafrag_strand));

  return 0 if(($gab1_1->dnafrag_start != $gab2_1->dnafrag_start) or ($gab1_1->dnafrag_end != $gab2_1->dnafrag_end));  
  return 0 if(($gab1_2->dnafrag_start != $gab2_2->dnafrag_start) or ($gab1_2->dnafrag_end != $gab2_2->dnafrag_end));  

  return 0 if($gab1->score != $gab2->score);

  return 0 if($gab1_1->cigar_line ne $gab2_1->cigar_line);  
  return 0 if($gab1_2->cigar_line ne $gab2_2->cigar_line);
  
  return 1;
}


sub genomic_align_blocks_overlap {
  my ($gab1, $gab2) = @_;
  
  my ($gab1_1, $gab1_2) = sort {$a->dnafrag_id <=> $b->dnafrag_id} @{$gab1->genomic_align_array};
  my ($gab2_1, $gab2_2) = sort {$a->dnafrag_id <=> $b->dnafrag_id} @{$gab2->genomic_align_array};
  
  return 0 if(($gab1_1->dnafrag_id != $gab2_1->dnafrag_id) or ($gab1_2->dnafrag_id != $gab2_2->dnafrag_id));
  return 0 if(($gab1_1->dnafrag_strand != $gab2_1->dnafrag_strand) or ($gab1_2->dnafrag_strand != $gab2_2->dnafrag_strand));

  return 0 if(($gab1_1->dnafrag_end < $gab2_1->dnafrag_start) or ($gab1_1->dnafrag_start > $gab2_1->dnafrag_end));  
  return 0 if(($gab1_2->dnafrag_end < $gab2_2->dnafrag_start) or ($gab1_2->dnafrag_start > $gab2_2->dnafrag_end));  
  
  return 1;
}


sub process_overlap_for_chunk_edge_truncation {
  my ($self, $gab1, $gab2, $region_start, $region_end) = @_;
   
  my $aligns_1_1 = $gab1->reference_genomic_align;
  my $aligns_1_2 = $gab1->get_all_non_reference_genomic_aligns->[0];
  my $aligns_2_1 = $gab2->reference_genomic_align;
  my $aligns_2_2 = $gab2->get_all_non_reference_genomic_aligns->[0];
    
  #first test if this overlapping pair is such that one of them crosses
  #one of the region boundaries and the other one does not
  #Processings is done such that we walk through the overlap regions of 
  #one genome, which in the GAB is the 'reference' so only need to test the
  #reference for region_edge artifacts.
  #IF both genomes are chunked and overlapped, then this needs to be run twice
  #1) with genome1 on the genome1 chunking regions
  #2) with genome2 on the genome2 chunking regions
  return undef 
    unless((($aligns_1_1->dnafrag_start < $region_start) and
            ($aligns_2_1->dnafrag_start >= $region_start))
           or
           (($aligns_1_1->dnafrag_start >= $region_start) and
            ($aligns_2_1->dnafrag_start < $region_start))
           or
           (($aligns_1_1->dnafrag_end > $region_end) and
            ($aligns_2_1->dnafrag_end <= $region_end))
           or
           (($aligns_1_1->dnafrag_end <= $region_end) and
            ($aligns_2_1->dnafrag_end > $region_end)));
            

  if(
      (($aligns_1_1->dnafrag_strand == $aligns_1_2->dnafrag_strand)
        and(
          (($aligns_1_1->dnafrag_start == $aligns_2_1->dnafrag_start) and 
           ($aligns_1_2->dnafrag_start == $aligns_2_2->dnafrag_start)) 
          or
          (($aligns_1_1->dnafrag_end   == $aligns_2_1->dnafrag_end) and 
           ($aligns_1_2->dnafrag_end   == $aligns_2_2->dnafrag_end))
        )
      ) 
      or
      (($aligns_1_1->dnafrag_strand != $aligns_1_2->dnafrag_strand)
        and(
          (($aligns_1_1->dnafrag_start == $aligns_2_1->dnafrag_start) and 
           ($aligns_1_2->dnafrag_end   == $aligns_2_2->dnafrag_end)) 
          or
          (($aligns_1_1->dnafrag_end   == $aligns_2_1->dnafrag_end) and 
           ($aligns_1_2->dnafrag_start == $aligns_2_2->dnafrag_start))
        )
      ) 
    )   
  {
    if($gab1->score > $gab2->score) {
      $self->param('delete_hash')->{$gab2->dbID} = $gab2;
    } else {
      $self->param('delete_hash')->{$gab1->dbID} = $gab1;
    }
    $self->param('truncate_count', $self->param('truncate_count')+1);  
    if ($self->debug) {
      if($gab1->{'analysis_job_id'} == $gab2->{'analysis_job_id'}) {
        printf("TRUNCATE GABs %d %d\n", $gab2->dbID, $gab1->dbID);
        if($self->param('delete_hash')->{$gab1->dbID}) { print("  DEL ");} else{ print("      ");}
        print_gab($gab1);
        if($self->param('delete_hash')->{$gab2->dbID}) { print("  DEL ");} else{ print("      ");}
        print_gab($gab2);
      } 
    }
  }
  else {
    $self->param('not_truncate_count', $self->param('not_truncate_count')+1);
    if ($self->debug) {
      if($gab1->{'analysis_job_id'} == $gab2->{'analysis_job_id'}) {
        printf("overlaping GABs %d %d - not truncate\n", $gab2->dbID, $gab1->dbID);
        print("      "); print_gab($gab1);
        print("      "); print_gab($gab2);
      }
    }
  }
}

1;
