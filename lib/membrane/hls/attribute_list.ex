defmodule Membrane.HLS.AttributeList do
  @moduledoc """
  From RFC 8216, 4.2

  Certain tags have values that are attribute-lists.  An attribute-list
  is a comma-separated list of attribute/value pairs with no
  whitespace.

  An attribute/value pair has the following syntax:

  AttributeName=AttributeValue

  An AttributeName is an unquoted string containing characters from the
  set [A..Z], [0..9] and '-'.  Therefore, AttributeNames contain only
  uppercase letters, not lowercase.  There MUST NOT be any whitespace
  between the AttributeName and the '=' character, nor between the '='
  character and the AttributeValue.

  An AttributeValue is one of the following:

  o  decimal-integer: an unquoted string of characters from the set
     [0..9] expressing an integer in base-10 arithmetic in the range
     from 0 to 2^64-1 (18446744073709551615).  A decimal-integer may be
     from 1 to 20 characters long.

  o  hexadecimal-sequence: an unquoted string of characters from the
     set [0..9] and [A..F] that is prefixed with 0x or 0X.  The maximum
     length of a hexadecimal-sequence depends on its AttributeNames.

  o  decimal-floating-point: an unquoted string of characters from the
     set [0..9] and '.' that expresses a non-negative floating-point
     number in decimal positional notation.

  o  signed-decimal-floating-point: an unquoted string of characters
     from the set [0..9], '-', and '.' that expresses a signed
     floating-point number in decimal positional notation.

  o  quoted-string: a string of characters within a pair of double
     quotes (0x22).  The following characters MUST NOT appear in a
     quoted-string: line feed (0xA), carriage return (0xD), or double
     quote (0x22).  Quoted-string AttributeValues SHOULD be constructed
     so that byte-wise comparison is sufficient to test two quoted-
     string AttributeValues for equality.  Note that this implies case-
     sensitive comparison.

  o  enumerated-string: an unquoted character string from a set that is
     explicitly defined by the AttributeName.  An enumerated-string
     will never contain double quotes ("), commas (,), or whitespace.

  o  decimal-resolution: two decimal-integers separated by the "x"
     character.  The first integer is a horizontal pixel dimension
     (width); the second is a vertical pixel dimension (height).

  The type of the AttributeValue for a given AttributeName is specified
  by the attribute definition.

  A given AttributeName MUST NOT appear more than once in a given
  attribute-list.  Clients SHOULD refuse to parse such Playlists.
  """
end
