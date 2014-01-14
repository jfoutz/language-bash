-- | Bash expansions.
module Language.Bash.Expand
    ( braceExpand
    , splitWord
    , unquote
    ) where

import           Control.Applicative
import           Data.Char
import           Data.Monoid
import           Data.Traversable
import           Text.Parsec                  hiding ((<|>), optional)

import qualified Language.Bash.Parse.Builder  as B
import           Language.Bash.Parse.Internal
import           Language.Bash.Syntax

-- | Parse a word with a parser that should always succeed.
parseWord :: String -> Parsec String () a -> String -> a
parseWord fname p s = case parse p s s of
    Left  e -> error $ "Language.Bash.Expand." ++ fname ++ ": " ++ show e
    Right r -> r

-- | Pad a number to a specified width
showPadded :: Int -> Int -> String
showPadded w n
    | n < 0     = '-' : showPadded (w - 1) (negate n)
    | otherwise = replicate (w - length s) '0' ++ s
  where
    s = show n

-- | Create a list from a start value, an end value, and an increment.
enum :: (Ord a, Enum a) => a -> a -> Maybe Int -> [a]
enum x y inc = map toEnum [fromEnum x, fromEnum x + step .. fromEnum y]
  where
    step = case inc of
        Nothing | y > x     -> 1
                | otherwise -> 1
        Just i              -> i

-- | Brace expand a word, including sequences.
braceExpand :: Word -> [Word]
braceExpand = parseWord "braceExpand" (map B.toString <$> brace "")
  where
    brace delims = try (expansion delims)
               <|> return <$> gobble delims

    expansion delims = do
        a  <- gobble ('{':delims)
        _  <- char '{'
        bs <- try sequenceExpansion <|> braceParts
        _  <- char '}'
        cs <- brace delims
        return [a <> b <> c | b <- bs, c <- cs]

    braceParts = concatParts <$> brace ",}" `sepBy` char ','

    concatParts []   = [B.fromString "{}"]
    concatParts [xs] = map (\x -> B.fromChar '{' <> x <> B.fromChar '}') xs
    concatParts xss  = concat xss

    fromNumber s = case s of
        '+':s' -> readNumber s'
        _      -> readNumber s
      where
        readNumber t = case reads t of
            [(n,"")] -> return (n :: Int)
            _        -> fail "not a number"
 
    fromAlpha [c] | isAlpha c = return c
    fromAlpha _               = fail "not a character"
 
    sequenceExpansion = do
        a   <- sequencePart
        b   <- string ".." *> sequencePart
        c   <- optional (string ".." *> sequencePart)
        inc <- traverse fromNumber c
        charExpansion a b inc <|> numberExpansion a b inc
      where
        sequencePart = many1 (satisfy (\c -> isAlphaNum c || c == '-'))
 
    charExpansion a b inc = do
        x <- fromAlpha a
        y <- fromAlpha b
        return . map B.fromChar $ enum x y inc
 
    numberExpansion a b inc = do
        x <- fromNumber a
        y <- fromNumber b
        return . map (B.fromString . render) $ enum x y inc
      where
        width = max (length a) (length b)

        isPadded ('-':'0':_:_) = True
        isPadded ('0':_:_)     = True
        isPadded _             = False
 
        render = if isPadded a || isPadded b
                 then showPadded width
                 else show

-- | Split a word into parts based on a the specified delimiters.
splitWord :: [Char] -> Word -> [Word]
splitWord ifs = parseWord "splitWord" (map B.toString <$> go)
  where
    go = do
        skipMany (oneOf ifs)
        [] <$ eof <|> (:) <$> gobble ifs <*> go

-- | Unquote a word.
unquote :: Word -> String
unquote s = case parse unquoteBare s s of
    Left _   -> s
    Right s' -> B.toString s'
  where
    unquoteBare = B.many $
            try unquoteEscape
        <|> try unquoteSingle
        <|> try unquoteDouble
        <|> try unquoteAnsi
        <|> try unquoteLocale
        <|> B.anyChar

    unquoteEscape = char '\\' *> B.anyChar
    unquoteSingle = B.span '\'' '\'' empty
    unquoteDouble = B.span '\"' '\"' unquoteEscape
    unquoteAnsi   = char '$' *> B.span '\'' '\'' unquoteEscape
    unquoteLocale = char '$' *> unquoteDouble