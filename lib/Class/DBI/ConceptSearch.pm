# $Id $
#
# Perl module for Class::DBI::ConceptSearch
#
# Cared for by Allen Day <allenday@ucla.edu>
#
# Copyright Allen Day
#
# You may distribute this module under the same terms as perl itself

# POD documentation - main docs before the code

=head1 NAME

Class::DBI::ConceptSearch - Retrieve Class::DBI aggregates from high-level conceptual searches

=head1 SYNOPSIS

 my $cs = Class::DBI::ConceptSearch->new(xml => $config); #see CONFIGURATION
 $cs->use_wildcards(1);
 $cs->use_implicit_wildcards(1);
 $cs->use_search_ilike(1);

 my(@tracks) = $cs->search( albums => 'Britney' );

=head1 DESCRIPTION

Given the example Class::DBI classes (Music::CD, Music::Artist,
Music::Track), lets add another one, Music::Dbxref, which contains
external database accessions outside our control.  Music::Dbxref includes
things like UPC IDs, ASIN and ISBN numbers, vendor and manufacturer part
numbers, person IDs (for artists), etc.

Now, imagine a website with a basic search function that gives the users
the option of searching in "Albums", "Artists", "Tracks", and (my favorite)
"Anything".

(1) In a simple implementation, a user search for "Britney Spears" in
"Artists" is going to do something like:

Music::Artist->search( name => 'Britney Spears');

(2) But suppose the user had accidentally searched in "Albums".  The executed
search would be:

Music::CD->search( title => 'Britney Spears');

which doesn't produce any hits, and wouldn't even using search_like().
Doh!

(3) Likewise, if the user were to search in *any* category for Britney's
CD "In the Zone" by its ASIN B0000DD7LB, no hits would be found.

In a slightly more complex implementation, searches in each category might
try to match fields in multiple different tables.  Query (2) might try to
match "Britney Spears" in both Artist.name and CD.title, but this would be
hardcoded into a class that performs the search.  If the search should be
returning only CDs, we would also have to hardcode how to transform any
matching Music::Artist instance to Music::CD instance(s).

This is where Class::DBI::ConceptSearch comes in.  It contains a generic
search function that, given a configuration file, allows arbitrary
mappings of search categories to database table fields.  You specify what
the available categories are, and where to look for data when a category
is searched.

You also specify any transforms that need to be performed on the resulting
matches.  This is where the Artist->CD mapping in query (2) is set up.

You're also able to search in sections of the database which are private
internals, and return public data.  For instance, in query (3), we might
have searched in "Artist" for the ASID.  Behind the scenes,
Class::DBI::ConceptSearch finds the ID and follows up with a:

 Dbxref -> CD -> Artist

transform and returns the Music::Artist objects.

As we can imagine, there may be multiple possible paths within the
database between Dbxref and Artist.  It is also possible to specify these,
see CONFIGURATION for details on how to define multiple sources

NOTE: This example is contrived, and the usefulness of 

 Concept -> Table.Field(s)

mapping may not be readily apparent.  Class::DBI::ConceptSearch really
shines when you have a more complex data model.

=head2 CONFIGURATION aka CONCEPT MAP FORMAT

=head3 An example

 <?xml version="1.0" encoding="UTF-8"?> 
 <conceptsearch> 

   <!--
     Find artists with name matching search term
   -->
   <concept label="Artist" name="artist">
     <source class="Music::Artist" field="name"/>
   </concept>

   <!--
     Find albums with title matching search term,
      -OR-
     artist with name matching search term,
      -OR-
     album with dbxref (ASIN, UPC, etc) matching search term
   -->
   <concept label="Album" name="cd">
     <source class="Music::CD" field="title"/>
     <source class="Music::Artist" field="name">
       <transform sourceclass="Music::Artist" sourcefield="artistid" targetclass="Music::CD" targetfield="artistid"/>
     </source>
     <source class="Music::Dbxref" field="accession">
       <transform sourceclass="Music::Dbxref" sourcefield="dbxrefid" targetclass="Music::CD_Dbxref" targetfield="dbxrefid"/>
       <transform sourceclass="Music::CD_Dbxref" sourcefield="cdid" targetclass="Music::CD" targetfield="cdid"/>
     </source>
   </concept>

   <!--
     Find songs matching search term
      -OR-
     songs by artist matching search term
      -OR-
     songs matching dbxref (iTunes ID, perhaps)
   -->
   <concept label="Song" name="track">
     <source class="Music::Track" field="title"/>
     <source class="Music::Artist" field="name">
       <transform sourceclass="Music::Artist" sourcefield="artistid" targetclass="Music::CD" targetfield="artistid"/>
     </source>
     <source class="Music::Dbxref" field="accession">
       <transform sourceclass="Music::Dbxref" sourcefield="dbxrefid" targetclass="Music::Track_Dbxref" targetfield="dbxrefid"/>
       <transform sourceclass="Music::Track_Dbxref" sourcefield="trackid" targetclass="Music::Track" targetfield="trackid"/>
     </source>
   </concept>

 </conceptsearch>

