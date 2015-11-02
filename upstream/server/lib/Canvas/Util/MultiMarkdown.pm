package Canvas::Util::MultiMarkdown;

use Mojo::Base -base;

#
# PERL INCLUDES
#
use Carp            qw(croak);
use Data::Dumper;
use Digest::MD5     qw(md5_hex);
use Encode          qw(encode_utf8);
use Text::Balanced  qw(gen_extract_tagged);

my $VERSION   = '2.0.b6-c1';

#
# GLOBALS
#

# Reusable patterns to match balanced [brackets] and (parens). See
# Friedl's "Mastering Regular Expressions", 2nd Ed., pp. 328-331.
my ($g_nested_brackets, $g_nested_parens);
$g_nested_brackets = qr{
  (?>                 # Atomic matching
     [^\[\]]+             # Anything other than brackets
   |
     \[
     (??{ $g_nested_brackets })   # Recursive set of nested brackets
     \]
  )*
}x;

# Doesn't allow for whitespace, because we're using it to match URLs:
$g_nested_parens = qr{
  (?>                 # Atomic matching
     [^()\s]+             # Anything other than parens or whitespace
   |
     \(
     (??{ $g_nested_parens })   # Recursive set of nested brackets
     \)
  )*
}x;


# Table of hash values for escaped characters:
my %g_escape_table;
foreach my $char (split //, '\\`*_{}[]()>#+-.!') {
  $g_escape_table{$char} = md5_hex($char);
}

