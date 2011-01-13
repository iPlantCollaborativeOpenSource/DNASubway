#!/usr/bin/perl 

use strict;
use lib ("/var/www/lib/perl", "/home/gearman/dnasubway/lib/perl");

use Data::Dumper;
use Gearman::Worker ();
use Storable qw(nfreeze thaw);

use DNALC::Pipeline::App::Phylogenetics::ProjectManager ();
use DNALC::Pipeline::Config();
use File::Basename;

sub run_phylip {
	my $gearman = shift;
	my $args = thaw( $gearman->arg );

	my ($status, $msg) = ('error', '');

	my $pm = DNALC::Pipeline::App::Phylogenetics::ProjectManager->new($args->{pid});
	my $proj = $pm->project;
	unless ($proj) {
		$msg = "Project not found!";
		print STDERR  "Project not found!", $/;
	}
	else {
		#my $phyi_file = $pm->get_alignment('phyi');
		#print STDERR "Alignment file to use: $phyi_file\n";

		my $dist_file = $pm->compute_dist_matrix;
		#print STDERR "Dist matrix file to use: $dist_file\n";
		if (-f $dist_file) {
			#print STDERR  "Dist = ", $dist_file, "\tsize = ", -s $dist_file, $/;

			my $stree = $pm->compute_tree($dist_file);
			print STDERR  "Tree = ", $stree->{tree}, "\t", $stree->{tree_file}, $/;
			$pm->set_task_status("phy_tree", "done");
			$status = "success";
		}
	}

   return nfreeze({status => $status, msg => $msg});
}


sub run_muscle {
	my $gearman = shift;
	my $args = thaw( $gearman->arg );

	my ($status, $msg) = ('error', '');

	my $pm = DNALC::Pipeline::App::Phylogenetics::ProjectManager->new($args->{pid});
	my $proj = $pm->project;
	unless ($proj) {
		$msg = "Project not found!";
		print STDERR  "Project not found!", $/;
	}
	else {
		if ($pm->build_alignment) {
			$status = "success";
		}
	}

   return nfreeze({status => $status, msg => $msg});
}


sub run_merger {
	my $gearman = shift;
	my $args = thaw( $gearman->arg );

	my ($status, $msg) = ("error", "");

	my $pm = DNALC::Pipeline::App::Phylogenetics::ProjectManager->new($args->{pid});
	my $proj = $pm->project;
	unless ($proj) {
		#$msg = "Project not found."
		print STDERR  "Project [$args->{pid}] not found!", $/;
	}
	else {
		my @pairs = $pm->pairs;
		if (@pairs) {
			if ($pm->get_task_status("phy_consensus")->name ne "done") {
				for my $p (@pairs) {
					$pm->build_consensus($p);
				}
				$pm->set_task_status("phy_consensus", "done");
				$status = "success";
			}
			$msg = $pm->get_task_status('phy_consensus')->name;
		}
		else {
			$msg = "This project has no pairs!";
		}

	}

   return nfreeze({status => $status});
}

#-------------------------------------------------
my $script_name = fileparse($0);
$script_name =~ s/\.[^.]*$//;
my $work_exit = 0;
my ($is_idle, $last_job_time);

my $stop_if = sub { 
	($is_idle, $last_job_time) = @_; 

	if ($work_exit) { 
		print STDERR  "*** [$script_name] exiting.. \n", $/;
		return 1; 
	}
	return 0; 
}; 

#-------------------------------------------------

my $pcf = DNALC::Pipeline::Config->new->cf('PIPELINE');
my $worker = Gearman::Worker->new;
$worker->job_servers(@{$pcf->{GEARMAN_SERVERS}});
$worker->register_function("phy_alignment", \&run_muscle);
$worker->register_function("phy_tree", \&run_phylip);
$worker->register_function("phy_consensus", \&run_merger);
$worker->register_function("${script_name}_exit" => sub { 
	$work_exit = 1; 
});

$worker->work( stop_if => $stop_if ) while !$work_exit;

exit 0;