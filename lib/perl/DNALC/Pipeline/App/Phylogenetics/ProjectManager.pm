package DNALC::Pipeline::App::Phylogenetics::ProjectManager;


use common::sense;

use Fcntl qw/:flock/;
use IO::File ();
use IO::Scalar ();
use File::Basename;
use File::Path;
use File::Spec;
use File::Copy qw/move/;
use File::Slurp qw/slurp/;
use Carp;
use Digest::MD5();
use Data::Dumper;

#use DNALC::Pipeline::ProjectLogger ();
use DNALC::Pipeline::Config ();
use aliased 'DNALC::Pipeline::Phylogenetics::Project';
use aliased 'DNALC::Pipeline::Phylogenetics::DataSource';
use aliased 'DNALC::Pipeline::Phylogenetics::DataFile';
use aliased 'DNALC::Pipeline::Phylogenetics::DataSequence';
use aliased 'DNALC::Pipeline::Phylogenetics::Pair';
use aliased 'DNALC::Pipeline::Phylogenetics::PairSequence';
use aliased 'DNALC::Pipeline::Phylogenetics::Tree';
use aliased 'DNALC::Pipeline::Phylogenetics::Workflow';
use aliased 'DNALC::Pipeline::Phylogenetics::Blast';

use DNALC::Pipeline::Process::Phylip::DNADist ();
use DNALC::Pipeline::Process::Phylip::Neighbor ();
use DNALC::Pipeline::Process::Merger ();
use DNALC::Pipeline::Process::Muscle();
use DNALC::Pipeline::CacheMemcached ();
use DNALC::Pipeline::Task ();
use DNALC::Pipeline::TaskStatus ();

use Bio::SearchIO ();
use Bio::SeqIO ();
use Bio::AlignIO ();
use Bio::Trace::ABIF ();

