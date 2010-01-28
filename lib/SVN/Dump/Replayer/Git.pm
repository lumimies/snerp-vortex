package SVN::Dump::Replayer::Git;

{
	# TODO - Refactor into its own class?
	# It feels odd making an entire class for a data structure.
	package SVN::Dump::Replayer::Git::Author;
	use Moose;
	has name  => ( is => 'ro', isa => 'Str', required => 1 );
	has email => ( is => 'ro', isa => 'Str', required => 1 );
	1;
}

use Moose;
extends 'SVN::Dump::Replayer';

has authors_file    => ( is => 'ro', isa => 'Str' );
has authors => (
	is => 'rw',
	isa => 'HashRef[SVN::Dump::Replayer::Git::Author]',
	default => sub { {} }
);

has files_needing_add => (
	is => 'rw',
	isa => 'HashRef',
	default => sub { {} }
);

has directories_needing_add => (
	is => 'rw',
	isa => 'HashRef',
	default => sub { {} }
);

has needs_commit => ( is => 'rw', isa => 'Int', default => 0 );

###

after on_revision_done => sub {
	my ($self, $revision_id) = @_;
	my $final_revision = $self->arborist()->pending_revision();
	$self->git_commit($final_revision);
};

after on_walk_begin => sub {
  my $self = shift;

	# Set up authors mapping.
  if (defined $self->authors_file()) {
    open my $fh, "<", $self->authors_file() or die $!;
    while (<$fh>) {
      my ($nick, $name, $email) = (/(\S+)\s*=\s*(\S[^<]*?)\s*<(\S+?)>/);
      $self->authors()->{$nick} = SVN::Dump::Replayer::Git::Author->new(
        name  => $name,
        email => $email,
      );
    }
  }

	$self->do_rmdir($self->replay_base()) if -e $self->replay_base();
	$self->do_mkdir($self->replay_base());

	$self->push_dir($self->replay_base());
	$self->do_or_die("git", "init", ($self->verbose() ? () : ("-q")));
	$self->pop_dir();
};

after on_branch_directory_creation => sub {
	my ($self, $change, $revision) = @_;
	$self->do_mkdir($self->qualify_change_path($change));
	# Git doesn't track directories, so nothing to add.
};

after on_branch_directory_copy => sub {
	my ($self, $change, $revision) = @_;
	$self->do_directory_copy($change, $self->qualify_change_path($change));
	$self->directories_needing_add()->{$change->path()} = 1;
};

after on_directory_copy => sub {
	my ($self, $change, $revision) = @_;
	$self->do_directory_copy($change, $self->qualify_change_path($change));
	$self->directories_needing_add()->{$change->path()} = 1;
};

after on_directory_creation => sub {
	my ($self, $change, $revision) = @_;
	$self->do_mkdir($self->qualify_change_path($change));
};

after on_directory_deletion => sub {
	my ($self, $change, $revision) = @_;

  # TODO - Doesn't need a commit if $rel_path is a directory that
  # contains no files.
  #   1. find $rel_path -type f
  #   2. If anything comes up, then we need a commit.
  #   3. Otherwise, we don't need one on account of this.

  # First try git rm, to remove from the repository.
	$self->push_dir($self->replay_base());
	$self->do_sans_die(
		"git", "rm", "-r", "--ignore-unmatch", "-f", "--",
		$change->path(),
	);
	$self->pop_dir();

	# Second, try a plain filesystem remove in case the file hasn't yet
	# been staged.  Since git-rm may have removed any number of parent
	# directories for $rel_path, we only try to rmtree() if it still
	# exists.
	my $full_path = $self->qualify_change_path($change);
  $self->do_rmdir($full_path) if -e $full_path;

	delete $self->directories_needing_add()->{$change->path()};
	$self->needs_commit(1);
};

after on_file_change => sub {
	my ($self, $change, $revision) = @_;
	if ($self->rewrite_file($change, $self->qualify_change_path($change))) {
		$self->files_needing_add()->{$change->path()} = 1;
	}
};

