#!/opt/bin/perl

use strict;
use Getopt::Long qw(GetOptions);
use FindBin qw($Bin); 

#### new casava splits fastqs into batches of 4m reads
### this will process each fastq
### and create a single bam
### that can go trhough the second half of pipeline

### takes in a file that list of gzipped read pairs
## e.g.LID46438_NoIndex_L001_R1_001.fastq.gz
##     LID46438_NoIndex_L001_R1_002.fastq.gz
##     LID46438_NoIndex_L001_R1_003.fastq.gz
##     LID46438_NoIndex_L001_R1_004.fastq.gz

### '@RG\tID:TEST_SFT20_SE\tPL:Illumina\tPU:TEST_SFT20\tLB:TEST_SFT20\tSM:20'

my ($file, $readgroup, $pre, $species, $run, $config);
$pre = 'TEMP';
GetOptions ('file=s' => \$file,
	    'pre=s' => \$pre,
	    'species=s' => \$species,
	    'run=s' => \$run,
	    'config=s' => \$config,
	    'readgroup=s' => \$readgroup);


my @bams = ();
my $count = 0;

my $uID = `/usr/bin/id -u -n`;
chomp $uID;

my $bwaDB = '';
my $knownSites = '';
my $refSeq = '';

if($species =~/hg19/){
    $starDB = '/ifs/data/bio/assemblies/H.sapiens/hg19/star';
    $refSeq = '/ifs/data/bio/assemblies/H.sapiens/hg19/hg19.fasta';
}
elsif($species =~ /mm9/){
    $starDB = '/ifs/data/bio/assemblies/M.musculus/mm9/star';
    $refSeq = '/ifs/data/bio/assemblies/M.musculus/mm9/mm9.fasta';
}
elsif($species =~ /human-mouse|mouse-human|hybrid/){
    $starDB = '/ifs/data/mpirun/genomes/human/hg19_mm9_hybrid/star';
    $refSeq = '/ifs/data/mpirun/genomes/human/hg19_mm9_hybrid/hg19_mm9_hybrid.fasta';
}
else{
    die "SPECIES $species ISN'T CURRENTLY SUPPORTED; ONLY SUPPORT FOR hg19 and mm9 and human-mouse hybrid (hybrid)\n";
}

my $PICARD = '/opt/bin/picard';
my $STAR = '/opt/bin/star';
open(CONFIG, "$config") or warn "CAN'T OPEN CONFIG FILE $config SO USING DEFAULT SETTINGS $!";
while(<CONFIG>){
    chomp;

    my @conf = split(/\s+/, $_);
    if($conf[0] =~ /cutadapt/i){
	$CUTADAPT = $conf[1];
    }
    elsif($conf[0] =~ /star/i){
	$STAR = $conf[1];
    }
    elsif($conf[0] =~ /picard/i){
	$PICARD = $conf[1];
    }
}
close CONFIG;

open(IN, "$file") or die "Can't open $file file listing fastqs $!";
open(MISS, ">$file\_MISSING_READS.txt") or die "Can't write $file\_MISSING_READS.txt file listing fastqs $!";
while (<IN>){
    chomp;

    my @data = split(/\s+/, $_);
    my @nameR1 = split(/\.gz/, $data[0]);
    $count++;
    
    `mkdir $count`;
        
    `/common/sge/bin/lx24-amd64/qsub -P ngs -N $pre\_$uID\_ZCAT_$nameR1[0] $Bin/qCMD /bin/zcat $data[0] ">$count/$nameR1[0]"`;

    sleep(5);

    `$Bin/qSYNC $pre\_$uID\_ZCAT_$nameR1[0]`;

    ### skipping empty fastq files
    if(!-s "$count/$nameR1[0]"){
	print MISS "$count/$nameR1[0] is empty\n";
	next;
    }	    	    
	
    `/common/sge/bin/lx24-amd64/qsub -P ngs -N $pre\_$uID\_STAR_$nameR1[0] -hold_jid $pre\_$uID\_ZCAT_$nameR1[0] -pe alloc 12 -l virtual_free=3G $Bin/qCMD $STAR/STAR --genomeDir $starDB --readFilesIn $count/$nameR1[0] --runThreadN 12 --outFileNamePrefix $count/$nameR1[0]\_STAR_ --outSAMstrandField intronMotif --outFilterIntronMotifs RemoveNoncanonicalUnannotated --outSAMattributes All --outSAMunmapped Within`;
	    
	    sleep(5);
	    
	    `/common/sge/bin/lx24-amd64/qsub -P ngs -N $pre\_$uID\_SP_$run -hold_jid $pre\_$uID\_STAR_$nameR1[0] -pe alloc 1 -l virtual_free=3G -q lau.q $Bin/qCMD $Bin/starProcessing.pl $count/$nameR1[0]\_STAR_Aligned.out.sam`;
	    
	    push @bams, "I=$count/$nameR1[0]\_STAR_Aligned.out.sam_filtered.sam";
	}
    }
}
close IN;
close MISS;

sleep(5);

my $inputBams = join(" ", @bams);
`/common/sge/bin/lx24-amd64/qsub -P ngs -N $pre\_$uID\_MERGE_$run -hold_jid $pre\_$uID\_SP_$run -pe alloc 24 -l virtual_free=3G -q lau.q $Bin/qCMD /opt/bin/java -Djava.io.tmpdir=/scratch/$uID -jar $PICARD/MergeSamFiles.jar $inputBams O=$run\_NORG.bam SORT_ORDER=coordinate VALIDATION_STRINGENCY=LENIENT TMP_DIR=/scratch/$uID CREATE_INDEX=true USE_THREADING=true`;

sleep(5);

`/common/sge/bin/lx24-amd64/qsub -P ngs -N $pre\_$uID\_ADDRG -hold_jid $pre\_$uID\_MERGE_$run -pe alloc 3 -l virtual_free=3G -q lau.q $Bin/qCMD /opt/bin/java -Djava.io.tmpdir=/scratch/$uID -jar $PICARD/AddOrReplaceReadGroups.jar I=$run\_NORG.bam O=$run\_FILTERED.bam SORT_ORDER=coordinate VALIDATION_STRINGENCY=LENIENT TMP_DIR=/scratch/$uID CREATE_INDEX=true $readgroup`;
