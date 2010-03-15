package SVN::Analysis::Change;

use Moose;

has revision => ( is => 'rw', isa => 'Int', required => 1 );

sub is_add    { 0 }
sub is_copy   { 0 }
sub is_delete { 0 }
sub is_touch  { 0 }
sub exists    { 0 }

sub as_xml_element {
	my ($self, $document) = @_;
	my $change = $document->createElement("change");
	$change->appendTextNode(ref $self);
	$change->setAttribute(revision => $self->revision());
	return $change;
}

sub new_from_xml_element {
	my ($self, $element) = @_;
	my $change_class = $element->textContent();
	return $change_class->new(
		map { $_->nodeName(), $_->value() }
		$element->attributes()
	);
}

1;
