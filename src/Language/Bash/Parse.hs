{-# LANGUAGE OverloadedStrings #-}
-- | Bash input parsing.
module Language.Bash.Parse
    ( parse
    ) where

import           Control.Applicative          hiding (many)
import           Control.Monad
import           Data.Either
import           Data.Functor.Identity
import           Text.Parsec.Char             hiding (newline)
import           Text.Parsec.Combinator       hiding (optional)
import           Text.Parsec.Error            (ParseError)
import           Text.Parsec.Pos
import           Text.Parsec.Prim             hiding (parse)

import qualified Language.Bash.Parse.Internal as I
import           Language.Bash.Parse.Packrat
import           Language.Bash.Syntax

-- | User state.
data U = U { postHeredoc :: Maybe (State D U) }

-- | Bash parser type.
type Parser = ParsecT D U Identity

-- | Parse a script or input line into a (possibly empty) list of commands.
parse :: SourceName -> String -> Either ParseError List
parse source = runParser script (U Nothing) source . pack (initialPos source)

-------------------------------------------------------------------------------
-- Basic parsers
-------------------------------------------------------------------------------

-- | Get the next line of input.
line :: Parser String
line = lookAhead anyChar *> many (satisfy (/= '\n')) <* optional (char '\n')

-- | Parse the next here document.
heredoc :: Bool -> String -> Parser String
heredoc strip end = do
    (h, s) <- lookAhead duck
    setState $ U (Just s)
    return h
  where
    process = if strip then dropWhile (== '\t') else id

    duck = do
        u <- getState
        case postHeredoc u of
            Nothing -> () <$ line
            Just s  -> () <$ setParserState s
        h <- unlines <$> heredocLines
        s <- getParserState
        return (h, s)

    heredocLines = do
        l <- process <$> line
        if l == end then return [] else (l :) <$> heredocLines

-- | Parse a newline, skipping any here documents.
newline :: Parser String
newline = do
    _ <- char '\n'
    u <- getState
    case postHeredoc u of
        Nothing -> return ()
        Just s  -> () <$ setParserState s
    setState $ U Nothing
    return "\n"

-- | Parse a list terminator.
listTerm :: Parser ListTerm
listTerm = term <* newlineList
  where
    term = Sequential   <$ newline
       </> Sequential   <$ operator ";"
       </> Asynchronous <$ operator "&"

-- | Skip zero or more newlines.
newlineList :: Parser ()
newlineList = skipMany newline

-------------------------------------------------------------------------------
-- Simple commands
-------------------------------------------------------------------------------

-- | Skip a redirection.
redir :: Parser Redir
redir = normalRedir
    </> heredocRedir
  where
    normalRedir = Redir <$> redirWord <*> redirOp <*> anyWord

    heredocRedir = do
        (strip, op) <- heredocOp
        w <- anyWord
        let delim  = I.unquote w
            quoted = delim /= w
        h <- heredoc strip delim
        return $ Heredoc op delim quoted h

    heredocOp = (,) False <$> operator "<<"
            </> (,) True  <$> operator "<<-"

-- | Skip a list of redirections.
redirList :: Parser [Redir]
redirList = many (try redir)

-- | Parse part of a command.
commandParts :: Parser a -> Parser ([a], [Redir])
commandParts p = partitionEithers <$> many (try part)
  where
    part = Left  <$> p
       </> Right <$> redir

-- | Parse a simple command.
simpleCommand :: Parser Command
simpleCommand = do
    notFollowedBy reservedWord
    normalCommand </> assignCommand
  where
    normalCommand = do
        (as, rs1) <- commandParts assign
        (ws, rs2) <- commandParts anyWord
        guard (not $ null as && null ws)
        return $ Command (SimpleCommand as ws) (rs1 ++ rs2)

    assignCommand = do
        rs1 <- redirList
        w <- assignBuiltin
        (args, rs2) <- commandParts assignArg
        return $ Command (AssignBuiltin w args) (rs1 ++ rs2)

    assignArg = Left  <$> assign
            </> Right <$> anyWord

-------------------------------------------------------------------------------
-- Lists
-------------------------------------------------------------------------------

-- | Parse a pipeline.
pipelineCommand :: Parser Pipeline
pipelineCommand = time
              </> invert
              </> pipeline1
  where
    invert = Invert <$ word "!" <*> pipeline0

    time = Time <$ word "time" <*> timeFlag <*> (invert </> pipeline0)

    timeFlag = True <$ word "-p"
           </> pure False

    pipeline0 = Pipeline <$> commandList0
    pipeline1 = Pipeline <$> commandList1

    commandList0 = option [] (try commandList1)
    commandList1 = do
        c <- command
        pipelineSep c </> pure [c]

    pipelineSep c = do
        c' <- c          <$ operator "|"
          </> addRedir c <$ operator "|&"
        (c' :) <$> commandList0

    addRedir (Command c rs) = Command c (stderrRedir : rs)

    stderrRedir = Redir (Just "2") ">&" "1"

-- | Parse a compound list of commands.
compoundList :: Parser List
compoundList = List <$ newlineList <*> many1 (try statement)
  where
    statement = Statement <$> andOr <*> option Sequential (try listTerm)

    andOr = do
        p <- pipelineCommand
        let rest = And p <$ operator "&&" <* newlineList <*> andOr
               </> Or  p <$ operator "||" <* newlineList <*> andOr
        rest </> pure (Last p)

-- | Parse a possible empty compound list of commands.
inputList :: Parser List
inputList = newlineList *> option (List []) (try compoundList)

-- | Parse a command group, wrapped either in braces or in a @do...done@ block.
doGroup :: Parser List
doGroup = word "do" *> compoundList <* word "done"
      </> word "{"  *> compoundList <* word "}"

-------------------------------------------------------------------------------
-- Compound commands
-------------------------------------------------------------------------------

-- | A list with one command.
singleton :: ShellCommand -> List
singleton c = List [Statement (Last (Pipeline [Command c []])) Sequential]

-- | Parse a compound command.
shellCommand :: Parser ShellCommand
shellCommand = group
           </> ifCommand
           </> caseCommand
           </> forCommand
           </> whileCommand
           </> untilCommand
           </> selectCommand
           </> condCommand
           </> arithCommand
           </> subshell

-- | Parse a @case@ command.
caseCommand :: Parser ShellCommand
caseCommand = Case <$ word "case"
          <*> anyWord <* newlineList
          <*  word "in" <* newlineList
          <*> clauses
  where
    clauses = [] <$ word "esac"
          </> do p <- pattern
                 c <- inputList
                 nextClause (CaseClause p c)

    nextClause f = (:) <$> (f <$> clauseTerm) <* newlineList <*> clauses
               </> [f Break] <$ newlineList <* word "esac"

    pattern = optional (try (operator "("))
           *> anyWord `sepBy` operator "|"
           <* operator ")"

    clauseTerm = Break       <$ operator ";;"
             </> FallThrough <$ operator ";&"
             </> Continue    <$ operator ";;&"

-- | Parse a @while@ command.
whileCommand :: Parser ShellCommand
whileCommand = While <$ word "while"
           <*> compoundList
           <*  word "do" <*> compoundList <* word "done"

-- | Parse an @until@ command.
untilCommand :: Parser ShellCommand
untilCommand = Until <$ word "until"
           <*> compoundList
           <*  word "do" <*> compoundList <* word "done"

-- | Parse a list of words for a @for@ or @select@ command.
wordList :: Parser [Word]
wordList = [] <$ operator ";" <* newlineList
       </> newlineList *> inList
  where
    inList = word "in" *> many (try anyWord) <* listTerm
         </> return ["\"$@\""]

-- | Parse a @for@ command.
forCommand :: Parser ShellCommand
forCommand = word "for" *> (arithFor_ </> for_)
  where
    arithFor_ = ArithFor
            <$  string "((" <*> arith <* string "))" <* skipSpace
            <*  optional (try listTerm)
            <*> doGroup

    for_ = For <$> anyWord <*> wordList <*> doGroup

-- | Parse a @select@ command.
selectCommand :: Parser ShellCommand
selectCommand = Select <$ word "select" <*> anyWord <*> wordList <*> doGroup

-- | Parse an @if@ command.
ifCommand :: Parser ShellCommand
ifCommand = word "if" *> if_
  where
    if_ = If <$> compoundList <* word "then" <*> compoundList
      <*> optional (try alternative) <* word "fi"

    alternative = singleton <$ word "elif" <*> if_
              </> word "else" *> compoundList

-- | Parse a subshell command.
subshell :: Parser ShellCommand
subshell = Subshell <$ operator "(" <*> compoundList <* operator ")"

-- | Parse a command group.
group :: Parser ShellCommand
group = Group <$ word "{" <*> compoundList <* word "}"

-- | Parse an arithmetic command.
arithCommand :: Parser ShellCommand
arithCommand = Arith <$ string "((" <*> arith <* string "))" <* skipSpace

-- | Parse a conditional command.
condCommand :: Parser ShellCommand
condCommand = Cond <$ word "[[" <*> many1 (try condPart) <* word "]]"
  where
    condPart = anyWord </> anyOperator

-------------------------------------------------------------------------------
-- Coprocesses
-------------------------------------------------------------------------------

-- | Parse a coprocess command.
coproc :: Parser ShellCommand
coproc = word "coproc" *> coprocCommand
  where
    coprocCommand = Coproc <$> option "COPROC" (try name)
                           <*> (Command <$> shellCommand <*> pure [])
                </> Coproc "COPROC" <$> simpleCommand

-------------------------------------------------------------------------------
-- Function definitions
-------------------------------------------------------------------------------

-- | Parse a function definition.
functionDef :: Parser ShellCommand
functionDef = functionDef1
          </> functionDef2
  where
    functionDef1 = FunctionDef <$ word "function" <*> anyWord
               <*  optional (try functionParens) <* newlineList
               <*> functionBody

    functionDef2 = FunctionDef <$> unreservedWord
               <*  functionParens <* newlineList
               <*> functionBody

    functionParens = operator "(" <* operator ")"

    functionBody = unwrap <$> group
               </> singleton <$> shellCommand

    unwrap (Group l) = l
    unwrap _         = List []

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------

-- | Parse a single command.
command :: Parser Command
command = Command <$> compoundCommand <*> redirList
      </> simpleCommand
  where
    compoundCommand = shellCommand
                  </> coproc
                  </> functionDef

-- | Parse an entire script (e.g. a file) as a list of commands.
script :: Parser List
script = skipSpace *> inputList <* eof