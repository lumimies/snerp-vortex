package SVN::Dump::Analyzer;

use Moose;
extends qw(SVN::Dump::Walker);

use SVN::Analysis;

use Carp qw(croak);
use Storable qw(dclone);

has analysis => (
	is      => 'rw',
	isa     => 'SVN::Analysis',
	lazy    => 1,
	default => sub {
		my $self = shift;
		SVN::Analysis->new( verbose => $self->verbose() );
	},
);

has verbose => ( is => 'ro', isa => 'Bool', default => 0 );

#######################################
### 1st walk: Analyze branch lifespans.

sub on_node_add {
	my ($self, $revision, $path, $kind, $data) = @_;
	$self->log("r$revision add $kind $path");
	$self->analysis()->consider_add($revision, $path, $kind);
}

sub on_node_change {
	my ($self, $revision, $path, $kind, $data) = @_;
	$self->log("r$revision edit $kind $path");
	$self->analysis()->consider_change($revision, $path, $kind);
}

sub on_node_replace {
	my ($self, $revision, $path, $kind, $data) = @_;
	$self->log("r$revision replace $kind $path");
	$self->analysis()->consider_change($revision, $path, $kind);
}

sub on_node_copy {
	my ($self, $dst_rev, $dst_path, $kind, $src_rev, $src_path, $text) = @_;
	$self->log("r$dst_rev copy $kind $dst_path from $src_path r$src_rev");
	$self->analysis()->consider_copy(
		$dst_rev, $dst_path, $kind, $src_rev, $src_path
	);
}

sub on_node_delete {
	my ($self, $revision, $path) = @_;
	$self->log("r$revision delete $path");
	$self->analysis()->consider_delete($revision, $path);
}

sub on_walk_done {
	my $self = shift;
	$self->analysis()->analyze();
}

sub on_walk_begin {
	my $self = shift;

	# The repository needs a root directory.
	$self->analysis()->consider_add(0, "", "dir");
}

sub log {
	my $self = shift;
	return unless $self->verbose();
	warn time() - $^T, " ", join("", @_), "\n";
}

1;