=head3 Allowed elements and attributes

 conceptsearch              # root container for searchable concepts
   attributes:
     name (optional)
   subelements:
     concept (0..*)

 concept                    # a searchable concept
   attributes:
     name   (required)      # name of the concept
     label  (optional)      # label of the concept, used for display UI, for
                            # instance
     target (optional)      # class of object returned by source
   subelements:
     source (0..*)

 source                     # class in which to search
   attributes:
     class (required)       # name of class
     field (required)       # attribute of class to match search pattern
   subelements:
     transform (0..*)

 transform                  # rule to transform one class to another ; an edge
                            # between nodes
                            # a sourceclass.sourcefield = targetclass.targetfield
                            # join is performed
   attributes:
     sourceclass (required) # source class (defaults to parent source.class for
                            # first <transform/> element
     sourcefield (required) # source field which equals target field
     targetclass (required) # target class returned
     targetfield (required) # target field which equals source field
   subelements:
     none

=head1 FEEDBACK

=head2 Mailing Lists

Email the author, or cdbi-talk@groups.kasei.com

=head2 Reporting Bugs

Email the author.

=head1 AUTHOR

Allen Day E<lt>allenday@ucla.eduE<gt>

=head1 SEE ALSO

Concept Mapping
  http://www.google.com/search?q=concept+mapping

=head1 APPENDIX

The rest of the documentation details each of the object methods.
Internal methods are usually preceded with a _

=cut

package Class::DBI::ConceptSearch;
use strict;
use XML::XPath;

our $VERSION = '0.02';

use constant DEBUG => 0;

=head2 new

 Title   : new
 Usage   : my $obj = new Class::DBI::ConceptSearch(xml => $xml);
 Function: Builds a new Class::DBI::ConceptSearch object
 Returns : an instance of Class::DBI::ConceptSearch
 Args    : xml (required): an xml string describing the behavior of
           this instance.  See CONFIGURATION


=cut

sub new {
  my($class,%arg) = @_;

  my $self = bless {}, $class;
  $self->_init(%arg);

  die(__PACKAGE__.' requires an "xml" argument.') unless $self->xml;

  return $self;
}

=head2 _init

 Title   : _init
 Usage   : $obj->_init(%arg);
 Function: internal method.  initializes a new Class::DBI::ConceptSearch object
 Returns : true on success
 Args    : args passed to new()


=cut

sub _init {
  my($self,%arg) = @_;

  foreach my $arg (keys %arg){
    $self->$arg($arg{$arg}) if $self->can($arg);
  }

  return 1;
}

=head2 search

  Title   : search
  Usage   : $cs->search(concept => 'gene', pattern => 'GH1');
  Function:
  Returns : a (possibly heterogenous) list of objects inheriting from
            Class::DBI.
  Args    : concept (required): conceptual domain to be searched
            pattern (required): pattern to match in each source
            table.field of concept search, as configured.  See CONFIGURATION


=cut