{
	my %status_map = (
			"not-processed" => 1,
			"done"          => 2,
			"error"         => 3,
			"processing"    => 4
		);
	my %status_id_to_name = reverse %status_map;

	#-----------------------------------------------------------------------------
	sub new {
		my ($class, $project) = @_;

		my $self = bless {
				config => DNALC::Pipeline::Config->new->cf('PHYLOGENETICS'),
				#logger => DNALC::Pipeline::ProjectLogger->new,
				project => undef,
			}, __PACKAGE__;
		if ($project) {
			if (ref $project eq '' && $project =~ /^\d+$/) {
				my $proj = Project->retrieve($project);
				unless ($proj) {
					print STDERR "Phylogenetics Project with id=$project wasn't found!", $/;
				}
				else {
					$self->project($proj);
				}
			}
			else { # we assume it's an instance of a project
				$self->project($project);
			}
		}

		$self;
	}

	#-----------------------------------------------------------------------------
	sub create_project {
		my ($self, $params) = @_;
		
		my ($status, $msg) = ('fail', '');
		my $name = $params->{name};
		my $user_id = $params->{user_id};
		my $data = $params->{data};

		my $proj = $self->search(user_id => $user_id, name => $name);
		if ($proj) {
			return {status => 'fail', msg => "There is already a project named \"$name\"."};
		}
		# create project
		$proj = eval { Project->create({
					user_id => $user_id,
					name => $name,
					type => $params->{type},
					has_tools => $params->{has_tools},
					sample => $params->{sample} || 0,
					description => substr($params->{description} || '', 0, 140),
				});
			};
		if ($@) {
			$msg = "Error creating the project: $@";
			print STDERR  $msg, $/;
			return {status => 'fail', msg => $msg};
		}
		#print STDERR  "NEW PID = ", $proj, $/;
		
		$self->project($proj);
		
		$self->create_work_dir;

		return {status => 'success', msg => $msg};
	}

	#-----------------------------------------------------------------------------
	sub project {
		my ($self, $project) = @_;
		
		if ($project) {
			$self->{project} = $project;
		}

		$self->{project};
	}
	#-----------------------------------------------------------------------------
	sub add_data {
		my ($self, $params) = @_;

		my @errors = ();
		my $seq_count = 0;

		my $bail_out = sub { return {seq_count => $seq_count, errors => \@errors}};

		my $data_src = $self->project->add_to_datasources({
				name => $params->{source},
			});
		return $bail_out->() unless $data_src;

		my @files = @{$params->{files}};

		unless (-e $self->work_dir) {
			$self->create_work_dir;
		}

		my $fasta = $self->fasta_file;
		open (my $fasta_fh, ">> $fasta") or do {
				print STDERR  "Unable to open fasta file: $fasta\n$!", $/;
			};
		#print STDERR "fh1 = ", $fasta_fh, $/;
		flock $fasta_fh, LOCK_EX or print STDERR "Unable to lock fasta file!!!\n$!\n";
		my $out_io  = Bio::SeqIO->new(-fh => $fasta_fh, -format => 'Fasta', -flush  => 0);

		my $ab = Bio::Trace::ABIF->new if $params->{type} =~ /trace/i;

		for my $fhash (@files) {
			# store files
			# this will return the path of the stored file, if any
			#my $stored_file = $self->store_file(src => $f, target => 'x', type => 'yy');
			my $stored_file = $fhash->{path};
			my $filename = $fhash->{filename};
			my $f = $fhash->{path};

			my $data_file = DataFile->create({
						project_id => $self->project,
						source_id => $data_src,
						file_name => $filename || '',
						file_path => $stored_file,
						file_type => $params->{type},
					});
			#$data_file = undef;
			#print STDERR "data file: ", $data_file ? $data_file->id : "undef", $/;
			#print STDERR "data src: ", $data_src ? $data_src->id : "undef", $/;
			# store sequences
			# FASTA files
			if ($params->{type} =~ /^(?:fasta|reference)$/i) {
				# make sure we have a text file
				unless (-T $f) {
					push @errors, sprintf("File %s is not an FASTA file!", $filename);
					next;
				}
				my $seqio = Bio::SeqIO->new(-file => $f, -format => 'fasta');
				while (my $seq_obj = $seqio->next_seq) {
					#print ">", $seq_obj->display_id, $/;
					#print $seq_obj->seq, $/;
					
					my $seq = DataSequence->create({
							project_id => $self->project,
							source_id => $data_src,
							file_id => $data_file ? $data_file->id : undef,
							display_id => $seq_obj->display_id,
							seq => $seq_obj->seq,
						});
					$out_io->write_seq($seq_obj);
				}

				$seq_count++;
			}
			# AB1 files
			elsif ($params->{type} =~ /trace/i) {
				my $rc = eval {
						$ab->open_abif($f);
					};

				unless ($rc && $ab->is_abif_format) {
					$ab->close_abif;
					push @errors, sprintf("File %s is not an AB1 file", $filename);
					next;
				}

				my $sequence = $ab->sequence;
				my $display_id = $filename;

				# remove file extension (if any)
				$display_id =~ s/\..*?$//;
				#remove any spaces
				$display_id =~ s/\s+/_/g;

				#print $rc, $/;
				my $seq_obj = Bio::Seq->new(
						-seq => $sequence,
						-id => $display_id,
					);
				my $seq = DataSequence->create({
							project_id => $self->project,
							source_id => $data_src,
							file_id => $data_file ? $data_file->id : undef,
							display_id => $display_id,
							seq => $sequence,
						});
				#print ">", $seq_obj->display_id, $/;
				$out_io->write_seq($seq_obj);

				$seq_count++;
			}
		}
		$ab->close_abif if $ab && $ab->is_abif_open;
		close $fasta_fh;

		return $bail_out->();
	}

	#-----------------------------------------------------------------------------
	sub add_reference {
		my ($self, $ref_id) = @_;

		return unless $self->project;
		my $type = $self->project->type;
		my $ref_cf = DNALC::Pipeline::Config->new->cf('PHYLOGENETICS_REF');
		my $refs = defined $ref_cf->{$type} ? $ref_cf->{$type} : [];
		#print STDERR 'xx: ', Dumper( $refs ), $/;
		my ($ref) = grep {$_->{id} =~ /^$ref_id$/} @$refs;
		#print STDERR 'add_reference: ', $ref_id, $/;
		#print STDERR 'ref = ', $ref, $/;
		return unless $ref;

		my $st = $self->add_data({
					source => "ref:$ref_id",
					files => [{ path => $ref->{file}, filename => basename($ref->{file})}],
					type => "reference",
				});
	}

	#-----------------------------------------------------------------------------
	# returns a list of the used references in the project
	sub references {
		my ($self) = @_;

		return unless $self->project;
	
		my @sources = DataSource->search_like( 
				project_id => $self->project,
				name => 'ref:%'
			);
		my @refs = map { 
				my $r = $_->name; $r =~ s/^ref://; $r
			} @sources;

		wantarray ? @refs : \@refs;
	}
	#-----------------------------------------------------------------------------
	sub add_blast_data {
		my ($self, $blast_id, $selected_results) = @_;

		my @errors = ();
		my $seq_count = 0;

		my $bail_out = sub { return {seq_count => $seq_count, errors => \@errors}};

		my $blast = Blast->retrieve($blast_id);
		unless ($blast) {
			push @errors, "Blast results not found.";
			return $bail_out->();
		}

		my $data_src = $self->project->add_to_datasources({
				name => "blast:$blast_id",
			});
		return $bail_out->() unless $data_src;

		my $fasta = $self->fasta_file;
		open (my $fasta_fh, ">> $fasta") or do {
				print STDERR  "Unable to open fasta file: $fasta\n$!", $/;
			};
		#print STDERR "fh1 = ", $fasta_fh, $/;
		flock $fasta_fh, LOCK_EX or print STDERR "Unable to lock fasta file!!!\n$!\n";
		my $out_io  = Bio::SeqIO->new(-fh => $fasta_fh, -format => 'Fasta', -flush  => 0);

		my $in_fh = IO::Scalar->new;
		print $in_fh $blast->output;
		$in_fh->seek(0,0);
		my $in = Bio::SearchIO->new(-format => 'blast', -fh => $in_fh);
		
		my $out = '';

		while( my $res = $in->next_result ) {
			while( my $hit = $res->next_hit ) {
				while( my $hsp = $hit->next_hsp ) {
					my $seq_obj = $hsp->seq("hit");
					my $name = $seq_obj->display_id;
					$name =~ s/(\.1)?\|$//;
				
					# chack if $name is in the selected names
					#
					#

					my @tmp = split /\s+/, $hit->description;
					my $display_id = $name . '|' . join '_', map {lc $_} splice @tmp, 0, 2;
					#$display_id =~ s/\|+/\|/g;

					#print ">", $display_id, $/;
					$seq_obj->display_id($display_id);
				
					my $seq = DataSequence->create({
						project_id => $self->project,
						source_id => $data_src,
						file_id => undef,
						display_id => $display_id,
						seq => $seq_obj->seq,
					});
					$out_io->write_seq($seq_obj);

					$seq_count++;
				}
			}
		}
		close $fasta_fh;
		close $in_fh;

		return $bail_out->();
	}
	#-----------------------------------------------------------------------------

	sub files {
		my ($self, $type) = @_;
		return unless $self->project;

		my @files = ();
		if ($type) {
			@files = DataFile->search(project_id => $self->project, file_type => $type);
		}
		else {
			@files = DataFile->search(project_id => $self->project);
		}
		wantarray ? @files : \@files;
	}

	#-----------------------------------------------------------------------------
	sub add_pair {
		my ($self, @sequences) = @_;

		return unless @sequences == 2;

		my $pair;
		Pair->do_transaction( sub {
			$pair = Pair->create({
				project_id => $self->project,
			});
			die "Can't create pair.." unless $pair;
			for my $s (@sequences) {
				#$pair->add_to_pair_sequences($s);
				my $pq = eval {
					PairSequence->create({
						seq_id => $s->{seq_id},
						pair_id => $pair,
						project_id => $self->project,
						strand => $s->{strand},
					});
				};
				if ($@) {
					confess "Can't add sequence $s->{seq_id} to pair in project " . $self->project;
				}
			}
		});
		
		return $pair;
	}

	#-----------------------------------------------------------------------------
	sub pairs {
		my ($self) = @_;
		return unless $self->project;
		
		my @pairs = Pair->search(project_id => $self->project);
		wantarray ? @pairs : \@pairs;
	}

	#-----------------------------------------------------------------------------
	sub non_paired_sequences {
		my ($self) = @_;
		DataSequence->search_non_paired_sequences($self->project);
	}
	#-----------------------------------------------------------------------------
	sub sequences {
		my ($self) = @_;
		return unless $self->project;

		my @sequences = DataSequence->search(project_id => $self->project);
		wantarray ? @sequences : \@sequences;
	}
	#-----------------------------------------------------------------------------
	# returns a list of sequences that were used initially at project conception
	#
	sub initial_sequences {
		my ($self) = @_;
		return unless $self->project;

		my @sequences = ();
		#for my $pair ($self->pairs) {
		#	next unless $pair->consensus;
		#	my @pair_sequences = $pair->paired_sequences;
		#	my $name = join '_', map {$_->seq->display_id} @pair_sequences;
		#	push @data, ">pair_" . $name;
		#	push @data, $pair->consensus;
		#}
		for my $s ( DataSequence->search_initial_non_paired_sequences($self->project) ) {
			push @sequences, $s;
		}

		wantarray ? @sequences : \@sequences;
	}

	#-----------------------------------------------------------------------------
	# returns the sequences in FASTA format
	#
	sub alignable_sequences {
		my ($self) = @_;

		my %selected_sequences = ();
		my $memcached = DNALC::Pipeline::CacheMemcached->new;
		if ($memcached) {
			my $mc_key = "selected-seq-" . $self->project->id;
			my $sel = $memcached->get($mc_key);
			if ($sel && @$sel) {
				%selected_sequences = map {$_ => 1} @$sel;
			}
		}

		my $has_selected_sequences = keys %selected_sequences;

		my @data = ();
		for my $pair ($self->pairs) {
			next if ($has_selected_sequences && !defined $selected_sequences{"p$pair"});
			next unless $pair->consensus;
			my @pair_sequences = $pair->paired_sequences;
			my $name = join '_', map {$_->seq->display_id} @pair_sequences;
			push @data, ">pair_" . $name;
			push @data, $pair->consensus;
		}
		for my $s ($self->non_paired_sequences) {
			next if ($has_selected_sequences && !defined $selected_sequences{$s->id});
			push @data, ('>' . $s->display_id, $s->seq);
		}
		join "\n", @data;
	}
	#-----------------------------------------------------------------------------
	sub build_consensus {
		my ($self, $pair) = @_;
		
		return unless ref $self && $self->project;
		return unless (defined $pair && ref($pair) eq 'DNALC::Pipeline::Phylogenetics::Pair');

		my @pair_sequences = $pair->paired_sequences;
		#print STDERR Dumper( \@pair_sequences), $/;

		# check project directory exists
		my $pwd = $self->work_dir;
		return unless $pwd && -d $pwd;

		# mk tmp dir
		my $wd = File::Temp->newdir( 
					'bldcXXXXX',
					DIR => $pwd,
					CLEANUP => 1,
				);
		#print STDERR "tmp dir = ", $wd->dirname, $/;

		# copy sequences to files
		# build merger params hash
		#

		my $outfile = File::Spec->catfile($wd->dirname, 'outfile.txt');
		my $outseq  = File::Spec->catfile($wd->dirname, 'outseq.txt');
		#my $dbgfile = File::Spec->catfile($wd->dirname, 'debug.txt');

		my %merger_args = (
				input_files => [],
				_names => {},
				outfile => $outfile,
				outseq => $outseq,
				debug => 0,
			);
		my $cnt = 1;
		for my $s (@pair_sequences) {
			my $seq = $s->seq;
			#print STDERR  "\tseq = ",$seq->display_id, $/;
			my $seq_file = File::Spec->catfile($wd->dirname, "seq_$seq.fasta");
			my $fh = IO::File->new;
			if ($fh->open($seq_file, 'w')) {
				print $fh ">", $seq->display_id, "\n";
				print $fh $seq->seq;
				push @{$merger_args{input_files}}, $seq_file;
				$merger_args{"sreverse$cnt"} = 1 if $s->strand ne 'F';
				$merger_args{"sid$cnt"} = "seq_$seq";
				$merger_args{_names}->{"seq_$seq"} = $seq->display_id;
			}
			$cnt++;
		}
		my $merger = DNALC::Pipeline::Process::Merger->new($wd->dirname);
		$merger->run(%merger_args);
		#print STDERR Dumper( $merger ), $/;
		print STDERR "\nconsensus exit code = ", $merger->{exit_status}, $/;

		if ($merger->{exit_status} == 0) { # success

			my $pdir = File::Spec->catfile($pwd, "pairs");
			mkdir $pdir;
			my $formatted_alignment = File::Spec->catfile($pdir, "pair-$pair.txt");
			$merger->build_consensus($outfile, $outseq, $formatted_alignment);

			my $alignment = slurp($formatted_alignment);
			#my $alignment = slurp($outfile);
			#$alignment =~ s/#{3,}.*Report_file.*#{3,}\n*//ms;

			my $consensus = uc slurp($outseq);
			$consensus =~ s/>.*//;
			$consensus =~ s/\n//g;

			$pair->alignment($alignment);
			$pair->consensus($consensus);
			$pair->update;
		}
		#print STDERR Dumper( $merger ), $/;

		return 1;
	}

	#-----------------------------------------------------------------------------
	sub build_alignment {
		my ($self, $realign) = @_;

		my $pwd = $self->work_dir;
		return unless $pwd && -d $pwd;

		my $seq_fasta = '';
		if ($realign) {
			my $alignment_file = $self->get_alignment;
			my $fh = IO::File->new;
			if ($fh->open($alignment_file)) {
				flock $fh, LOCK_SH;
				while(<$fh>) {
					$seq_fasta .= $_;
				}
				flock $fh, LOCK_UN;
			}
		}
		else {
			
			$seq_fasta = $self->alignable_sequences;
		}
		return unless $seq_fasta;

		my $fasta_file = File::Spec->catfile($pwd, 'to_align.fas');
		my $fh = IO::File->new;
		if ($fh->open($fasta_file, 'w')) {
			flock $fh, LOCK_EX;
			print $fh $seq_fasta;
			flock $fh, LOCK_UN;
		}

		#my $m = DNALC::Pipeline::Process::Muscle->new($wd->dirname);
		my $m = DNALC::Pipeline::Process::Muscle->new($pwd);

		my $st = $m->run(pretend=>0, debug => 1, input => $fasta_file);

		my ($output, $phy_out);

		if (defined $m->{exit_status} && $m->{exit_status} == 0) { # success
			$output = $m->get_output;
		}
		
		if ($output && -f $output) {
			$phy_out = $m->convert_fasta_to_phylip;
			$self->set_task_status("phy_alignment", "done", $m->{elapsed});
		}
		else {
			$self->set_task_status("phy_alignment", "error");
		}

		#print STDERR  "exit_status: ", $m->{exit_status}, $/;
		#print STDERR  "elapsed: ", $m->{elapsed}, $/;

		print STDERR "Fasta out: ", $output, $/;
		print STDERR "phylip out: ", $phy_out, $/;
		return $output;
	}
	#-----------------------------------------------------------------------------
	# returns the path to the alignment file (default format is fasta)
	#	or undef if the file doesn't exist
	#
	sub get_alignment {
		my ($self, $format) = @_;

		$format ||= 'fasta';

		my $pwd = $self->work_dir;
		return unless -d $pwd;
		my $mcf = DNALC::Pipeline::Config->new->cf('MUSCLE');

		my $out_file;
		my ($out_type) = grep (/$format/i, keys %{$mcf->{option_output_files}});
		if ($out_type) {
			$out_file = File::Spec->catfile($pwd, 'MUSCLE', $mcf->{option_output_files}->{$out_type});
		}

		return $out_file if ($out_file && -f $out_file);
	}
	#-----------------------------------------------------------------------------
	# trims the last alignment
	#
	sub trim_alignment {
		my ($self, $params) = @_;

		my $alignment_file = $self->get_alignment;
		return unless $alignment_file;
		return unless ($params->{left} || $params->{right});

		my ($l_trim, $r_trim) = ($params->{left} || 0, $params->{right} || 0);

		my $aio; #Bio::AlignIO object
		open (my $afh, $alignment_file) || 
			confess "Can't read alignment: ", $/;

		flock $afh, LOCK_SH or print STDERR "Unable to lock fasta file!!!\n$!\n";
		$aio = Bio::AlignIO->new(-fh => $afh, -format => 'fasta');

		my $trimmed_fasta = '';
		while (my $aln = $aio->next_aln) {
			for my $seq ($aln->each_seq) {
				my $s = $seq->seq;
				$s = substr $s, 0, length($s) - $r_trim if $r_trim;
				$s = substr $s, $l_trim;

				$trimmed_fasta .= '>' . $seq->display_id . "\n";
				$trimmed_fasta .= $s . "\n";
			}
		}

		flock $afh, LOCK_UN;
		$afh->close;
		
		print STDERR  "size 1: ", -s $alignment_file, $/;

		# now write the trimmed alignment
		$afh = IO::File->new;
		if ($afh->open($alignment_file, 'w')) {
			flock $afh, LOCK_EX;
			print $afh $trimmed_fasta;
			flock $afh, LOCK_UN;
			$afh->close;
		}
		else {
			print STDERR  "Unable to write trimmed alignment..", $/;
		}
		print STDERR  "size 2: ", -s $alignment_file, $/;
		return $trimmed_fasta;
	}

	#-----------------------------------------------------------------------------
	#
	sub compute_dist_matrix {
		my ($self) = @_;

		my $pwd = $self->work_dir;
		return unless -d $pwd;

		my $dnadist_input = $self->get_alignment('phyi');
		return unless $dnadist_input;

		my $d = DNALC::Pipeline::Process::Phylip::DNADist->new($pwd);

		my $rc = $d->run(input => $dnadist_input, debug => 0);

		if ($rc == 0) {
			my $dist_file = $d->get_output;
			return $dist_file;
		}
		return;
	}
	#-----------------------------------------------------------------------------
	# params: 
	#	$dist_tree => the path to the tree created by neighbor
	# returns {tree => $tree_object, tree_file => $stored_tree_file}
	#
	sub compute_tree {
		my ($self, $dist_file) = @_;

		my $pwd = $self->work_dir;
		return unless -d $pwd;

		my $p = DNALC::Pipeline::Process::Phylip::Neighbor->new($pwd);

		my $rc = $p->run( input => $dist_file, debug => 1 );
		if ($rc == 0) {
			#print STDERR  "exit_status: ", $p->{exit_status}, $/;
			print STDERR  "elapsed: ", $p->{elapsed}, $/;

			my $stored_tree = $self->_store_tree($p->get_tree);
			return $stored_tree if ($stored_tree && $stored_tree->{tree});
		}

		return;
	}

	#-----------------------------------------------------------------------------
	#
	sub get_tree {
		my ($self) = @_;

		my $pwd = $self->work_dir;
		return unless -d $pwd;

		my $project = $self->project;
		return unless $project;

		my ($tree, $tree_file);

		my $tree_dir = File::Spec->catfile($pwd, 'trees');
		#print STDERR "Trees are in ", $tree_dir, $/;
		unless (-e $tree_dir) {
			unless (mkdir $tree_dir) {
				print STDERR  "Unable to create tree dir for project: ", $project, $/;
				return;
			}
		}
		my $trees = Tree->search(project_id => $project->id,  {order_by => 'id DESC' });
		#print STDERR "Trees= ", $trees, $/;
		if ($trees) {
			$tree = $trees->next;
			$tree_file = File::Spec->catfile($tree_dir, sprintf("%d.nw", $tree->id) );
		}

		return {tree => $tree, tree_file => $tree_file};
	}

	#-----------------------------------------------------------------------------
	#
	sub _store_tree {
		my ($self, $file) = @_;

		return unless ($file && -f $file);

		my $pwd = $self->work_dir;
		return unless -d $pwd;

		my $project = $self->project;
		return unless $project;

		my $tree = eval {
			Tree->create({
				project_id => $project,
			});
		};
		if ($@) {
			print STDERR "Error storing tree: $@", $/;	
			return;
		}

		my $tree_dir = File::Spec->catfile($pwd, 'trees');
		unless (-e $tree_dir) {
			unless (mkdir $tree_dir) {
				print STDERR  "Unable to create tree dir for project: ", $project, $/;
				return;
			}
		}
		my $tree_file = File::Spec->catfile($tree_dir, sprintf("%d.nw", $tree->id) );
		unless (move $file, $tree_file) {
			return;
		}

		return {tree => $tree, tree_file => $tree_file};
	}


	#-----------------------------------------------------------------------------
	sub store_file {
		my ($self, $params) = @_;
		
	}

	#-----------------------------------------------------------------------------
	sub do_blast_sequence {
		my ($self, %args) = @_;

		my $bail_out = sub { return {status => 'error', 'message' => shift } };

		my $seq_str;
		my $blast;
		my $status = 'success';

		my $seq = $args{seq};
		my $pair = $args{pair};
		my $type = $args{type};

		unless ($type && $type =~ /sequence|consensus/) {
			return $bail_out->("Blast: Missing or invalid type specified.");
		}

		if ($type eq 'sequence') {
			unless ( ref ($seq) =~ /DataSequence/) {
				($seq) = DataSequence->search(
						project_id => $self->project->id,
						id => $seq,
					);
			}
			$seq_str = $seq->seq if $seq;
		}
		else {
			unless ( ref ($pair) =~ /Pair$/) {
				($pair) = Pair->search(
						project_id => $self->project->id,
						pair_id => $pair,
					);
			}
			$seq_str = $pair->consensus if $pair;
		}

		#print STDERR  'seq = ', $seq_str, $/;

		my $ctx = Digest::MD5->new;
		$ctx->add($seq_str);
		my $crc = $ctx->hexdigest;

		# see if we already have cached such sequence
		($blast) = Blast->search( crc => $crc );
		if ($blast) {
			return {status => 'success', blast => $blast};
		}
		
		my $pwd = $self->work_dir;
		my $tdir = File::Temp->newdir(
                    'blast_XXXXX',
                    DIR => $pwd,
                    CLEANUP => 1,
                );
		my $in_file = File::Spec->catfile($tdir->dirname, 'input.txt');
		my $out_file = File::Spec->catfile($tdir->dirname, 'output.txt');

		my $fh = IO::File->new;
		if ($fh->open($in_file, 'w')) {
			print $fh $seq_str;
			$fh->close;
		}
		else {
			print STDERR "Can't write file $in_file", $/;
			return $bail_out->('Error: Cannot process sequence.');
		}
		
		my @args = (
				'-p', 'blastn',
				'-d', 'nr',
				'-i', $in_file,
				'-o', $out_file,
			);
		#print STDERR 'blast args: ', Dumper( \@args ), $/;

		my $pcf = DNALC::Pipeline::Config->new->cf('PIPELINE');
		my $blast_script = File::Spec->catfile($pcf->{EXE_PATH}, 'web_blast.pl');
		my $rc = system($blast_script, @args);
		print STDERR "blast rc = $rc\n";

		# 0 == success
		# 2 == success, no results
		if ((0 == $rc || 2 == $rc) && -f $out_file) {
			my $alignment = '';
			if ($fh->open($out_file)) {
				while (<$fh>) {
					$alignment .= $_;
				}
				$fh->close;			
			}
			$blast = DNALC::Pipeline::Phylogenetics::Blast->create({
					project_id => $self->project->id,
					sequence_id => $seq,
					crc => $crc,
					output => $alignment || 'No results!',
				});
			$status = 'success';

		}

		return {status => $status, blast => $blast};

	}
	#-----------------------------------------------------------------------------

	sub create_work_dir {
		my ($self) = @_;

		my $path = $self->work_dir;
		return unless $path;

		eval { mkpath($path) };
		if ($@) {
			print STDERR "Couldn't create $path: $@", $/;
			return;
		}
		return 1;
	}

	#-----------------------------------------------------------------------------
	sub work_dir {
		my ($self) = @_;
		return unless ref $self eq __PACKAGE__;
		my $proj = $self->project;
		unless ($proj)  {
			confess "Project is missing...\n";
			return;
		}

		return File::Spec->catfile($self->config->{PROJECTS_DIR}, sprintf("%04X", $proj->id));
	}
	#-----------------------------------------------------------------------------
	sub config {
		my ($self) = @_;

		$self->{config};
	}
	#-----------------------------------------------------------------------------
	sub search {
		my ($self, %args) = @_;

		Project->search(%args);
	}

	#-----------------------------------------------------------------------------
	sub has_fasta_file {
		my ($self) = @_;
		return $self->fasta_file && -f $self->fasta_file;
	}
	#-----------------------------------------------------------------------------
	sub fasta_file {
		my ($self) = @_;
		my $wd = $self->work_dir;
		return File::Spec->catfile($wd, 'fasta.fa');
	}
	#-----------------------------------------------------------------------------
	sub set_task_status {
		my ($self, $task_name, $status_name, $duration) = @_;

		unless (defined $status_map{ $status_name }) {
			print STDERR  "Unknown status: ", $status_name, $/;
			croak "Unknown status: ", $status_name, $/;
		}

		my ($task) = DNALC::Pipeline::Task->search(name => $task_name );
		unless ($task) {
			print STDERR  "Unknown task: ", $task_name, $/;
			croak "Unknown task: ", $task_name, $/;
		}

		my $wf = Workflow->retrieve(
					project_id => $self->project->id,
					task_id => $task,
				);
		if ($wf) {
			$wf->status_id($status_map{ $status_name });
			$wf->duration( $duration ? $duration : 0);
			$wf->update;
		}
		else {
			$wf = eval{
				Workflow->create({
					project_id => $self->project->id,
					task_id => $task,
					status_id => $status_map{ $status_name },
					duration => $duration ? $duration : 0,
				});
			};
			if ( $@ ) {
				print STDERR  "Can't add workflow details: ", $@, $/;
			}
		}
		$wf->status;
	}
	#-----------------------------------------------------------------------------
	sub get_task_status {
		my ($self, $task_name) = @_;

		#print STDERR  "TASK NAME = $task_name", $/;
		my ($task) = DNALC::Pipeline::Task->search(name => $task_name );
		#print STDERR  "TASK = $task", $/;
		unless ($task) {
			print STDERR  "Unknown task: ", $task_name, $/;
			croak "Unknown task: ", $task_name, $/;
		}

		my ($wf) = Workflow->search(
					project_id => $self->project->id,
					task_id => $task,
				);

		unless ($wf) {
			return DNALC::Pipeline::TaskStatus->retrieve( $status_map{'not-processed'} );
		}
		$wf->status;

	}
}

1;