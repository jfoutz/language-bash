{-# LANGUAGE OverloadedStrings, RecordWildCards #-}
-- | Bash words and substitutions.
module Language.Bash.Word
    ( 
      -- * Words
      Word
    , Span(..)
      -- * Parameters
    , Parameter(..)
    , ParameterSubst(..)
    , AltOp(..)
    , Direction(..)
      -- * Process
    , ProcessSubstOp(..)
      -- * Manipulation
    , fromString
    , unquote
    ) where

import Text.PrettyPrint

import Language.Bash.Operator
import Language.Bash.Pretty

-- | A Bash word, broken up into logical spans.
type Word = [Span]

data Span
      -- | A normal character.
    = Char Char
      -- | An escaped character.
    | Escape Char
      -- | A single-quoted string.
    | Single String
      -- | A double-quoted string.
    | Double Word
      -- | A ANSI C string.
    | ANSIC Word
      -- | A locale-translated string.
    | Locale Word
      -- | A backquote-style command substitution.
      -- To extract the command string, use 'unquote'.
    | Backquote Word
      -- | A parameter substitution.
    | ParameterSubst ParameterSubst
      -- | An arithmetic substitution.
    | ArithSubst String
      -- | A command substitution.
    | CommandSubst String
      -- | A process substitution.
    | ProcessSubst ProcessSubstOp String
    deriving (Eq, Read, Show)

instance Pretty Span where
    pretty (Char c)           = char c
    pretty (Escape c)         = "\\" <> char c
    pretty (Single s)         = "\'" <> text s <> "\'"
    pretty (Double w)         = "\"" <> pretty w <> "\""
    pretty (ANSIC w)          = "$\'" <> pretty w <> "\'"
    pretty (Locale w)         = "$\"" <> pretty w <> "\""
    pretty (Backquote w)      = "`" <> pretty w <> "`"
    pretty (ParameterSubst s) = pretty s
    pretty (ArithSubst s)     = "$((" <> text s <> "))"
    pretty (CommandSubst s)   = "$(" <> text s <> ")"
    pretty (ProcessSubst c s) = pretty c <> "(" <> text s <> ")"

    prettyList = hcat . map pretty

-- | A parameter name an optional subscript.
data Parameter = Parameter String (Maybe Word)
    deriving (Eq, Read, Show)

instance Pretty Parameter where
    pretty (Parameter s sub) = text s <> subscript sub
      where
        subscript Nothing  = empty
        subscript (Just w) = "[" <> pretty w <> "]"

data ParameterSubst
      -- | An ill-formed substitution.
    = BadSubst String
      -- | A substitution with no braces.
    | Bare
        { -- ^ The parameter to substitute.
          parameter         :: Parameter
        }
      -- | A simple substitution with bracesx
    | Brace
        { -- ^ Use indirect expansion.
          indirect          :: Bool
        , parameter         :: Parameter
        }
      -- | A substitution that treats unset or null values specially.
    | Alt
        { indirect          :: Bool
        , parameter         :: Parameter
          -- ^ Test for both existence and null values.
        , testNull          :: Bool
          -- ^ The operator.
        , altOp             :: AltOp
          -- ^ The alternate word.
        , altWord           :: Word
        }
      -- ^ Substring replacement.
    | Substring
        { indirect          :: Bool
        , parameter         :: Parameter
          -- ^ The substring offset.
        , subOffset         :: Word
          -- ^ The substring length, if any.
        , subLength         :: Word
        }
      -- ^ Variable prefixes.
    | Prefix
        { -- ^ The variable prefix.
          prefix            :: String
          -- ^ Either @\@@ of @*@.
        , modifier          :: Char
        }
      -- ^ Array indices.
    | Indices
        { parameter         :: Parameter
        }
      -- ^ Expansion length.
    | Length
        { parameter         :: Parameter
        }
      -- ^ Pattern deletion.
    | Delete
        { indirect          :: Bool
        , parameter         :: Parameter
          -- ^ Replace the shortest match instead of the longest match.
        , shortest          :: Bool
          -- ^ Where to delete from.
        , deleteDirection   :: Direction
          -- ^ The replacement pattern.
        , pattern           :: Word
        }
    | Replace
        { indirect          :: Bool
        , parameter         :: Parameter
          -- ^ Replace all occurences.
        , replaceAll        :: Bool
          -- ^ Where to replace.
        , replaceDirection  :: Maybe Direction
        , pattern           :: Word
          -- ^ The replacement string.
        , replacement       :: Word
        }
    | LetterCase
        { indirect          :: Bool
        , parameter         :: Parameter
          -- ^ Convert to lowercase, not uppercase.
        , toLower           :: Bool
          -- ^ Convert only the starts of words.
        , startCase         :: Bool
        , pattern           :: Word
        }
    deriving (Eq, Read, Show)

prettyParameter :: Bool -> Parameter -> Doc -> Doc
prettyParameter bang param suffix =
    "${" <> (if bang then "!" else empty) <> pretty param <> suffix <> "}"

twiceUnless :: Bool -> Doc -> Doc
twiceUnless False d = d
twiceUnless True  d = d <> d

instance Pretty ParameterSubst where
    pretty (BadSubst s)   = text s
    pretty Bare{..}       = "$" <> pretty parameter
    pretty Brace{..}      = prettyParameter indirect parameter empty
    pretty Alt{..}        = prettyParameter indirect parameter $
        (if testNull then ":" else empty) <>
        pretty altOp <>
        pretty altWord
    pretty Substring{..}  = prettyParameter indirect parameter $
        ":" <> pretty subOffset <>
        (if null subLength then empty else ":") <> pretty subLength
    pretty Prefix{..}     = "${!" <> text prefix <> char modifier <> "}"
    pretty Indices{..}    = prettyParameter True parameter empty
    pretty Length{..}     = "${#" <> pretty parameter <> "}"
    pretty Delete{..}     = prettyParameter indirect parameter $
        twiceUnless shortest (pretty deleteDirection) <>
        pretty pattern
    pretty Replace{..}    = prettyParameter indirect parameter $
        "/" <>
        (if replaceAll then "/" else empty) <>
        pretty replaceDirection <>
        pretty pattern <>
        "/" <>
        pretty replacement
    pretty LetterCase{..} = prettyParameter indirect parameter $
        twiceUnless startCase (if toLower then "," else "^") <>
        pretty pattern

-- | An alternation operator.
data AltOp
    = AltDefault  -- ^ '-', ':-'
    | AltAssign   -- ^ '=', ':='
    | AltError    -- ^ '?', ':?'
    | AltReplace  -- ^ '+', ':+'
    deriving (Eq, Ord, Read, Show, Enum, Bounded)

instance Operator AltOp where
    operatorTable = zip [minBound .. maxBound] ["-", "=", "?", "+"]

instance Pretty AltOp where
    pretty = prettyOperator

-- | A string direction.
data Direction
    = Front
    | Back
    deriving (Eq, Ord, Read, Show, Enum, Bounded)

instance Pretty Direction where
    pretty Front = "#"
    pretty Back  = "%"

-- | A process substitution.
data ProcessSubstOp
    = In   -- ^ @\<@
    | Out  -- ^ @\>@
    deriving (Eq, Ord, Read, Show, Enum, Bounded)

instance Operator ProcessSubstOp where
    operatorTable = zip [In, Out] ["<", ">"]

instance Pretty ProcessSubstOp where
    pretty = prettyOperator

-- | Convert a string to an unquoted word.
fromString :: String -> Word
fromString = map Char

-- | Remove all quoting characters from a word.
unquote :: Word -> String
unquote = render . unquoteWord
  where
    unquoteWord = hcat . map unquoteSpan

    unquoteSpan (Char c)   = char c
    unquoteSpan (Escape c) = char c
    unquoteSpan (Single s) = text s
    unquoteSpan (Double w) = unquoteWord w
    unquoteSpan (ANSIC w)  = unquoteWord w
    unquoteSpan (Locale w) = unquoteWord w
    unquoteSpan s          = pretty s