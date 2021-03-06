package PrepareGenome;
use strict; 
use Cwd qw/abs_path/;
use File::Basename;
use File::Path qw/make_path remove_tree/;
use Common; 
use Location; 
use Data::Dumper;
use Seq;
use Gff;
use Gtb;
use Log::Log4perl;
use List::Util qw/min max sum/;

use vars qw/$VERSION @ISA @EXPORT @EXPORT_OK/;
require Exporter;
@ISA = qw/Exporter/;
@EXPORT_OK = qw//;
@EXPORT = qw/pipe_pre_processing/; 

sub get_orf_genome {
  my ($fi, $fo, $cutoff_missing, $sep) = @_;
  my $seqHI = Bio::SeqIO->new(-file=>"<$fi", -format=>'fasta');
  my $seqHO = Bio::SeqIO->new(-file=>">$fo", -format=>'fasta');
  $cutoff_missing ||= 0.5;
  $sep ||= "|";
  
  my $log = Log::Log4perl->get_logger("PrepareGenome");
  $log->info("extracting ORFs from translated genomic sequence");
  while(my $seq = $seqHI->next_seq()) {
    my $seqStr = $seq->seq;
    my ($id, $beg, $end, $srd) = ($seq->id, 1, 3*length($seqStr), "+");
    if($seq->id =~ /^(\S+)\Q$sep\E(\d+)\Q$sep\E(\d+)\Q$sep\E([\+\-])$/) {
      ($id, $beg, $end, $srd) = ($1, $2, $3, $4);
    }
    while( $seqStr =~ /([^\*]{15,})/g ) {
      my ($begL, $endL) = ($-[1]+1, $+[1]);
      my ($begG, $endG);
      if($srd eq "-") {
        $begG = $end - $endL*3 + 1;
        $endG = $end - ($begL*3-2) + 1;
      } else {
        $begG = $beg + ($begL*3-2) - 1;
        $endG = $beg + $endL*3 - 1;
      }
      my $sseq = $1;
      my $sid = join($sep, $id, "$begG-$endG", $srd, "x");
      my $n_x =()= $1 =~ /X/gi;
      if($n_x / ($endL-$begL+1) <= $cutoff_missing) {
        $seqHO->write_seq(Bio::Seq->new(-id=>$sid, -seq=>$sseq));
      }
    }
  }
  $seqHI->close();
  $seqHO->close();
}
sub get_orf_proteome {
  my ($f_gtb, $fo, $f_seq, $sep) = @_;
  my $t = readTable(-in => $f_gtb, -header => 1);
  my $seqHO = Bio::SeqIO->new(-file=>">$fo", -format=>'fasta');
  $sep ||= "|";
  
  my $log = Log::Log4perl->get_logger("PrepareGenome");
  $log->info("extracting ORFs from predicted protein sequence");

  my $h = {};
  for my $i (0..$t->nofRow-1) {
    my ($idM, $idG, $chr, $beg, $end, $srd, $phaseS, $locS, $cat1, $cat2) = 
      map {$t->elm($i, $_)} qw/id par chr beg end srd phase cloc cat1 cat2/;
    $cat1 eq "mRNA" || next;
    die "no locCDS for $idM\n" unless $locS;
    my $rloc = locStr2Ary($locS);
    my $loc = $srd eq "+" ? 
      [ map {[$beg+$_->[0]-1, $beg+$_->[1]-1]} @$rloc ]
      : [ map {[$end-$_->[1]+1, $end-$_->[0]+1]} @$rloc ];
    
    $phaseS ne "" || die "$idM: no phase\n"; 
    $loc = cropLoc_cds($loc, $srd, $phaseS);
    my $id = join($sep, $chr, locAry2Str($loc), $srd, "p");
    next if exists $h->{$id};
    $h->{$id} = 1;

    my $seqStr = seqRet($loc, $chr, $srd, $f_seq);
    my $seq_cds = Bio::Seq->new(-id=>$id, -seq=>$seqStr);
    my $seq_pro = $seq_cds->translate();
    $seqHO->write_seq($seq_pro);
#    printf "  %5d / %5d done\n", $i+1, $t->nofRow if ($i+1) % 1000 == 0;
  }
  $seqHO->close();
}

sub pipe_pre_processing {
  my ($dir) = @_;
  $dir = abs_path($dir);
  -d $dir || make_path($dir);
  chdir $dir || die "cannot chdir to $dir\n";
  
  my $dirfas = dirname($ENV{'SPADA_FAS'});
  my $dirgff = dirname($ENV{'SPADA_GFF'});

  my $log = Log::Log4perl->get_logger("PrepareGenome");
  $log->error_die("Genome Seq file not there: $ENV{'SPADA_FAS'}") unless -s $ENV{"SPADA_FAS"};
  $log->info("#####  Stage 1 [Pre-processing]  #####");
  my $fn;

  $fn = "01_refseq.fas";
  if("$dir/01_refseq.fas" eq $ENV{"SPADA_FAS"}) {
    $log->info("already generated: $fn");
  } else {
    $log->info("creating symlink to: $fn");
    runCmd("rm -rf $fn", 0); 
    runCmd("ln -sf $ENV{'SPADA_FAS'} $fn", 0);
  }
  system("rm -rf $fn.index") if -s "$fn.index";
  
  $fn = "12_orf_genome.fas";
  if($dir eq $dirfas && -s $fn) {
    $log->info("already generated: $fn");
  } elsif(-s "$dirfas/$fn") {
    $log->info("creating symlink to: $fn");
    runCmd("rm -rf $fn", 0); 
    runCmd("ln -sf $dirfas/$fn $fn", 0);
  } else {
    translate6("01_refseq.fas", "11_refseq_trans6.fas");
    get_orf_genome("11_refseq_trans6.fas", $fn);
  } 

  if(!exists $ENV{"SPADA_GFF"}) {
    return 1;
  } elsif(! -s $ENV{"SPADA_GFF"}) {
    $log->warn("Annotation GFF not there: $ENV{'SPADA_GFF'}");
    $log->warn("Proceeding without GFF");
    return 1;
  } 
  
  $fn = "51_gene.gff";
  if($dir eq $dirgff && -s $fn) {
    $log->info("already generated: $fn");
  } else {
    $log->info("creating symlink to: $fn");
    runCmd("rm -rf $fn", 0); 
    runCmd("ln -sf $ENV{'SPADA_GFF'} $fn", 0);
  }
 
  $fn = "71_orf_proteome.fas";
  if($dir eq $dirgff && -s $fn) {
    $log->info("already generated: $fn");
  } elsif(-s "$dirgff/$fn") {
    $log->info("creating symlink to: $fn");
    runCmd("rm -rf $fn", 0); 
    runCmd("ln -sf $dirgff/$fn $fn", 0);
  } else {
    runCmd("gff2gtb.pl -i 51_gene.gff -o 61_gene.gtb", 1);
    runCmd("gtb2gff.pl -i 61_gene.gtb -o 62_gene.gff", 1);
    get_orf_proteome("61_gene.gtb", $fn, "01_refseq.fas");
  } 
}


1;
__END__