sub new {
    my ($class, %p) = @_;

    $p{use_attributes} = ( $p{use_attributes} // 0 ) ? 1 : 0;

    # default off
    $p{use_metadata} = ( $p{use_metadata} // 0 ) ? 1 : 0;

    $p{use_metadata_newline} //= {
      default   => "\n",
      keywords  => ',',
    };

    $p{base_url} ||= ''; # This is the base url to be used for WikiLinks

    $p{tab_width} = 4 unless (defined $p{tab_width} and $p{tab_width} =~ m/^\d+$/);

    $p{document_format} ||= '';
    $p{allow_mathml} = 0;
    $p{base_header_level} = 1;
    $p{list_level} = 0;

    $p{empty_element_suffix} ||= ' />'; # Change to ">" for HTML output

    #$p{heading_ids} = defined $p{heading_ids} ? $p{heading_ids} : 1;

    # For use with WikiWords and [[Wiki Links]]
    # NOTE: You can use \WikiWord to prevent a WikiWord from being treated as a link
    $p{use_wikilinks} = $p{use_wikilinks} ? 1 : 0;

    $p{heading_ids} = defined $p{heading_ids} ? $p{heading_ids} : 1;
    $p{img_ids}     = defined $p{img_ids}     ? $p{img_ids}     : 1;

    $p{bibliography_title} ||= 'Bibliography'; # FIXME - Test and document, can also be in metadata!

    my $self = { params => \%p };
    bless $self, ref($class) || $class;
    return $self;
}


sub markdown {
  my ( $self, $text, $options ) = @_;

  # detect functional mode, and create an instance for this run..
  unless( ref $self ) {
    if( $self ne __PACKAGE__ ) {
      my $ob = __PACKAGE__->new();
      # $self is text, $text is options
      return $ob->markdown($self, $text);
    }
    else {
      croak('Calling ' . $self . '->markdown (as a class method) is not supported.');
    }
  }

  $options //= {};

  %$self = (%{ $self->{params} }, %$options, params => $self->{params});

  $self->_CleanUpRunData($options);

  return $self->_Markdown($text);
}


sub _CleanUpRunData {
  my ($self, $options) = @_;
  # Clear the global hashes. If we don't clear these, you get conflicts
  # from other articles when generating a page which contains more than
  # one article (e.g. an index page that shows the N most recent
  # articles):
  $self->{_crossrefs}   = {};
  $self->{_footnotes}   = {};
  $self->{_references}  = {};
  $self->{_used_footnotes}  = []; # Why do we need 2 data structures for footnotes? FIXME
  $self->{_used_references} = []; # Ditto for references
  $self->{_citation_counter} = 0;
  $self->{_metadata} = {};
  $self->{_attributes}  = {}; # Used for extra attributes on links / images.

  $self->{_urls} = {};
  $self->{_titles} = {};
  $self->{_html_blocks} = {};
  $self->{_metadata_newline} = {};
  $self->{_footnote_counter} = 0;

  $self->{_list_level} = $self->{params}{list_level};
  $self->{_base_url} = $self->{params}{base_url};

#$g_bibliography_title = "Bibliography";

#$self->{params}{use_metadata} = 1;
#$self->{_metadata}_newline{default} = "\n";
#$self->{_metadata}_newline{keywords} = ", ";
#my $self->{params}{document_format} = "";

# Used to track when we're inside an ordered or unordered list
# (see _ProcessListItems() for details):
#my $g_list_level = 0;
}


sub _Markdown {
#
# Main function. The order in which other subs are called here is
# essential. Link and image substitutions need to happen before
# _EscapeSpecialCharsWithinTagAttributes(), so that any *'s or _'s in the <a>
# and <img> tags get encoded.
#
  my $self = shift;
  my $text = shift // '';

  # Standardize line endings:
  $text =~ s{\r\n}{\n}g;  # DOS to Unix
  $text =~ s{\r}{\n}g;  # Mac to Unix

  # Make sure $text ends with a couple of newlines:
  $text .= "\n\n";

  # Convert all tabs to spaces.
  $text = $self->_Detab($text);

  # Strip any lines consisting only of spaces and tabs.
  # This makes subsequent regexen easier to write, because we can
  # match consecutive blank lines with /\n+/ instead of something
  # contorted like /[ \t]*\n+/ .
  $text =~ s/^[ \t]+$//mg;

  # Strip out MetaData
  $text = $self->_ParseMetaData($text) if $self->{params}{use_metadata};

  # And recheck for leading blank lines
  $text =~ s/^\n+//s;

  # Turn block-level HTML blocks into hash entries
  $text = $self->_HashHTMLBlocks($text);

  # Strip footnote and link definitions, store in hashes.
  $text = $self->_StripFootnoteDefinitions($text);

  $text = $self->_StripLinkDefinitions($text);

  $self->_GenerateImageCrossRefs($text);

  $text = $self->_StripMarkdownReferences($text);

  $text = $self->_RunBlockGamut($text);

  $text = $self->_DoMarkdownCitations($text);

  $text = $self->_DoFootnotes($text);

  $text = $self->_UnescapeSpecialChars($text);

  # Clean encoding within HTML comments
  $text = $self->_UnescapeComments($text);

  $text = $self->_FixFootnoteParagraphs($text);
  $text .= $self->_PrintFootnotes();

  $text .= $self->_PrintMarkdownBibliography();

  $text = $self->_ConvertCopyright($text);

  # sanitise our input from unsafe tags
  $text = $self->_SanitiseHTML( $text );

  $text = $self->_DoVideoEmbeds($text);

  return $text . "\n";
}


sub _StripLinkDefinitions {
  my $self = shift;
#
# Strips link definitions from text, stores the URLs and titles in
# hash references.
#
  my $text = shift;
  my $less_than_tab = $self->{params}{tab_width} - 1;

  # Link defs are in the form: ^[id]: url "optional title"
  while ($text =~ s{
            # Pattern altered for MultiMarkdown
            # in order to not match citations or footnotes
            ^[ ]{0,$less_than_tab}\[([^#^].*)\]:  # id = $1
              [ \t]*
              \n?       # maybe *one* newline
              [ \t]*
            <?(\S+?)>?      # url = $2
              [ \t]*
              \n?       # maybe one newline
              [ \t]*
            (?:
              (?<=\s)     # lookbehind for whitespace
              ["(]
              (.+?)     # title = $3
              [")]
              [ \t]*
            )?  # title is optional

            # MultiMarkdown addition for attribute support
            \n?
            (       # Attributes = $4
              (?<=\s)     # lookbehind for whitespace
              (([ \t]*\n)?[ \t]*((\S+=\S+)|(\S+=".*?")))*
            )?
            [ \t]*
            # /addition
            (?:\n+|\Z)
          }
          {}mx) {
#   $self->{_urls}{lc $1} = _EncodeAmpsAndAngles( $2 );  # Link IDs are case-insensitive
    $self->{_urls}{lc $1} = $2;  # Link IDs are case-insensitive
    if ($3) {
      $self->{_titles}{lc $1} = $3;
      $self->{_titles}{lc $1} =~ s/"/&quot;/g;
    }

    # MultiMarkdown addition "
    if( $4 && $self->{params}{use_attributes} ) {
      $self->{_attributes}{lc $1} = $4;
    }
    # /addition
  }

  return $text;
}

sub _DoVideoEmbeds {
  my $self = shift;

  # Strip unsupported (X)HTML code from string
  my $text = shift;

  $text =~ s/youtube!([a-zA-Z0-9_-]{11})/<div class="video-container"><iframe width="560" height="315" src="\/\/www.youtube.com\/embed\/$1" frameborder="0" allowfullscreen><\/iframe><\/div>/g;
  $text =~ s/vimeo!([0-9]+)/<div class="video-container"><iframe width="560" height="315" src="\/\/player.vimeo.com\/video\/$1" frameborder="0" allowfullscreen><\/iframe><\/div>/g;

  return $text;
}

sub _SanitiseHTML {
  my $self = shift;

  # Strip unsupported (X)HTML code from string
  my $text = shift;

  $text =~ s/<(\/?((?!a|b|blockquote|code|div|em|h[1-6]|i|img|li|ol|p|span|strong|ul|\/)[^>]*)|(\/?(iframe|ins)[^>]*))>/&lt;$1&gt;/g;

  return $text;
}

sub _StripHTML {
  my $self = shift;
  # Strip (X)HTML code from string
  my $text = shift;

  $text =~ s/<.*?>//g;

  return $text;
}

sub _HashHTMLBlocks {
  my $self = shift;
  my $text = shift;
  my $less_than_tab = $self->{params}{tab_width} - 1;

  # Hashify HTML blocks:
  # We only want to do this for block-level HTML tags, such as headers,
  # lists, and tables. That's because we still want to wrap <p>s around
  # "paragraphs" that are wrapped in non-block-level tags, such as anchors,
  # phrase emphasis, and spans. The list of tags we're looking for is
  # hard-coded:
  my $block_tags = qr{
      (?:
      p         |  div     |  h[1-6]  |  blockquote  |  pre       |  table  |
      dl        |  ol      |  ul      |  script      |  noscript  |  form   |
      fieldset  |  iframe     |  ins         |  del
      )
    }x;     # MultiMarkdown does not include `math` in the above list so that
          # Equations can optionally be included in separate paragraphs

  my $tag_attrs = qr{
            (?:       # Match one attr name/value pair
              \s+       # There needs to be at least some whitespace
                      # before each attribute name.
              [\w.:_-]+   # Attribute name
              \s*=\s*
              (?:
                ".+?"   # "Attribute value"
               |
                '.+?'   # 'Attribute value'
              )
            )*        # Zero or more
          }x;

  my $empty_tag = qr{< \w+ $tag_attrs \s* />}xms;
  my $open_tag =  qr{< $block_tags $tag_attrs \s* >}xms;
  my $close_tag = undef;  # let Text::Balanced handle this

  my $extract_block = gen_extract_tagged($open_tag, $close_tag, undef, { ignore => [$empty_tag] });

  my @chunks;
  ## TO-DO: the 0,3 on the next line ought to respect the
  ## tabwidth, or else, we should mandate 4-space tabwidth and
  ## be done with it:
  while ($text =~ s{^(([ ]{0,3}<)?.*\n)}{}m) {
    my $cur_line = $1;
    if (defined $2) {
      # current line could be start of code block

      my ($tag, $remainder) = $extract_block->($cur_line . $text);
      if ($tag) {
        my $key = md5_hex( encode_utf8 $tag );
        $self->{_html_blocks}{$key} = $tag;
        push @chunks, "\n\n" . $key . "\n\n";
        $text = $remainder;
      }
      else {
        # No tag match, so toss $cur_line into @chunks
        push @chunks, $cur_line;
      }
    }
    else {
      # current line could NOT be start of code block
      push @chunks, $cur_line;
    }

  }
  push @chunks, $text; # Whatever is left.

  $text = join '', @chunks;



  # Special case just for <hr />. It was easier to make a special case than
  # to make the other regex more complicated.
  $text =~ s{
        (?:
          (?<=\n\n)   # Starting after a blank line
          |       # or
          \A\n?     # the beginning of the doc
        )
        (           # save in $1
          [ ]{0,$less_than_tab}
          <(hr)       # start tag = $2
          \b          # word break
          ([^<>])*?     #
          /?>         # the matching end tag
          [ \t]*
          (?=\n{2,}|\Z)   # followed by a blank line or end of document
        )
      }{
        my $key = md5_hex( encode_utf8 $1 );
        $self->{_html_blocks}{$key} = $1;
        "\n\n" . $key . "\n\n";
      }egx;

  # Special case for standalone HTML comments:
  $text =~ s{
        (?:
          (?<=\n\n)   # Starting after a blank line
          |       # or
          \A\n?     # the beginning of the doc
        )
        (           # save in $1
          [ ]{0,$less_than_tab}
          (?s:
            <!
            (--.*?--\s*)+
            >
          )
          [ \t]*
          (?=\n{2,}|\Z)   # followed by a blank line or end of document
        )
      }{
        my $key = md5_hex( encode_utf8 $1 );
        $self->{_html_blocks}{$key} = $1;
        "\n\n" . $key . "\n\n";
      }egx;

  # PHP and ASP-style processor instructions (<?…?> and <%…%>)
  $text =~ s{
        (?:
          (?<=\n\n)   # Starting after a blank line
          |       # or
          \A\n?     # the beginning of the doc
        )
        (           # save in $1
          [ ]{0,$less_than_tab}
          (?s:
            <([?%])     # $2
            .*?
            \2>
          )
          [ \t]*
          (?=\n{2,}|\Z)   # followed by a blank line or end of document
        )
      }{
        my $key = md5_hex( encode_utf8 $1 );
        $self->{_html_blocks}{$key} = $1;
        "\n\n" . $key . "\n\n";
      }egx;


  return $text;
}


sub _RunBlockGamut {
  my $self = shift;
#
# These are all the transformations that form block-level
# tags like paragraphs, headers, and list items.
#
  my $text = shift;

  $text = $self->_DoFencedCodeBlocks($text);

  $text = $self->_DoHeaders($text);

  # Do tables first to populate the table id's for cross-refs
  # Escape <pre><code> so we don't get greedy with tables
  $text = $self->_DoTables($text);

  # And now, protect our tables
  $text = $self->_HashHTMLBlocks($text);

  # Do Horizontal Rules:
  $text =~ s{^[ ]{0,2}([ ]?\*[ ]?){3,}[ \t]*$}{\n<hr$self->{params}{empty_element_suffix}\n}gmx;
  $text =~ s{^[ ]{0,2}([ ]? -[ ]?){3,}[ \t]*$}{\n<hr$self->{params}{empty_element_suffix}\n}gmx;
  $text =~ s{^[ ]{0,2}([ ]? _[ ]?){3,}[ \t]*$}{\n<hr$self->{params}{empty_element_suffix}\n}gmx;

  $text = $self->_DoDefinitionLists($text);
  $text = $self->_DoLists($text);
  $text = $self->_DoCodeBlocks($text);
  $text = $self->_DoBlockQuotes($text);

  # We already ran _HashHTMLBlocks() before, in Markdown(), but that
  # was to escape raw HTML in the original Markdown source. This time,
  # we're escaping the markup we've just created, so that we don't wrap
  # <p> tags around block-level tags.
  $text = $self->_HashHTMLBlocks($text);
  $text = $self->_FormParagraphs($text);

  return $text;
}


sub _RunSpanGamut {
  my $self = shift;
#
# These are all the transformations that occur *within* block-level
# tags like paragraphs, headers, and list items.
#
  my $text = shift;

  $text = $self->_DoCodeSpans($text);
#  $text = _DoMathSpans($text);
  $text = $self->_EscapeSpecialCharsWithinTagAttributes($text);
  $text = $self->_EncodeBackslashEscapes($text);

  # Process anchor and image tags. Images must come first,
  # because ![foo][f] looks like an anchor.
  $text = $self->_DoImages($text);
  $text = $self->_DoAnchors($text);

  # Make links out of things like `<http://example.com/>`
  # Must come after _DoAnchors(), because you can use < and >
  # delimiters in inline links like [this](<url>).
  $text = $self->_DoAutoLinks($text);
  $text = $self->_EncodeAmpsAndAngles($text);
  $text = $self->_DoItalicsAndBold($text);

  # Do hard breaks:
  $text =~ s/ {2,}\n/ <br$self->{params}{empty_element_suffix}\n/g;

  return $text;
}


sub _EscapeSpecialCharsWithinTagAttributes {
  my $self = shift;
#
# Within tags -- meaning between < and > -- encode [\ ` * _] so they
# don't conflict with their use in Markdown for code, italics and strong.
# We're replacing each such character with its corresponding MD5 checksum
# value; this is likely overkill, but it should prevent us from colliding
# with the escape values by accident.
#
  my $text = shift;
  my $tokens ||= $self->_TokenizeHTML($text);
  $text = '';   # rebuild $text from the tokens

  foreach my $cur_token (@$tokens) {
    if ($cur_token->[0] eq "tag") {
      $cur_token->[1] =~  s! \\ !$g_escape_table{'\\'}!gx;
      $cur_token->[1] =~  s{ (?<=.)</?code>(?=.)  }{$g_escape_table{'`'}}gx;
      $cur_token->[1] =~  s! \* !$g_escape_table{'*'}!gx;
      $cur_token->[1] =~  s! _  !$g_escape_table{'_'}!gx;
    }
    $text .= $cur_token->[1];
  }
  return $text;
}


sub _DoAnchors {
  my $self = shift;
#
# Turn Markdown link shortcuts into XHTML <a> tags.
#
  my $text = shift;

  #
  # First, handle reference-style links: [link text] [id]
  #
  $text =~ s{
    (         # wrap whole match in $1
      \[
        ($g_nested_brackets)  # link text = $2
      \]

      [ ]?        # one optional space
      (?:\n[ ]*)?   # one optional newline followed by spaces

      \[
        (.*?)   # id = $3
      \]
    )
  }{
    my $result;
    my $whole_match = $1;
    my $link_text   = $2;
    my $link_id     = lc $3;

    if ($link_id eq "") {
      $link_id = lc $link_text;     # for shortcut links like [this][].
    }

    # Allow automatic cross-references to headers
    my $label = $self->Header2Label($link_id);
    if (defined $self->{_urls}{$link_id}) {
      my $url = $self->{_urls}{$link_id};
      $url =~ s! \* !$g_escape_table{'*'}!gx;   # We've got to encode these to avoid
      $url =~ s!  _ !$g_escape_table{'_'}!gx;   # conflicting with italics/bold.
      $result = "<a href=\"$url\"";
      if ( defined $self->{_titles}{$link_id} ) {
        my $title = $self->{_titles}{$link_id};
        $title =~ s! \* !$g_escape_table{'*'}!gx;
        $title =~ s!  _ !$g_escape_table{'_'}!gx;
        $result .=  " title=\"$title\"";
      }
      $result .= $self->_DoAttributes($label);
      $result .= ">$link_text</a>";
    } elsif (defined $self->{_crossrefs}{$label}) {
      my $url = $self->{_crossrefs}{$label};
      $url =~ s! \* !$g_escape_table{'*'}!gx;   # We've got to encode these to avoid
      $url =~ s!  _ !$g_escape_table{'_'}!gx;   # conflicting with italics/bold.
      $result = "<a href=\"$url\"";
      if ( defined $self->{_titles}{$label} ) {
        my $title = $self->{_titles}{$label};
        $title =~ s! \* !$g_escape_table{'*'}!gx;
        $title =~ s!  _ !$g_escape_table{'_'}!gx;
        $result .=  " title=\"$title\"";
      }
      $result .= $self->_DoAttributes($label);
      $result .= ">$link_text</a>";
    } else {
      $result = $whole_match;
    }
    $result;
  }xsge;

  #
  # Next, inline-style links: [link text](url "optional title")
  #
  $text =~ s{
    (       # wrap whole match in $1
      \[
        ($g_nested_brackets)  # link text = $2
      \]
      \(      # literal paren
        [ \t]*
      ($g_nested_parens)    # href = $3
        [ \t]*
      (     # $4
        (['"])  # quote char = $5
        (.*?)   # Title = $6
        \5    # matching quote
            [ \t]*  # ignore any spaces/tabs between closing quote and )
      )?      # title is optional
      \)
    )
  }{
    my $result;
    my $whole_match = $1;
    my $link_text   = $2;
    my $url       = $3;
    my $title   = $6;

    $url =~ s! \* !$g_escape_table{'*'}!gx;   # We've got to encode these to avoid
    $url =~ s!  _ !$g_escape_table{'_'}!gx;   # conflicting with italics/bold.
    $url =~ s{^<(.*)>$}{$1};          # Remove <>'s surrounding URL, if present
    $result = "<a href=\"$url\"";

    if (defined $title) {
      $title =~ s/"/&quot;/g;
      $title =~ s! \* !$g_escape_table{'*'}!gx;
      $title =~ s!  _ !$g_escape_table{'_'}!gx;
      $result .=  " title=\"$title\"";
    }
    $result .= ">$link_text</a>";

    $result;
  }xsge;

  #
  # Last, handle reference-style shortcuts: [link text]
  # These must come last in case you've also got [link test][1]
  # or [link test](/foo)
  #
  $text =~ s{
    (         # wrap whole match in $1
      \[
        ([^\[\]]+)    # link text = $2; can't contain '[' or ']'
      \]
    )
  }{
    my $result;
    my $whole_match = $1;
    my $link_text   = $2;
    (my $link_id = lc $2) =~ s{[ ]?\n}{ }g; # lower-case and turn embedded newlines into spaces

    # Allow automatic cross-references to headers
    my $label = $self->Header2Label($link_id);
    if (defined $self->{_urls}{$link_id}) {
      my $url = $self->{_urls}{$link_id};
      $url =~ s! \* !$g_escape_table{'*'}!gx;   # We've got to encode these to avoid
      $url =~ s!  _ !$g_escape_table{'_'}!gx;   # conflicting with italics/bold.
      $result = "<a href=\"$url\"";
      if ( defined $self->{_titles}{$link_id} ) {
        my $title = $self->{_titles}{$link_id};
        $title =~ s! \* !$g_escape_table{'*'}!gx;
        $title =~ s!  _ !$g_escape_table{'_'}!gx;
        $result .=  " title=\"$title\"";
      }
      $result .= $self->_DoAttributes($link_id);
      $result .= ">$link_text</a>";
    } elsif (defined $self->{_crossrefs}{$label}) {
      my $url = $self->{_crossrefs}{$label};
      $url =~ s! \* !$g_escape_table{'*'}!gx;   # We've got to encode these to avoid
      $url =~ s!  _ !$g_escape_table{'_'}!gx;   # conflicting with italics/bold.
      $result = "<a href=\"$url\"";
      if ( defined $self->{_titles}{$label} ) {
        my $title = $self->{_titles}{$label};
        $title =~ s! \* !$g_escape_table{'*'}!gx;
        $title =~ s!  _ !$g_escape_table{'_'}!gx;
        $result .=  " title=\"$title\"";
      }
      $result .= $self->_DoAttributes($label);
      $result .= ">$link_text</a>";
    } else {
      $result = $whole_match;
    }
    $result;
  }xsge;

  return $text;
}


sub _DoImages {
  my $self = shift;
#
# Turn Markdown image shortcuts into <img> tags.
#
  my $text = shift;

  #
  # First, handle reference-style labeled images: ![alt text][id]
  #
  $text =~ s{
    (       # wrap whole match in $1
      !\[
        (.*?)   # alt text = $2
      \]

      [ ]?        # one optional space
      (?:\n[ ]*)?   # one optional newline followed by spaces

      \[
        (.*?)   # id = $3
      \]

    )
  }{
    my $result;
    my $whole_match = $1;
    my $alt_text    = $2;
    my $link_id     = lc $3;

    if ($link_id eq "") {
      $link_id = lc $alt_text;     # for shortcut links like ![this][].
    }

    $alt_text =~ s/"/&quot;/g;
    if (defined $self->{_urls}{$link_id}) {
      my $url = $self->{_urls}{$link_id};
      $url =~ s! \* !$g_escape_table{'*'}!gx;   # We've got to encode these to avoid
      $url =~ s!  _ !$g_escape_table{'_'}!gx;   # conflicting with italics/bold.

      my $label = $self->Header2Label($alt_text);
      $self->{_crossrefs}{$label} = "#$label";
      if (! defined $self->{_titles}{$link_id}) {
        $self->{_titles}{$link_id} = $alt_text;
      }

      $result = "<img id=\"$label\" src=\"$url\" alt=\"$alt_text\"";
      if (defined $self->{_titles}{$link_id}) {
        my $title = $self->{_titles}{$link_id};
        $title =~ s! \* !$g_escape_table{'*'}!gx;
        $title =~ s!  _ !$g_escape_table{'_'}!gx;
        $result .=  " title=\"$title\"";
      }
      $result .= $self->_DoAttributes($link_id);
      $result .= $self->{params}{empty_element_suffix};
    }
    else {
      # If there's no such link ID, leave intact:
      $result = $whole_match;
    }

    $result;
  }xsge;

  #
  # Next, handle inline images:  ![alt text](url "optional title")
  # Don't forget: encode * and _

  $text =~ s{
    (       # wrap whole match in $1
      !\[
        (.*?)   # alt text = $2
      \]
      \s?     # One optional whitespace character
      \(      # literal paren
        [ \t]*
      ($g_nested_parens)    # href = $3
        [ \t]*
      (     # $4
        (['"])  # quote char = $5
        (.*?)   # title = $6
        \5    # matching quote
        [ \t]*
      )?      # title is optional
      \)
    )
  }{
    my $result;
    my $whole_match = $1;
    my $alt_text    = $2;
    my $url       = $3;
    my $title   = (defined $6) ? $6 : '';

    $alt_text =~ s/"/&quot;/g;
    $title    =~ s/"/&quot;/g;
    $url =~ s! \* !$g_escape_table{'*'}!gx;   # We've got to encode these to avoid
    $url =~ s!  _ !$g_escape_table{'_'}!gx;   # conflicting with italics/bold.
    $url =~ s{^<(.*)>$}{$1};          # Remove <>'s surrounding URL, if present

    my $label = $self->Header2Label($alt_text);
    $self->{_crossrefs}{$label} = "#$label";
#   $self->{_titles}{$label} = $alt_text;      # I think this line should not be here

    $result = "<img id=\"$label\" src=\"$url\" alt=\"$alt_text\"";
    if (defined $title) {
      $title =~ s! \* !$g_escape_table{'*'}!gx;
      $title =~ s!  _ !$g_escape_table{'_'}!gx;
      $result .=  " title=\"$title\"";
    }
    $result .= $self->{params}{empty_element_suffix};

    $result;
  }xsge;

  return $text;
}


sub _DoHeaders {
  my $self = shift;
  my $text = shift;
  my $header = "";
  my $label = "";
  my $idString = "";

  # Setext-style headers:
  #   Header 1
  #   ========
  #
  #   Header 2
  #   --------
  #
  $text =~ s{ ^(.+?)(?:\s*(?<!\\)\[([^\[]*?)\])?[ \t]*\n=+[ \t]*\n+ }{
    if (defined $2) {
      $label = $self->Header2Label($2);
    } else {
      $label = $self->Header2Label($1);
    }
    $header = $self->_RunSpanGamut($1);
    $header =~ s/^\s*//s;

    if ($label ne "") {
      $self->{_crossrefs}{$label} = "#$label";
      $self->{_titles}{$label} = $self->_StripHTML($header);
      $idString = " id=\"$label\"";
    } else {
      $idString = "";
    }
    my $h_level = $self->{params}{base_header_level};

    "<h$h_level$idString>"  .  $header  .  "</h$h_level>\n\n";
  }egmx;

  $text =~ s{ ^(.+?)(?:\s*(?<!\\)\[([^\[]*?)\])?[ \t]*\n-+[ \t]*\n+ }{
    if (defined $2) {
      $label = $self->Header2Label($2);
    } else {
      $label = $self->Header2Label($1);
    }
    $header = $self->_RunSpanGamut($1);
    $header =~ s/^\s*//s;

    if ($label ne "") {
      $self->{_crossrefs}{$label} = "#$label";
      $self->{_titles}{$label} = $self->_StripHTML($header);
      $idString = " id=\"$label\"";
    } else {
      $idString = "";
    }

    my $h_level = $self->{params}{base_header_level} +1;

    "<h$h_level$idString>"  .  $header  .  "</h$h_level>\n\n";
  }egmx;


  # atx-style headers:
  # # Header 1
  # ## Header 2
  # ## Header 2 with closing hashes ##
  # ...
  # ###### Header 6
  #
  $text =~ s{
      ^(\#{1,6})  # $1 = string of #'s
      [ \t]*
      (.+?)   # $2 = Header text
      [ \t]*
      (?:(?<!\\)\[([^\[]*?)\])? # $3 = optional label for cross-reference
      [ \t]*
      \#*     # optional closing #'s (not counted)
      \n+
    }{
      my $h_level = length($1) + $self->{params}{base_header_level} - 1;
      if (defined $3) {
        $label = $self->Header2Label($3);
      } else {
        $label = $self->Header2Label($2);
      }
      $header = $self->_RunSpanGamut($2);
      $header =~ s/^\s*//s;

      if ($label ne "") {
        $self->{_crossrefs}{$label} = "#$label";
        $self->{_titles}{$label} = $self->_StripHTML($header);
        $idString = " id=\"$label\"";
      } else {
        $idString = "";
      }

      "<h$h_level$idString>"  .  $header  .  "</h$h_level>\n\n";
    }egmx;

  return $text;
}


sub _DoLists {
  my $self = shift;
#
# Form HTML ordered (numbered) and unordered (bulleted) lists.
#
  my $text = shift;
  my $less_than_tab = $self->{params}{tab_width} - 1;

  # Re-usable patterns to match list item bullets and number markers:
  my $marker_ul  = qr/[*+-]/;
  my $marker_ol  = qr/\d+[.]/;
  my $marker_any = qr/(?:$marker_ul|$marker_ol)/;

  # Re-usable pattern to match any entirel ul or ol list:
  my $whole_list = qr{
    (               # $1 = whole list
      (               # $2
      [ ]{0,$less_than_tab}
      (${marker_any})       # $3 = first list item marker
      [ \t]+
      )
      (?s:.+?)
      (               # $4
        \z
      |
        \n{2,}
        (?=\S)
        (?!           # Negative lookahead for another list item marker
        [ \t]*
        ${marker_any}[ \t]+
        )
      )
    )
  }mx;

  # We use a different prefix before nested lists than top-level lists.
  # See extended comment in _ProcessListItems().
  #
  # Note: There's a bit of duplication here. My original implementation
  # created a scalar regex pattern as the conditional result of the test on
  # $self->{_list_level}, and then only ran the $text =~ s{...}{...}egmx
  # substitution once, using the scalar as the pattern. This worked,
  # everywhere except when running under MT on my hosting account at Pair
  # Networks. There, this caused all rebuilds to be killed by the reaper (or
  # perhaps they crashed, but that seems incredibly unlikely given that the
  # same script on the same server ran fine *except* under MT. I've spent
  # more time trying to figure out why this is happening than I'd like to
  # admit. My only guess, backed up by the fact that this workaround works,
  # is that Perl optimizes the substition when it can figure out that the
  # pattern will never change, and when this optimization isn't on, we run
  # afoul of the reaper. Thus, the slightly redundant code that uses two
  # static s/// patterns rather than one conditional pattern.

  if ($self->{_list_level}) {
    $text =~ s{
        ^
        $whole_list
      }{
        my $list = $1;
        my $list_type = ($3 =~ m/$marker_ul/) ? "ul" : "ol";

        # Turn double returns into triple returns, so that we can make a
        # paragraph for the last item in a list, if necessary:
        $list =~ s/\n{2,}/\n\n\n/g;
        my $result = $self->_ProcessListItems($list, $marker_any);

        # Trim any trailing whitespace, to put the closing `</$list_type>`
        # up on the preceding line, to get it past the current stupid
        # HTML block parser. This is a hack to work around the terrible
        # hack that is the HTML block parser.
        $result =~ s{\s+$}{};
        $result = "<$list_type>" . $result . "</$list_type>\n";
        $result;
      }egmx;
  }
  else {
    $text =~ s{
        (?:(?<=\n\n)|\A\n?)
        $whole_list
      }{
        my $list = $1;
        my $list_type = ($3 =~ m/$marker_ul/) ? "ul" : "ol";
        # Turn double returns into triple returns, so that we can make a
        # paragraph for the last item in a list, if necessary:
        $list =~ s/\n{2,}/\n\n\n/g;
        my $result = $self->_ProcessListItems($list, $marker_any);
        $result = "<$list_type>\n" . $result . "</$list_type>\n";
        $result;
      }egmx;
  }


  return $text;
}


sub _ProcessListItems {
  my $self = shift;
#
# Process the contents of a single ordered or unordered list, splitting it
# into individual list items.
#

  my $list_str = shift;
  my $marker_any = shift;


  # The $self->{_list_level} global keeps track of when we're inside a list.
  # Each time we enter a list, we increment it; when we leave a list,
  # we decrement. If it's zero, we're not in a list anymore.
  #
  # We do this because when we're not inside a list, we want to treat
  # something like this:
  #
  #   I recommend upgrading to version
  #   8. Oops, now this line is treated
  #   as a sub-list.
  #
  # As a single paragraph, despite the fact that the second line starts
  # with a digit-period-space sequence.
  #
  # Whereas when we're inside a list (or sub-list), that line will be
  # treated as the start of a sub-list. What a kludge, huh? This is
  # an aspect of Markdown's syntax that's hard to parse perfectly
  # without resorting to mind-reading. Perhaps the solution is to
  # change the syntax rules such that sub-lists must start with a
  # starting cardinal number; e.g. "1." or "a.".

  $self->{_list_level}++;

  # trim trailing blank lines:
  $list_str =~ s/\n{2,}\z/\n/;


  $list_str =~ s{
    (\n)?             # leading line = $1
    (^[ \t]*)           # leading whitespace = $2
    ($marker_any) [ \t]+      # list marker = $3
    ((?s:.+?)           # list item text   = $4
    (\n{1,2}))
    (?= \n* (\z | \2 ($marker_any) [ \t]+))
  }{
    my $item = $4;
    my $leading_line = $1;
    my $leading_space = $2;

    if ($leading_line or ($item =~ m/\n{2,}/)) {
      $item = $self->_RunBlockGamut($self->_Outdent($item));
    }
    else {
      # Recursion for sub-lists:
      $item = $self->_DoLists($self->_Outdent($item));
      chomp $item;
      $item = $self->_RunSpanGamut($item);
    }

    "<li>" . $item . "</li>\n";
  }egmx;

  $self->{_list_level}--;
  return $list_str;
}

sub _DoCodeBlocks {
  my $self = shift;
#
# Process Markdown `<pre><code>` blocks.
#

  my $text = shift;

  $text =~ s{
      (?:\n+|\A)
      (             # $1 = the code block -- one or more lines, starting with a space/tab
        (?:
          (?:[ ]{$self->{params}{tab_width}} | \t)  # Lines must start with a tab or a tab-width of spaces
          .*\n+
        )+
      )
      ((?=^[ ]{0,$self->{params}{tab_width}}\S)|\Z) # Lookahead for non-space at line-start, or end of doc
    }{
      my $codeblock = $1;
      my $result; # return value

      $codeblock = $self->_EncodeCode($self->_Outdent($codeblock));
      $codeblock = $self->_Detab($codeblock);
      $codeblock =~ s/\A\n+//; # trim leading newlines
      $codeblock =~ s/\n+\z//; # trim trailing newlines

      $result = "\n\n<pre><code>" . $codeblock . "</code></pre>\n\n"; # CHANGED: Removed newline for MMD

      $result;
    }egmx;

  return $text;
}

sub _DoFencedCodeBlocks {
  my $self = shift;
#
# Process Markdown `<pre><code>` blocks.
#


  my $text = shift;
  $text =~ s{
      ```(.*)\n           # leader
      (             # $1 = the code block -- one or more lines, starting with a space/tab
        (?:
          (?!```)
          .*\n+
        )+
      )
      ((?=```)|\Z) # Lookahead for fence-end, or end of doc
      ```
    }{
      my $language = $1;
      my $codeblock = $2;
      my $result; # return value

      $codeblock = $self->_EncodeCode($codeblock);
      $codeblock =~ s/\A\n+//; # trim leading newlines
      $codeblock =~ s/\n+\z//; # trim trailing newlines

      $result = "\n\n<pre><code class=\"" . $language . "\">" . $codeblock . "</code></pre>\n\n"; # CHANGED: Removed newline for MMD

      $result;
    }egmx;

  return $text;
}


sub _DoCodeSpans {
  my $self = shift;
#
#   * Backtick quotes are used for <code></code> spans.
#
#   * You can use multiple backticks as the delimiters if you want to
#     include literal backticks in the code span. So, this input:
#
#         Just type ``foo `bar` baz`` at the prompt.
#
#       Will translate to:
#
#         <p>Just type <code>foo `bar` baz</code> at the prompt.</p>
#
#   There's no arbitrary limit to the number of backticks you
#   can use as delimters. If you need three consecutive backticks
#   in your code, use four for delimiters, etc.
#
# * You can use spaces to get literal backticks at the edges:
#
#         ... type `` `bar` `` ...
#
#       Turns to:
#
#         ... type <code>`bar`</code> ...
#

  my $text = shift;

  $text =~ s@
      (?<!\\)   # Character before opening ` can't be a backslash
      (`+)    # $1 = Opening run of `
      (.+?)   # $2 = The code block
      (?<!`)
      \1      # Matching closer
      (?!`)
    @
      my $c = "$2";
      $c =~ s/^[ \t]*//g; # leading whitespace
      $c =~ s/[ \t]*$//g; # trailing whitespace
      $c = $self->_EncodeCode($c);
      "<code>$c</code>";
    @egsx;

  return $text;
}


sub _EncodeCode {
  my $self = shift;
#
# Encode/escape certain characters inside Markdown code runs.
# The point is that in code, these characters are literals,
# and lose their special Markdown meanings.
#
    local $_ = shift;

  # Encode all ampersands; HTML entities are not
  # entities within a Markdown code span.
  s/&/&amp;/g;

  # Do the angle bracket song and dance:
  s! <  !&lt;!gx;
  s! >  !&gt;!gx;

  # Now, escape characters that are magic in Markdown:
  s! \* !$g_escape_table{'*'}!gx;
  s! _  !$g_escape_table{'_'}!gx;
  s! {  !$g_escape_table{'{'}!gx;
  s! }  !$g_escape_table{'}'}!gx;
  s! \[ !$g_escape_table{'['}!gx;
  s! \] !$g_escape_table{']'}!gx;
  s! \\ !$g_escape_table{'\\'}!gx;
  s! \# !$g_escape_table{'#'}!gx;

  return $_;
}


sub _DoItalicsAndBold {
  my $self = shift;
  my $text = shift;

  # Cave in - `*` and `_` behave differently...  We'll see how it works out


  # <strong> must go first:
  $text =~ s{ (?<!\w) (\*\*|__) (?=\S) (.+?[*_]*) (?<=\S) \1 }
    {<strong>$2</strong>}gsx;

  $text =~ s{ (?<!\w) (\*|_) (?=\S) (.+?) (?<=\S) \1 }
    {<em>$2</em>}gsx;

  # And now, a second pass to catch nested strong and emphasis special cases
  $text =~ s{ (?<!\w) (\*\*|__) (?=\S) (.+?[*_]*) (?<=\S) \1 }
    {<strong>$2</strong>}gsx;

  $text =~ s{ (?<!\w) (\*|_) (?=\S) (.+?) (?<=\S) \1 }
    {<em>$2</em>}gsx;

  # And now, allow `*` in the middle of words

  # <strong> must go first:
  $text =~ s{ (\*\*) (?=\S) (.+?[*]*) (?<=\S) \1 }
    {<strong>$2</strong>}gsx;

  $text =~ s{ (\*) (?=\S) (.+?) (?<=\S) \1 }
    {<em>$2</em>}gsx;

  return $text;
}


sub _DoBlockQuotes {
  my $self = shift;
  my $text = shift;

  $text =~ s{
      (                 # Wrap whole match in $1
       (
        ^[ \t]*>[ \t]?  # '>' at the start of a line
          .+\n          # rest of the first line
        (.+\n)*         # subsequent consecutive lines
        \n*             # blanks
       )+
      )
    }{
      my $bq = $1;
      $bq =~ s/^[ \t]*>[ \t]?//gm;      # trim one level of quoting
      $bq =~ s/^[ \t]+$//mg;            # trim whitespace-only lines
      $bq = $self->_RunBlockGamut($bq); # recurse

      $bq =~ s/^/  /g;
      # These leading spaces screw with <pre> content, so we need to fix that:
      $bq =~ s{
          (\s*<pre>.+?</pre>)
        }{
          my $pre = $1;
          $pre =~ s/^  //mg;
          $pre;
        }egsx;

      "<blockquote>\n$bq\n</blockquote>\n\n";
    }egmx;


  return $text;
}


sub _FormParagraphs {
  my $self = shift;
#
# Params:
#   $text - string to process with html <p> tags
#
  my $text = shift;

  # Strip leading and trailing lines:
  $text =~ s/\A\n+//;
  $text =~ s/\n+\z//;

  my @grafs = split(/\n{2,}/, $text);

  #
  # Wrap <p> tags.
  #
  foreach (@grafs) {
    unless (defined( $self->{_html_blocks}{$_} )) {
      $_ = $self->_RunSpanGamut($_);
      s/^([ \t]*)/<p>/;
      $_ .= "</p>";
    }
  }

  #
  # Unhashify HTML blocks
  #
#   foreach my $graf (@grafs) {
#     my $block = $self->{_html_blocks}{$graf};
#     if (defined $block) {
#       $graf = $block;
#     }
#   }

  foreach my $graf (@grafs) {
    # Modify elements of @grafs in-place...
    my $block = $self->{_html_blocks}{$graf};
    if (defined $block) {
      $graf = $block;
      if ($block =~ m{
              \A
              (             # $1 = <div> tag
                <div  \s+
                [^>]*
                \b
                markdown\s*=\s*  (['"]) # $2 = attr quote char
                1
                \2
                [^>]*
                >
              )
              (             # $3 = contents
              .*
              )
              (</div>)          # $4 = closing tag
              \z

              }xms
        ) {
        my ($div_open, $div_content, $div_close) = ($1, $3, $4);

        # We can't call Markdown(), because that resets the hash;
        # that initialization code should be pulled into its own sub, though.
        $div_content = $self->_HashHTMLBlocks($div_content);
        $div_content = $self->_StripLinkDefinitions($div_content);
        $div_content = $self->_RunBlockGamut($div_content);
        $div_content = $self->_UnescapeSpecialChars($div_content);

        $div_open =~ s{\smarkdown\s*=\s*(['"]).+?\1}{}ms;

        $graf = $div_open . "\n" . $div_content . "\n" . $div_close;
      }
    }
  }


  return join "\n\n", @grafs;
}


sub _EncodeAmpsAndAngles {
  my $self = shift;
# Smart processing for ampersands and angle brackets that need to be encoded.

  my $text = shift;

  # Ampersand-encoding based entirely on Nat Irons's Amputator MT plugin:
  #   http://bumppo.net/projects/amputator/
  $text =~ s/&(?!#?[xX]?(?:[0-9a-fA-F]+|\w+);)/&amp;/g;

  # Encode naked <'s
  $text =~ s{<(?![a-z/?\$!])}{&lt;}gi;

  return $text;
}


sub _EncodeBackslashEscapes {
  my $self = shift;
#
#   Parameter:  String.
#   Returns:    The string, with after processing the following backslash
#               escape sequences.
#
    local $_ = shift;

    s! \\\\  !$g_escape_table{'\\'}!gx;   # Must process escaped backslashes first.
    s! \\`   !$g_escape_table{'`'}!gx;
    s! \\\*  !$g_escape_table{'*'}!gx;
    s! \\_   !$g_escape_table{'_'}!gx;
    s! \\\{  !$g_escape_table{'{'}!gx;
    s! \\\}  !$g_escape_table{'}'}!gx;
    s! \\\[  !$g_escape_table{'['}!gx;
    s! \\\]  !$g_escape_table{']'}!gx;
    s! \\\(  !$g_escape_table{'('}!gx;
    s! \\\)  !$g_escape_table{')'}!gx;
    s! \\>   !$g_escape_table{'>'}!gx;
    s! \\\#  !$g_escape_table{'#'}!gx;
    s! \\\+  !$g_escape_table{'+'}!gx;
    s! \\\-  !$g_escape_table{'-'}!gx;
    s! \\\.  !$g_escape_table{'.'}!gx;
    s{ \\!  }{$g_escape_table{'!'}}gx;

    return $_;
}


sub _DoAutoLinks {
  my $self = shift;
  my $text = shift;

  $text =~ s{<((https?|ftp|dict):[^'">\s]+)>}{<a href="$1">$1</a>}gi;

  # Email addresses: <address@domain.foo>
  $text =~ s{
    <
        (?:mailto:)?
    (
      [-.\w]+
      \@
      [-a-z0-9]+(\.[-a-z0-9]+)*\.[a-z]+
    )
    >
  }{
    $self->_EncodeEmailAddress( $self->_UnescapeSpecialChars($1) );
  }egix;

  return $text;
}


sub _EncodeEmailAddress {
  my $self = shift;
#
# Input: an email address, e.g. "foo@example.com"
#
# Output: the email address as a mailto link, with each character
#   of the address encoded as either a decimal or hex entity, in
#   the hopes of foiling most address harvesting spam bots. E.g.:
#
#   <a href="&#x6D;&#97;&#105;&#108;&#x74;&#111;:&#102;&#111;&#111;&#64;&#101;
#       x&#x61;&#109;&#x70;&#108;&#x65;&#x2E;&#99;&#111;&#109;">&#102;&#111;&#111;
#       &#64;&#101;x&#x61;&#109;&#x70;&#108;&#x65;&#x2E;&#99;&#111;&#109;</a>
#
# Based on a filter by Matthew Wickline, posted to the BBEdit-Talk
# mailing list: <http://tinyurl.com/yu7ue>
#

  my $addr = shift;

  srand;
  my @encode = (
    sub { '&#' .                 ord(shift)   . ';' },
    sub { '&#x' . sprintf( "%X", ord(shift) ) . ';' },
    sub {                            shift          },
  );

  $addr = "mailto:" . $addr;

  $addr =~ s{(.)}{
    my $char = $1;
    if ( $char eq '@' ) {
      # this *must* be encoded. I insist.
      $char = $encode[int rand 1]->($char);
    } elsif ( $char ne ':' ) {
      # leave ':' alone (to spot mailto: later)
      my $r = rand;
      # roughly 10% raw, 45% hex, 45% dec
      $char = (
        $r > .9   ?  $encode[2]->($char)  :
        $r < .45  ?  $encode[1]->($char)  :
               $encode[0]->($char)
      );
    }
    $char;
  }gex;

  $addr = qq{<a href="$addr">$addr</a>};
  $addr =~ s{">.+?:}{">}; # strip the mailto: from the visible part

  return $addr;
}


sub _UnescapeSpecialChars {
  my $self = shift;
#
# Swap back in all the special characters we've hidden.
#
  my $text = shift;

  while( my($char, $hash) = each(%g_escape_table) ) {
    $text =~ s/$hash/$char/g;
  }
    return $text;
}


sub _TokenizeHTML {
  my $self = shift;
#
#   Parameter:  String containing HTML markup.
#   Returns:    Reference to an array of the tokens comprising the input
#               string. Each token is either a tag (possibly with nested,
#               tags contained therein, such as <a href="<MTFoo>">, or a
#               run of text between tags. Each element of the array is a
#               two-element array; the first is either 'tag' or 'text';
#               the second is the actual value.
#
#
#   Derived from the _tokenize() subroutine from Brad Choate's MTRegex plugin.
#       <http://www.bradchoate.com/past/mtregex.php>
#

    my $str = shift;
    my $pos = 0;
    my $len = length $str;
    my @tokens;

    my $depth = 6;
    my $nested_tags = join('|', ('(?:<[a-z/!$](?:[^<>]') x $depth) . (')*>)' x  $depth);
    my $match = qr/(?s: <! ( -- .*? -- \s* )+ > ) |  # comment
                   (?s: <\? .*? \?> ) |              # processing instruction
                   $nested_tags/ix;                   # nested tags

    while ($str =~ m/($match)/g) {
        my $whole_tag = $1;
        my $sec_start = pos $str;
        my $tag_start = $sec_start - length $whole_tag;
        if ($pos < $tag_start) {
            push @tokens, ['text', substr($str, $pos, $tag_start - $pos)];
        }
        push @tokens, ['tag', $whole_tag];
        $pos = pos $str;
    }
    push @tokens, ['text', substr($str, $pos, $len - $pos)] if $pos < $len;

    return \@tokens;
}


sub _Outdent {
  my $self = shift;
#
# Remove one level of line-leading tabs or spaces
#
  my $text = shift;

  $text =~ s/^(\t|[ ]{1,$self->{params}{tab_width}})//gm;
  return $text;
}


sub _Detab {
  my $self = shift;
#
# Cribbed from a post by Bart Lateur:
# <http://www.nntp.perl.org/group/perl.macperl.anyperl/154>
#
  my $text = shift;

  $text =~ s{(.*?)\t}{$1.(' ' x ($self->{params}{tab_width} - length($1) % $self->{params}{tab_width}))}ge;
  return $text;
}

#
# MultiMarkdown Routines
#

sub _ParseMetaData {
  my $self = shift;
  my $text = shift;
  my $clean_text = "";

  my ($inMetaData, $currentKey) = (1,'');

  # If only metadata is "Format: complete" then skip

  if ($text =~ s/^(Format):\s*complete\n(.*?)\n/$2\n/is) {
    # If "Format: complete" was added automatically, don't force first
    # line of text to be metadata
    $self->{_metadata}{$1}= "complete";
    $self->{params}{document_format} = "complete";
  }

  foreach my $line ( split /\n/, $text ) {
    $line =~ /^$/ and $inMetaData = 0;
    if ($inMetaData) {
      if ($line =~ /^([a-zA-Z0-9][0-9a-zA-Z _-]*?):\s*(.*)$/ ) {
        $currentKey = $1;
        my $meta = $2;
        $currentKey =~ s/\s+/ /g;
        $currentKey =~ s/\s$//;
        $self->{_metadata}{$currentKey} = $meta;
        if (lc($currentKey) eq "format") {
          $self->{params}{document_format} = lc($self->{_metadata}{$currentKey});
        }
        if (lc($currentKey) eq "base url") {
          $self->{_base_url} = $self->{_metadata}{$currentKey};
        }
        if (lc($currentKey) eq "bibliography title") {
          $self->{params}{bibliography_title} = $self->{_metadata}{$currentKey};
          $self->{params}{bibliography_title} =~ s/\s*$//;
        }
        if (lc($currentKey) eq "base header level") {
          $self->{params}{base_header_level} = $self->{_metadata}{$currentKey};
        }
        if (!$self->{_metadata_newline}{$currentKey}) {
          $self->{_metadata_newline}{$currentKey} = $self->{_metadata_newline}{default};
        }
      } else {
        if ($currentKey eq "") {
          # No metadata present
          $clean_text .= "$line\n";
          $inMetaData = 0;
          next;
        }
        if ($line =~ /^\s*(.+)$/ ) {
          $self->{_metadata}{$currentKey} .= "$self->{_metadata}_newline{$currentKey}$1";
        }
      }
    } else {
      $clean_text .= "$line\n";
    }
  }

  return $clean_text;
}

sub _StripFootnoteDefinitions {
  my $self = shift;
  my $text = shift;
  my $less_than_tab = $self->{params}{tab_width} - 1;

  while ($text =~ s{
    \n[ ]{0,$less_than_tab}\[\^([^\n]+?)\]\:[ \t]*# id = $1
    \n?
    (.*?)\n{1,2}    # end at new paragraph
    ((?=\n[ ]{0,$less_than_tab}\S)|\Z)  # Lookahead for non-space at line-start, or end of doc
  }
  {\n}sx)
  {
    my $id = $1;
    my $footnote = "$2\n";
    $footnote =~ s/^[ ]{0,$self->{params}{tab_width}}//gm;

    $self->{_footnotes}{ $self->id2footnote($id) } = $footnote;
  }

  return $text;
}

sub _DoFootnotes {
  my $self = shift;
  my $text = shift;

  # First, run routines that get skipped in footnotes
  foreach my $label (sort keys %{$self->{_footnotes}}) {
    my $footnote = $self->_RunBlockGamut($self->{_footnotes}{$label});

    $footnote = $self->_DoMarkdownCitations($footnote);
    $self->{_footnotes}{$label} = $footnote;
  }

  $text =~ s{
    \[\^(.+?)\]   # id = $1
  }{
    my $result = "";
    my $id = $self->id2footnote($1);
    if (defined $self->{_footnotes}{$id} ) {
      $self->{_footnote_counter}++;
      if ($self->{_footnotes}{$id} =~ /^(<p>)?glossary:/i) {
        $result = "<a href=\"#fn:$id\" id=\"fnref:$id\" title=\"see glossary\" class=\"footnote glossary\"><sup>$self->{_footnote_counter}</sup></a>";
      } else {
        $result = "<a href=\"#fn:$id\" id=\"fnref:$id\" title=\"see footnote\" class=\"footnote\"><sup>$self->{_footnote_counter}</sup></a>";
      }
      push (@{$self->{_used_footnotes}},$id);
    }
    $result;
  }xsge;

  return $text;
}

sub _FixFootnoteParagraphs {
  my $self = shift;
  my $text = shift;

  $text =~ s/^\<p\>\<\/footnote\>/<\/footnote>/gm;

  return $text;
}

sub _PrintFootnotes{
  my $self = shift;
  my $footnote_counter = 0;
  my $result = "";

  foreach my $id (@{$self->{_used_footnotes}}) {
    $footnote_counter++;
    my $footnote = $self->{_footnotes}{$id};
    my $footnote_closing_tag = "";

    $footnote =~ s/(\<\/(p(re)?|ol|ul)\>)$//;
    $footnote_closing_tag = $1;

    if ($footnote =~ s/^(<p>)?glossary:\s*//i) {
      # Add some formatting for glossary entries

      $footnote =~ s{
        ^(.*?)        # $1 = term
        \s*
        (?:\(([^\(\)]*)\)[^\n]*)?   # $2 = optional sort key
        \n
      }{
        my $glossary = "<span class=\"glossary name\">$1</span>";

        if ($2) {
          $glossary.="<span class=\"glossary sort\" style=\"display:none\">$2</span>";
        };

        $glossary . ":<p>";
      }egsx;

      $result.="<li id=\"fn:$id\">$footnote<a href=\"#fnref:$id\" title=\"return to article\" class=\"reversefootnote\">&#160;&#8617;</a>$footnote_closing_tag</li>\n\n";
    } else {
      $result.="<li id=\"fn:$id\">$footnote<a href=\"#fnref:$id\" title=\"return to article\" class=\"reversefootnote\">&#160;&#8617;</a>$footnote_closing_tag</li>\n\n";
    }
  }
  $result .= "</ol>\n</div>";

  if ($footnote_counter > 0) {
    $result = "\n\n<div class=\"footnotes\">\n<hr$self->{params}{empty_element_suffix}\n<ol>\n\n".$result;
  } else {
    $result = "";
  }

  $result= $self->_UnescapeSpecialChars($result);
  return $result;
}

sub Header2Label {
  my $self = shift;
  my $header = shift;
  my $label = lc $header;
  $label =~ s/[^A-Za-z0-9:_.-]//g;    # Strip illegal characters
  while ($label =~ s/^[^A-Za-z]//g)
    {};   # Strip illegal leading characters
  return $label;
}

sub id2footnote {
  my $self = shift;
  # Since we prepend "fn:", we can allow leading digits in footnotes
  my $id = shift;
  my $footnote = lc $id;
  $footnote =~ s/[^A-Za-z0-9:_.-]//g;   # Strip illegal characters
  return $footnote;
}


sub xhtmlMetaData {
  my $self = shift;
  my $result = qq{<?xml version="1.0" encoding="UTF-8" ?>\n};

  # This screws up xsltproc - make sure to use `-nonet -novalid` if you
  # have difficulty
  if( $self->{params}{allow_mathml} ) {
     $result .= qq{<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1 plus MathML 2.0//EN"\n\t"http://www.w3.org/TR/2001/REC-MathML2-20010221/dtd/xhtml-math11-f.dtd">
\n};

    $result.= qq{<html xmlns="http://www.w3.org/1999/xhtml">\n\t<head>\n};
  } else {
    $result .= qq{<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">\n};

    $result.= qq!<html xmlns="http://www.w3.org/1999/xhtml">\n\t<head>\n!;
  }

  $result.= "\t\t<!-- Processed by MultiMarkdown -->\n";

  foreach my $key (sort keys %{$self->{_metadata}} ) {
    # Strip trailing spaces
    $self->{_metadata}{$key} =~ s/(\s)*$//s;

    # Strip spaces from key
    my $export_key = $key;
    $export_key =~ s/\s//g;

    if (lc($key) eq "title") {
      $result.= "\t\t<title>" . $self->_EncodeAmpsAndAngles($self->{_metadata}{$key}) . "</title>\n";
    } elsif (lc($key) eq "css") {
      $result.= "\t\t<link type=\"text/css\" rel=\"stylesheet\" href=\"$self->{_metadata}{$key}\"$self->{params}{empty_element_suffix}\n";
    } elsif (lc($export_key) eq "xhtmlheader") {
      $result .= "\t\t$self->{_metadata}{$key}\n";
    } else {
      my $encodedMeta = $self->_EncodeAmpsAndAngles($self->{_metadata}{$key});
      $result.= qq!\t\t<meta name="$export_key" content="$encodedMeta"$self->{params}{empty_element_suffix}\n!;
    }
  }
  $result.= "\t</head>\n";

  return $result;
}

sub textMetaData {
  my $self = shift;
  my $result = "";

  foreach my $key (sort keys %{$self->{_metadata}} ) {
    $result .= "$key: $self->{_metadata}{$key}\n";
  }
  $result =~ s/\s*\n/<br \/>\n/g;

  if ($result ne "") {
    $result.= "\n";
  }

  return $result;
}

sub _ConvertCopyright{
  my $self = shift;
  my $text = shift;
  # Convert to an XML compatible form of copyright symbol

  $text =~ s/&copy;/&#xA9;/gi;

  return $text;
}


sub _DoTables {
  my $self = shift;
  my $text = shift;
  my $less_than_tab = $self->{params}{tab_width} - 1;

  # Algorithm inspired by PHP Markdown Extra's table support
  # <http://www.michelf.com/projects/php-markdown/>

  # Reusable regexp's to match table

  my $line_start = qr{
    [ ]{0,$less_than_tab}
  }mx;

  my $table_row = qr{
    [^\n]*?\|[^\n]*?\n
  }mx;

  my $first_row = qr{
    $line_start
    \S+.*?\|.*?\n
  }mx;

  my $table_rows = qr{
    (\n?$table_row)
  }mx;

  my $table_caption = qr{
    $line_start
    \[.*?\][ \t]*\n
  }mx;

  my $table_divider = qr{
    $line_start
    [\|\-\+\:\.][ \-\+\|\:\.]* \| [ \-\+\|\:\.]*
  }mx;

  my $whole_table = qr{
    ($table_caption)?   # Optional caption
    ($first_row       # First line must start at beginning
    ($table_row)*?)?    # Header Rows
    $table_divider      # Divider/Alignment definitions
    $table_rows+      # Body Rows
    ($table_caption)?   # Optional caption
  }mx;


  # Find whole tables, then break them up and process them

  $text =~ s{
    ^($whole_table)     # Whole table in $1
    (\n|\Z)         # End of file or 2 blank lines
  }{
    my $table = $1;

    # Clean extra spaces at end of lines -
    # they cause the processing to choke
    $table =~ s/[\t ]*\n/\n/gs;

    my $result = "<table>\n";
    my @alignments;
    my $use_row_header = 1;

    # Add Caption, if present

    if ($table =~ s/^$line_start(?:\[\s*(.*)\s*\])?(?:\[\s*(.*?)\s*\])[ \t]*$//m) {
      my $table_id = "";
      my $table_caption = "";

      $table_id = $self->Header2Label($2);

      if (defined $1) {
        $table_caption = $1;
      } else {
        $table_caption = $2;
      }
      $result .= "<caption id=\"$table_id\">" . $self->_RunSpanGamut($table_caption). "</caption>\n";

      $self->{_crossrefs}{$table_id} = "#$table_id";
      $self->{_titles}{$table_id} = "see table";   # captions with "stuff" in them break links
    }

    # If a second "caption" is present, treat it as a summary
    # However, this is not valid in XHTML 1.0 Strict
    # But maybe in future

    # A summary might be longer than one line
    if ($table =~ s/\n$line_start\[\s*(.*?)\s*\][ \t]*\n/\n/s) {
      # $result .= "<summary>" . $self->_RunSpanGamut($1) . "</summary>\n";
    }

    # Now, divide table into header, alignment, and body

    # First, add leading \n in case there is no header

    $table = "\n" . $table;

    # Need to be greedy

    $table =~ s/\n($table_divider)\n(($table_rows)+)//s;

    my $body = "";
    my $alignment_string = "";
    if (defined $1){
      $alignment_string = $1;
    }
    if (defined $2){
      $body = $2;
    }

    # Process column alignment
    while ($alignment_string =~ /\|?\s*(.+?)\s*(\||\Z)/gs) {
      my $cell = $self->_RunSpanGamut($1);
      if ($cell =~ /\+/){
        $result .= "<col class=\"extended\"";
      } else {
        $result .= "<col";
      }
      if ($cell =~ /\:$/) {
        if ($cell =~ /^\:/) {
          $result .= " align=\"center\"$self->{params}{empty_element_suffix}\n";
          push(@alignments,"center");
        } else {
          $result .= " align=\"right\"$self->{params}{empty_element_suffix}\n";
          push(@alignments,"right");
        }
      } else {
        if ($cell =~ /^\:/) {
          $result .= " align=\"left\"$self->{params}{empty_element_suffix}\n";
          push(@alignments,"left");
        } else {
          if (($cell =~ /^\./) || ($cell =~ /\.$/)) {
            $result .= " align=\"char\"$self->{params}{empty_element_suffix}\n";
            push(@alignments,"char");
          } else {
            $result .= "$self->{params}{empty_element_suffix}\n";
            push(@alignments,"");
          }
        }
      }
    }

    # Process headers
    $table =~ s/^\n+//s;

    $result .= "<thead>\n";

    # Strip blank lines
    $table =~ s/\n[ \t]*\n/\n/g;

    foreach my $line (split(/\n/, $table)) {
      # process each line (row) in table
      $result .= "<tr>\n";
      my $count=0;
      while ($line =~ /\|?\s*([^\|]+?)\s*(\|+|\Z)/gs) {
        # process contents of each cell
        my $cell = $self->_RunSpanGamut($1);
        my $ending = $2;
        my $colspan = "";
        if ($ending =~ s/^\s*(\|{2,})\s*$/$1/) {
          $colspan = " colspan=\"" . length($ending) . "\"";
        }
        $result .= "\t<th$colspan>$cell</th>\n";
        if ( $count == 0) {
          if ($cell =~ /^\s*$/) {
            $use_row_header = 1;
          } else {
            $use_row_header = 0;
          }
        }
        $count++;
      }
      $result .= "</tr>\n";
    }

    # Process body

    $result .= "</thead>\n<tbody>\n";

    foreach my $line (split(/\n/, $body)) {
      # process each line (row) in table
      if ($line =~ /^\s*$/) {
        $result .= "</tbody>\n\n<tbody>\n";
        next;
      }
      $result .= "<tr>\n";
      my $count=0;
      while ($line =~ /\|?\s*([^\|]+?)\s*(\|+|\Z)/gs) {
        # process contents of each cell
        my $cell = $self->_RunSpanGamut($1);
        my $ending = "";
        if ($2 ne ""){
          $ending = $2;
        }
        my $colspan = "";
        my $cell_type = "td";
        if ($count == 0 && $use_row_header == 1) {
          $cell_type = "th";
        }
        if ($ending =~ s/^\s*(\|{2,})\s*$/$1/) {
          $colspan = " colspan=\"" . length($ending) . "\"";
        }
        if ($alignments[$count] !~ /^\s*$/) {
          $result .= "\t<$cell_type$colspan align=\"$alignments[$count]\">$cell</$cell_type>\n";
        } else {
          $result .= "\t<$cell_type$colspan>$cell</$cell_type>\n";
          }
        $count++;
      }
      $result .= "</tr>\n";
    }

    # Strip out empty <thead> sections
    $result =~ s/<thead>\s*<\/thead>\s*//s;

    # Handle pull-quotes

    # This might be too specific for my needs.  If others want it
    # removed, I am open to discussion.

    $result =~ s/<table>\s*<col \/>\s*<tbody>/<table class="pull-quote">\n<col \/>\n<tbody>/s;

    $result .= "</tbody>\n</table>\n";
    $result
  }egmx;

  my $table_body = qr{
    (               # wrap whole match in $2

      (.*?\|.*?)\n          # wrap headers in $3

      [ ]{0,$less_than_tab}
      ($table_divider)  # alignment in $4

      (             # wrap cells in $5
        $table_rows
      )
    )
  }mx;

  return $text;
}


sub _DoAttributes{
  my $self = shift;
  my $id = shift;
  my $result = "";

  if (defined $self->{_attributes}{$id}) {
    my $attributes = $self->{_attributes}{$id};
    while ($attributes =~ s/(\S+)="(.*?)"//) {
      $result .= " $1=\"$2\"";
    }
    while ($attributes =~ /(\S+)=(\S+)/g) {
      $result .= " $1=\"$2\"";
    }
  }

  return $result;
}


sub _StripMarkdownReferences {
  my $self = shift;
  my $text = shift;
  my $less_than_tab = $self->{params}{tab_width} - 1;

  while ($text =~ s{
    \n\[\#(.+?)\]:[ \t]*  # id = $1
    \n?
    (.*?)\n{1,2}      # end at new paragraph
    ((?=\n[ ]{0,$less_than_tab}\S)|\Z)  # Lookahead for non-space at line-start, or end of doc
  }
  {\n}sx)
  {
    my $id = $1;
    my $reference = "$2\n";

    $reference =~ s/^[ ]{0,$self->{params}{tab_width}}//gm;

    $reference = $self->_RunBlockGamut($reference);

    # strip leading and trailing <p> tags (they will be added later)
    $reference =~ s/^\<p\>//s;
    $reference =~ s/\<\/p\>\s*$//s;

    $self->{_references}{$id} = $reference;
  }

  return $text;
}

sub _DoMarkdownCitations {
  my $self = shift;
  my $text = shift;

  $text =~ s{       # Allow for citations without locator to be written
    \[\#([^\[]*?)\]   # in usual manner, e.g. [#author][] rather than
    [ ]?        # [][#author]
    (?:\n[ ]*)?
    \[\s*\]
  }{
    "[][#$1]";
  }xsge;

  $text =~ s{
    \[([^\[]*?)\]   # citation text = $1
    [ ]?      # one optional space
    (?:\n[ ]*)?   # one optional newline followed by spaces
    \[\#(.*?)\]   # id = $2
  }{
    my $result;
    my $anchor_text = $1;
    my $id = $2;
    my $count;

    # implement equivalent to \citet
    my $textual_string = "";
    if ($anchor_text =~ s/^(.*?);\s*//) {
      $textual_string = "<span class=\"textual citation\">$1</span>";
    }

    if (defined $self->{_references}{$id} ) {
      my $citation_counter=0;

      # See if citation has been used before
      foreach my $old_id (@{$self->{_used_references}}) {
        $citation_counter++;
        $count = $citation_counter if ($old_id eq $id);
      }

      if (! defined $count) {
        $self->{_citation_counter}++;
        $count = $self->{_citation_counter};
        push (@{$self->{_used_references}},$id);
      }

      $result = "<span class=\"markdowncitation\">$textual_string (<a href=\"#$id\" title=\"see citation\">$count</a>";

      if ($anchor_text ne "") {
        $result .=", <span class=\"locator\">$anchor_text</span>";
      }

      $result .= ")</span>";
    } else {
      # No reference exists
      $result = "<span class=\"externalcitation\">$textual_string (<a id=\"$id\">$id</a>";

      if ($anchor_text ne "") {
        $result .=", <span class=\"locator\">$anchor_text</span>";
      }

      $result .= ")</span>";
    }

    if ($self->Header2Label($anchor_text) eq "notcited"){
      $result = "<span class=\"notcited\" id=\"$id\"/>";
    }
    $result;
  }xsge;

  return $text;

}

sub _PrintMarkdownBibliography{
  my $self = shift;
  my $citation_counter = 0;
  my $result;

  foreach my $id ( @{$self->{_used_references}} ) {
    $citation_counter++;
    $result.="<div id=\"$id\"><p>[$citation_counter] <span class=\"item\">$self->{_references}{$id}</span></p></div>\n\n";
  }

  $result .= "</div>";

  if($citation_counter > 0 ) {
    $result = "\n\n<div class=\"bibliography\">\n<hr$self->{params}{empty_element_suffix}\n<p>$self->{params}{bibliography_title}</p>\n\n".$result;
  } else {
    $result = "";
  }

  return $result;
}

sub _GenerateImageCrossRefs {
  my $self = shift;
  my $text = shift;

  #
  # First, handle reference-style labeled images: ![alt text][id]
  #
  $text =~ s{
    (       # wrap whole match in $1
      !\[
        (.*?)   # alt text = $2
      \]

      [ ]?        # one optional space
      (?:\n[ ]*)?   # one optional newline followed by spaces

      \[
        (.*?)   # id = $3
      \]

    )
  }{
    my $result;
    my $whole_match = $1;
    my $alt_text    = $2;
    my $link_id     = lc $3;

    if ($link_id eq "") {
      $link_id = lc $alt_text;     # for shortcut links like ![this][].
    }

    $alt_text =~ s/"/&quot;/g;
    if (defined $self->{_urls}{$link_id}) {
      my $label = $self->Header2Label($alt_text);
      $self->{_crossrefs}{$label} = "#$label";
    }
    else {
      # If there's no such link ID, leave intact:
      $result = $whole_match;
    }

    $whole_match;
  }xsge;

  #
  # Next, handle inline images:  ![alt text](url "optional title")
  # Don't forget: encode * and _

  $text =~ s{
    (       # wrap whole match in $1
      !\[
        (.*?)   # alt text = $2
      \]
      \(      # literal paren
        [ \t]*
      <?(\S+?)>?  # src url = $3
        [ \t]*
      (     # $4
        (['"])  # quote char = $5 '
        (.*?)   # title = $6
        \5    # matching quote
        [ \t]*
      )?      # title is optional
      \)
    )
  }{
    my $result;
    my $whole_match = $1;
    my $alt_text    = $2;

    $alt_text =~ s/"/&quot;/g;
    my $label = $self->Header2Label($alt_text);
    $self->{_crossrefs}{$label} = "#$label";
    $whole_match;
  }xsge;

  return $text;
}

sub _FindMathEquations{
  my $self = shift;
  my $text = shift;

  $text =~ s{
    (\<math[^\>]*)id=\"(.*?)\">   # "
  }{
    my $label = $self->Header2Label($2);
    my $header = $self->_RunSpanGamut($2);

    $self->{_crossrefs}{$label} = "#$label";
    $self->{_titles}{$label} = $header;

    $1 . "id=\"$label\">";
  }xsge;

  return $text;
}

sub _DoMathSpans {
  my $self = shift;
  # Based on Gruber's _DoCodeSpans

  my $text = shift;
  my $display_as_block = 0;
  $display_as_block = 1 if ($text =~ /^<<[^\>\>]*>>$/);

  $text =~ s{
      (?<!\\)   # Character before opening << can't be a backslash
      (<<)    # $1 = Opening
      (.+?)   # $2 = The code block
      (?:\[(.+)\])? # $3 = optional label
      (>>)
    }{
      my $m = "$2";
      my $label = "";
      my @attr = (xmlns=>"http://www.w3.org/1998/Math/MathML");

      if (defined $3) {
        $label = $self->Header2Label($3);
        my $header = $self->_RunSpanGamut($3);

        $self->{_crossrefs}{$label} = "#$label";
        $self->{_titles}{$label} = $header;
      }
      $m =~ s/^[ \t]*//g; # leading whitespace
      $m =~ s/[ \t]*$//g; # trailing whitespace
      push(@attr,(id=>"$label")) if ($label ne "");
      push(@attr,(display=>"block")) if ($display_as_block == 1);

#      $m = $mathParser->TextToMathML($m,\@attr);
      "$m";
    }egsx;

  return $text;
}

sub _DoDefinitionLists {
  my $self = shift;
  # Uses the syntax proposed by Michel Fortin in PHP Markdown Extra

  my $text = shift;
  my $less_than_tab = $self->{params}{tab_width} -1;

  my $line_start = qr{
    [ ]{0,$less_than_tab}
  }mx;

  my $term = qr{
    $line_start
    [^:\s][^\n]*\n
  }sx;

  my $definition = qr{
    \n?[ ]{0,$less_than_tab}
    \:[ \t]+(.*?)\n
    ((?=\n?\:)|\n|\Z) # Lookahead for next definition, two returns,
              # or the end of the document
  }sx;

  my $definition_block = qr{
    ((?:$term)+)        # $1 = one or more terms
    ((?:$definition)+)      # $2 = by one or more definitions
  }sx;

  my $definition_list = qr{
    (?:$definition_block\n*)+   # One ore more definition blocks
  }sx;

  $text =~ s{
    ($definition_list)      # $1 = the whole list
  }{
    my $list = $1;
    my $result = $1;

    $list =~ s{
      (?:$definition_block)\n*
    }{
      my $terms = $1;
      my $defs = $2;

      $terms =~ s{
        [ ]{0,$less_than_tab}
        (.*)
        \s*
      }{
        my $term = $1;
        my $result = "";
        $term =~ s/^\s*(.*?)\s*$/$1/;
        if ($term !~ /^\s*$/){
          $result = "<dt>" . $self->_RunSpanGamut($1) . "</dt>\n";
        }
        $result;
      }xmge;

      $defs =~ s{
        $definition
      }{
        my $def = $1 . "\n";
        $def =~ s/^[ ]{0,$self->{params}{tab_width}}//gm;
        "<dd>\n" . $self->_RunBlockGamut($def) . "\n</dd>\n";
      }xsge;

      $terms . $defs . "\n";
    }xsge;

    "<dl>\n" . $list . "</dl>\n\n";
  }xsge;

  return $text
}

sub _UnescapeComments{
  my $self = shift;
  # Remove encoding inside comments
  # Based on proposal by Toras Doran (author of Text::MultiMarkdown)

  my $text = shift;
  $text =~ s{
    (?<=<!--) # Begin comment
    (.*?)     # Anything inside
    (?=-->)   # End comments
  }{
    my $t = $1;
    $t =~ s/&amp;/&/g;
    $t =~ s/&lt;/</g;
    $t;
  }egsx;

  return $text;
}

1;

__END__


=pod

=head1 NAME

B<MultiMarkdown>


=head1 SYNOPSIS



=head1 DESCRIPTION

MultiMarkdown is an extended version of Markdown. See the website for more
information.

  http://fletcherpenney.net/multimarkdown/

Markdown is a text-to-HTML filter; it translates an easy-to-read /
easy-to-write structured text format into HTML. Markdown's text format
is most similar to that of plain text email, and supports features such
as headers, *emphasis*, code blocks, blockquotes, and links.

Markdown's syntax is designed not as a generic markup language, but
specifically to serve as a front-end to (X)HTML. You can  use span-level
HTML tags anywhere in a Markdown document, and you can use block level
HTML tags (like <div> and <table> as well).

For more information about Markdown's syntax, see:

    http://daringfireball.net/projects/markdown/

=head1 AUTHOR

    John Gruber
    http://daringfireball.net/

    PHP port and other contributions by Michel Fortin
    http://michelf.com/

    MultiMarkdown changes by Fletcher Penney
    http://fletcherpenney.net/

=head1 COPYRIGHT AND LICENSE

Original Markdown Code Copyright (c) 2003-2007 John Gruber
<http://daringfireball.net/>
All rights reserved.

MultiMarkdown changes Copyright (c) 2005-2009 Fletcher T. Penney
<http://fletcherpenney.net/>
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

* Redistributions of source code must retain the above copyright notice,
  this list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright
  notice, this list of conditions and the following disclaimer in the
  documentation and/or other materials provided with the distribution.

* Neither the name "Markdown" nor the names of its contributors may
  be used to endorse or promote products derived from this software
  without specific prior written permission.

This software is provided by the copyright holders and contributors "as
is" and any express or implied warranties, including, but not limited
to, the implied warranties of merchantability and fitness for a
particular purpose are disclaimed. In no event shall the copyright owner
or contributors be liable for any direct, indirect, incidental, special,
exemplary, or consequential damages (including, but not limited to,
procurement of substitute goods or services; loss of use, data, or
profits; or business interruption) however caused and on any theory of
liability, whether in contract, strict liability, or tort (including
negligence or otherwise) arising in any way out of the use of this
software, even if advised of the possibility of such damage.

=cut

1;