after on_file_copy => sub {
	my ($self, $change, $revision) = @_;
	$self->do_file_copy($change, $self->qualify_change_path($change));
	$self->files_needing_add()->{$change->path()} = 1;
};

after on_file_creation => sub {
	my ($self, $change, $revision) = @_;
	$self->write_new_file($change, $self->qualify_change_path($change));
	$self->files_needing_add()->{$change->path()} = 1;
};

after on_file_deletion => sub {
	my ($self, $change, $revision) = @_;

	$self->push_dir($self->replay_base());
	$self->do_sans_die(
		"git", "rm", "-r", "--ignore-unmatch", "-f", "--",
		$change->path(),
	);
	$self->pop_dir();

	delete $self->files_needing_add()->{$change->path()};
	$self->needs_commit(1);
};

after on_tag_directory_copy => sub {
	my ($self, $change, $revision) = @_;

	$self->git_commit($revision);

	my $tag_name = $change->container->name();
	$self->push_dir($self->replay_base());
	open my $fh, "|-", "git tag -a -F - $tag_name" or die $!;
	print $fh $revision->message();
	close $fh;
	$self->pop_dir();
};

### Git helpers.

sub git_commit {
	my ($self, $revision) = @_;

	$self->push_dir($self->replay_base());

	# Every directory added is exploded into its constituent files.
	# Try to avoid "git-add --all".  It traverses the entire project
	# tree, which quickly gets expensive.

  if (scalar keys %{$self->directories_needing_add()}) {
    foreach my $dir (keys %{$self->directories_needing_add()}) {
      # TODO - Use File::Find when shell characters become an issue.
      foreach my $file (`find $dir -type f`) {
        chomp $file;
				$self->files_needing_add()->{$file} = 1;
      }
    }

		$self->directories_needing_add({});
    $self->needs_commit(1);
  }

  my $needs_status = 1;
  if (scalar keys %{$self->files_needing_add()}) {
		# TODO - Break it up if the files list is too big.
    $self->do_or_die("git", "add", "-f", keys(%{$self->files_needing_add()}));
		$self->files_needing_add({});
		$self->needs_commit(1);
		$needs_status = 0;
  }

	unless ($self->needs_commit()) {
		$self->log("skipping git commit");
		$self->pop_dir();
    return;
  }

	my $git_commit_message_file = "/tmp/git-commit.txt";

  open my $tmp, ">", $git_commit_message_file or die $!;
  print $tmp $revision->message() or die $!;
  close $tmp or die $!;

  $ENV{GIT_COMMITTER_DATE} = $ENV{GIT_AUTHOR_DATE} = $revision->time();

	my $rev_author = $revision->author();
  $ENV{GIT_COMMITTER_NAME} = $ENV{GIT_AUTHOR_NAME} = (
    $self->authors()->{$rev_author}->name() || "A. U. Thor"
  );

  $ENV{GIT_COMMITTER_EMAIL} = $ENV{GIT_AUTHOR_EMAIL} = (
    $self->authors()->{$rev_author}->email() || 'author@example.com'
  );

	# Some changes seem to alter no files.  We can detect whether a
	# commit is needed using git-status.  Otherwise, if we guess wrong,
	# git-commit will fail if there's nothing to commit.  We bother
	# checking git-commit because we do want to catch errors.

	# TODO - Status is noisy, and there's no way to -q it.  Can we be
	# smart enough to avoid git-status altogether?
  if (!$needs_status or !(system "git", "status")) {
    $self->do_or_die(
			"git", "commit",
			($self->verbose() ? () : ("-q")),
			"-F", $git_commit_message_file
		);
  }

	unlink $git_commit_message_file;

	$self->needs_commit(0);
	$self->pop_dir();
  return;
}

### Helper methods.

sub qualify_change_path {
	my ($self, $change) = @_;
	return $self->calculate_path($change->path());
}

sub calculate_path {
	my ($self, $path) = @_;

	my $full_path = $self->replay_base() . "/" . $path;
	$full_path =~ s!//+!/!g;

	return $full_path;
}

1;