sub search {
  my($self,$concept,$pattern) = @_;

  return () unless defined($concept) and defined($pattern);

  my $search_strategy;

  if(($pattern =~ /\*/s and $self->use_wildcards) or $self->use_implicit_wildcards){
    $pattern =~ s/\*/%/gs;

    $pattern = '%'.$pattern.'%' if $self->use_implicit_wildcards;

    if($self->use_search_ilike){
      $search_strategy = 'search_ilike';
    } else {
      $search_strategy = 'search_like';
    }
  } else {
    $search_strategy = 'search';
  }

  my $config = XML::XPath->new( xml => $self->xml ) or die "couldn't instantiate XML::XPath: $!";

  my @concepts;
  my @hits;

  #a driver to test the search
  foreach my $concept ($config->find('/searchlist/concept')->get_nodelist){
    next unless $concept eq $concept->getAttribute('name');

    my @concept_hits =();

    foreach my $source ($concept->find('source')->get_nodelist){
      my $sourceclass = $source->getAttribute('class');
      my $sourcefield = $source->getAttribute('field');
      my(@source_matches) = $sourceclass->$search_strategy( $sourcefield => $pattern );

      if(@source_matches){
        warn "xforms start" if DEBUG;

        foreach my $transform ($source->find('transform')->get_nodelist){
          warn "xform" if DEBUG;

          my $t_sourceclass = $transform->getAttribute('sourceclass'); #unused;
          my $t_sourcefield = $transform->getAttribute('sourcefield');
          my $t_targetclass = $transform->getAttribute('targetclass');
          my $t_targetfield = $transform->getAttribute('targetfield');

          my @t = ();

          foreach my $source_match (@source_matches){
            warn Dumper($source_match) if DEBUG;
            warn "$t_targetclass->search( $t_targetfield => ".$source_match->$t_sourcefield." );" if DEBUG;

            my $v =  ref($source_match->$t_sourcefield)
              ? $source_match->$t_sourcefield->id
              : scalar($source_match->$t_sourcefield);

            warn $v if DEBUG;

            # this call is fragile, handle it with care
            #
            # it would add power to allow search_like, search_ilike, or fuzzy searches (eg soundex) here
            # but requires extension of the xml format and *a lot* more code
            my @u = $t_targetclass->search( $t_targetfield => $v );
            push @t, @u;
          }
          @source_matches = @t;
        }

        push @concept_hits, @source_matches;
      }
      warn "xforms end" if DEBUG;
    }

    my %unique_hits = ();
    $unique_hits{ref($_).'_'.$_->id} = $_ foreach @concept_hits;
    @hits = values %unique_hits;
    return @hits;
  }
}

=head2 use_wildcards

  Title   : use_wildcards
  Usage   : $obj->use_wildcards($newval)
  Function: when true, enables search_like/search_ilike from
            search()
  Returns : value of use_wildcards (a scalar)
  Args    : on set, new value (a scalar or undef, optional)


=cut

sub use_wildcards {
  my $self = shift;

  return $self->{'use_wildcards'} = shift if @_;
  return $self->{'use_wildcards'};
}

=head2 use_implicit_wildcards

  Title   : use_implicit_wildcards
  Usage   : $obj->use_implicit_wildcards($newval)
  Function: assume wildcards on the beginning and end of the
            search string
  Returns : value of use_implicit_wildcards (a scalar)
  Args    : on set, new value (a scalar or undef, optional)


=cut

sub use_implicit_wildcards {
  my $self = shift;

  return $self->{'use_implicit_wildcards'} = shift if @_;
  return $self->{'use_implicit_wildcards'};
}

=head2 use_search_ilike

  Title   : use_search_ilike
  Usage   : $obj->use_search_ilike($newval)
  Function: when true, search() uses search_ilike()
            where search_like() would have been used
  Returns : value of use_search_ilike (a scalar)
  Args    : on set, new value (a scalar or undef, optional)


=cut

sub use_search_ilike {
  my $self = shift;

  return $self->{'use_search_ilike'} = shift if @_;
  return $self->{'use_search_ilike'};
}


=head2 xml

  Title   : xml
  Usage   : $obj->xml($newval)
  Function: stores the configuration for this instance.  See
            CONFIGURATION
  Returns : value of xml (a scalar)
  Args    : on set, new value (a scalar or undef, optional)


=cut

sub xml {
  my $self = shift;

  return $self->{'xml'} = shift if @_;
  return $self->{'xml'};
}

1;
