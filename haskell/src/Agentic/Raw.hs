{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Agentic.Raw
-- Description : The unchecked term language, and the JSON it travels as.
--
-- A transliteration of @Agentic\/Core\/Dsl\/Syntax.lean@ (with 'Code' and
-- 'Addressee' from @Agentic\/Core\/Question.lean@), together with a codec that
-- reproduces Lean's @deriving ToJson@ strategy exactly at the
-- @Data.Aeson.Value@ level. The corpus at
-- @\/Users\/johnw\/src\/agent-cat\/test\/corpus@ is the arbiter; every
-- constructor and every field name below was checked against all 99 program
-- entries of it.
--
-- Constructor argument order is Lean's declaration order throughout, so a
-- positional pattern match here reads like the corresponding Lean match.
--
-- == The one encoding rule
--
-- Every non-nullary constructor of every type here names all of its arguments
-- in Lean, so every one of them takes the /named-field object/ form
--
-- > { "ctorName": { "arg1": val1, …, "argN": valN } }
--
-- including the one-argument constructors: @Chunk.lit@ is @{"lit":{"s":"w"}}@
-- and never @{"lit":"w"}@, and @RawSource.rhs@ is @{"rhs":{"r":…}}@. There are
-- no positional arrays anywhere inside a 'RawProgram'. A structure
-- ('Pos', 'RawTarget', 'RawAsk', 'RawFn', 'RawProgram') is a bare object of its
-- fields with no tag at all; a nullary constructor ('Code') is a bare string;
-- @Option@ is the payload itself, with @none@ as @null@; a pair is a
-- two-element array.
--
-- Decoding is liberal exactly where Lean's is: @Json.parseCtorFields@ reads
-- fields with @getObjValD@, so a missing key reads as @null@, which an
-- @Option@ field accepts as @none@. That is what ('.::') implements. Encoding
-- is strict: the explicit @null@ is always emitted, because the corpus has
-- @"model": null@, @"ann": null@, @"reviewAnn": null@ and @"answer": null@.
--
-- == The @ack@ \/ @receipt@ trap
--
-- Inside a 'RawProgram' — the @ann@, @reviewAnn@ and @result@ fields and the
-- second component of a @params@ pair — 'Code' uses the /derived constructor
-- names/, so the fourth one is spelled @"ack"@. That is what the 'ToJSON' and
-- 'FromJSON' instances of 'Code' do. Everywhere else on the wire (the @code@
-- of a @string@ request, a trace event, a checked reply's @codes@) it is
-- spelled @"receipt"@; that spelling is 'codeName' and 'codeOfName', which are
-- exported for @Agentic.Text@ and are deliberately /not/ the instances.
--
-- == Tag collisions
--
-- @"bind"@, @"act"@, @"lit"@ and @"name"@ each name two different things at
-- two different levels of the tree. They are told apart by /expected type/ and
-- never by sniffing the payload's shape, exactly as Lean does: there is no
-- \"decode any node\" function here, and there must not be one.
module Agentic.Raw
  ( -- * Positions, codes, prompts
    Pos (..),
    Code (..),
    codeName,
    codeOfName,
    Chunk (..),
    Prompt,
    Addressee (..),

    -- * The term language
    RawTarget (..),
    RawAsk (..),
    RawArg (..),
    RawRhs (..),
    RawSource (..),
    Raw (..),
    RawBlock,
    RawBodyStmt (..),
    RawFn (..),
    RawProgram (..),

    -- * Derived positions
    rawArgPos,
    rawRhsPos,
    rawSourcePos,

    -- * Codec helpers
    ctorObj,
    withCtor,
    unknownCtor,
    (.::),
    parseNat,
  )
where

import Data.Aeson
  ( FromJSON (..),
    Object,
    ToJSON (..),
    Value (Null),
    object,
    withArray,
    withObject,
    withScientific,
    withText,
    (.=),
  )
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (JSONPathElement (Key), Pair, Parser, (<?>))
import Data.Maybe (fromMaybe)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import qualified Data.Vector as V

-- ---------------------------------------------------------------------------
-- Codec helpers
-- ---------------------------------------------------------------------------

-- | Encode a Lean constructor whose arguments all carry user-visible names:
-- @{ "ctor": { "arg1": …, "argN": … } }@. Every constructor in this module
-- takes this form.
ctorObj :: K.Key -> [Pair] -> Value
ctorObj tag fields = object [tag .= object fields]

-- | Decode the shape 'ctorObj' writes. The tag is the sole key of a one-key
-- object; the payload is that key's object, read field by field by name.
--
-- @ty@ names the Haskell type and appears in every failure message, so a
-- codec mismatch says which type refused the value.
withCtor :: String -> (K.Key -> Object -> Parser a) -> Value -> Parser a
withCtor ty f = withObject ty $ \o -> case KM.toList o of
  [(tag, payload)] ->
    withObject (ty ++ "." ++ K.toString tag) (f tag) payload <?> Key tag
  kvs ->
    fail $
      ty
        ++ ": expected a one-key constructor object, but found "
        ++ show (length kvs)
        ++ " keys: "
        ++ show (map (K.toString . fst) kvs)

-- | The failure for a tag no constructor of @ty@ answers to.
unknownCtor :: String -> K.Key -> Parser a
unknownCtor ty tag =
  fail $ ty ++ ": unknown constructor " ++ show (K.toString tag)

-- | Read a field the way Lean's @getObjValD@ does: a missing key is @null@.
--
-- For a @Maybe@ field that means a missing key decodes as 'Nothing' — the
-- codec is liberal on input and strict on output, always emitting the explicit
-- @null@ the corpus carries; for any other field it
-- means the field's own parser gets a @null@ and fails there, naming itself.
(.::) :: (FromJSON a) => Object -> K.Key -> Parser a
o .:: key = parseJSON (fromMaybe Null (KM.lookup key o)) <?> Key key

infixl 9 .::

-- | Lean @Nat@ is Haskell 'Integer' — never 'Int'. The corpus does not
-- exercise overflow, but the ask counts multiply, so the counting types must
-- not wrap.
parseNat :: String -> Value -> Parser Integer
parseNat ty = withScientific ty $ \s -> case floatingOrInteger s of
  Right n
    | n >= 0 -> pure n
    | otherwise ->
        fail $ ty ++ ": expected a natural number, but found " ++ show (n :: Integer)
  Left d ->
    fail $ ty ++ ": expected a natural number, but found " ++ show (d :: Double)

-- | 'parseNat' at a named field, with @getObjValD@ liberality.
natField :: String -> Object -> K.Key -> Parser Integer
natField ty o key =
  parseNat (ty ++ "." ++ K.toString key) (fromMaybe Null (KM.lookup key o))
    <?> Key key

-- ---------------------------------------------------------------------------
-- Positions
-- ---------------------------------------------------------------------------

-- | A point of the source text, one-based, as a reader counts.
--
-- A structure, so it encodes as a bare @{"line": l, "col": c}@ with no tag.
data Pos = Pos
  { posLine :: !Integer,
    posCol :: !Integer
  }
  deriving (Eq, Ord, Show)

instance ToJSON Pos where
  toJSON (Pos l c) = object ["line" .= l, "col" .= c]

instance FromJSON Pos where
  parseJSON = withObject "Pos" $ \o ->
    Pos <$> natField "Pos" o "line" <*> natField "Pos" o "col"

-- ---------------------------------------------------------------------------
-- Codes
-- ---------------------------------------------------------------------------

-- | The four answer kinds. The fourth is /named/ @ack@ and /written/
-- @receipt@; see the module header. The instances below are the @ack@
-- spelling, which is the one a 'RawProgram' uses.
data Code
  = CodeText
  | CodeVerdict
  | CodeFlag
  | CodeAck
  deriving (Eq, Ord, Show, Enum, Bounded)

instance ToJSON Code where
  toJSON = \case
    CodeText -> "text"
    CodeVerdict -> "verdict"
    CodeFlag -> "flag"
    CodeAck -> "ack"

instance FromJSON Code where
  parseJSON = withText "Code" $ \case
    "text" -> pure CodeText
    "verdict" -> pure CodeVerdict
    "flag" -> pure CodeFlag
    "ack" -> pure CodeAck
    other ->
      fail $
        "Code: expected one of \"text\", \"verdict\", \"flag\", \"ack\", but found "
          ++ show other

-- | The keyword that /writes/ a code: Lean's @codeName@. Note @receipt@.
--
-- This is not the 'ToJSON' instance. It is the spelling used by the @code@
-- field of a @string@ request and by trace events.
codeName :: Code -> Text
codeName = \case
  CodeText -> "text"
  CodeVerdict -> "verdict"
  CodeFlag -> "flag"
  CodeAck -> "receipt"

-- | The keyword parsed back: Lean's @codeOfName@, a retraction of 'codeName'.
codeOfName :: Text -> Maybe Code
codeOfName = \case
  "text" -> Just CodeText
  "verdict" -> Just CodeVerdict
  "flag" -> Just CodeFlag
  "receipt" -> Just CodeAck
  _ -> Nothing

-- ---------------------------------------------------------------------------
-- Prompts
-- ---------------------------------------------------------------------------

-- | One piece of a prompt: literal text, or the value of a name spliced in.
data Chunk
  = Lit !Text
  | Interp !Text
  deriving (Eq, Show)

instance ToJSON Chunk where
  toJSON = \case
    Lit s -> ctorObj "lit" ["s" .= s]
    Interp n -> ctorObj "interp" ["name" .= n]

instance FromJSON Chunk where
  parseJSON = withCtor "Chunk" $ \tag o -> case tag of
    "lit" -> Lit <$> o .:: "s"
    "interp" -> Interp <$> o .:: "name"
    _ -> unknownCtor "Chunk" tag

-- | Everything said in one question, as written: chunks read left to right.
--
-- @Prompt.normalize@ is /not/ ported and must not be applied on either side of
-- the codec: a corpus prompt may legitimately hold two adjacent 'Lit' chunks,
-- and re-encoding must reproduce it verbatim.
type Prompt = [Chunk]

-- ---------------------------------------------------------------------------
-- Addressees and targets
-- ---------------------------------------------------------------------------

-- | Who is asked.
data Addressee
  = AddrModel !Text
  | AddrTool !Text
  | AddrPerson !Text
  deriving (Eq, Show)

instance ToJSON Addressee where
  toJSON = \case
    AddrModel i -> ctorObj "model" ["id" .= i]
    AddrTool i -> ctorObj "tool" ["id" .= i]
    AddrPerson i -> ctorObj "person" ["id" .= i]

instance FromJSON Addressee where
  parseJSON = withCtor "Addressee" $ \tag o -> case tag of
    "model" -> AddrModel <$> o .:: "id"
    "tool" -> AddrTool <$> o .:: "id"
    "person" -> AddrPerson <$> o .:: "id"
    _ -> unknownCtor "Addressee" tag

-- | Whom a question is put to, and which independent draw it is.
data RawTarget = RawTarget
  { tgtAddressee :: !Addressee,
    tgtDraw :: !Integer
  }
  deriving (Eq, Show)

instance ToJSON RawTarget where
  toJSON (RawTarget a d) = object ["addressee" .= a, "draw" .= d]

instance FromJSON RawTarget where
  parseJSON = withObject "RawTarget" $ \o ->
    RawTarget <$> o .:: "addressee" <*> natField "RawTarget" o "draw"

-- ---------------------------------------------------------------------------
-- Asks
-- ---------------------------------------------------------------------------

-- | One question, as written. The kind is not a field: it comes from the
-- binder or the position, and the checker imposes it.
data RawAsk = RawAsk
  { -- | The @served by "s"@ override, if any.
    askModel :: !(Maybe Text),
    askTarget :: !RawTarget,
    askPrompt :: !Prompt,
    askPos :: !Pos
  }
  deriving (Eq, Show)

instance ToJSON RawAsk where
  toJSON (RawAsk m t p pos) =
    object ["model" .= m, "target" .= t, "prompt" .= p, "pos" .= pos]

instance FromJSON RawAsk where
  parseJSON = withObject "RawAsk" $ \o ->
    RawAsk
      <$> o .:: "model"
      <*> o .:: "target"
      <*> o .:: "prompt"
      <*> o .:: "pos"

-- ---------------------------------------------------------------------------
-- Arguments
-- ---------------------------------------------------------------------------

-- | One argument at a call site: a name in scope, or literal words.
data RawArg
  = ArgName !Text !Pos
  | ArgLit !Prompt !Pos
  deriving (Eq, Show)

instance ToJSON RawArg where
  toJSON = \case
    ArgName x pos -> ctorObj "name" ["x" .= x, "pos" .= pos]
    ArgLit p pos -> ctorObj "lit" ["p" .= p, "pos" .= pos]

instance FromJSON RawArg where
  parseJSON = withCtor "RawArg" $ \tag o -> case tag of
    "name" -> ArgName <$> o .:: "x" <*> o .:: "pos"
    "lit" -> ArgLit <$> o .:: "p" <*> o .:: "pos"
    _ -> unknownCtor "RawArg" tag

-- | Where an argument is written.
rawArgPos :: RawArg -> Pos
rawArgPos = \case
  ArgName _ p -> p
  ArgLit _ p -> p

-- ---------------------------------------------------------------------------
-- Right-hand sides
-- ---------------------------------------------------------------------------

-- | A clause-position source: one question, a panel of them, or a call.
data RawRhs
  = RhsAsk !RawAsk
  | RhsPanel ![RawAsk] !Pos
  | RhsCall !Text ![RawArg] !Pos
  deriving (Eq, Show)

instance ToJSON RawRhs where
  toJSON = \case
    RhsAsk a -> ctorObj "ask" ["a" .= a]
    RhsPanel ms pos -> ctorObj "panel" ["members" .= ms, "pos" .= pos]
    RhsCall f as pos -> ctorObj "call" ["fn" .= f, "args" .= as, "pos" .= pos]

instance FromJSON RawRhs where
  parseJSON = withCtor "RawRhs" $ \tag o -> case tag of
    "ask" -> RhsAsk <$> o .:: "a"
    "panel" -> RhsPanel <$> o .:: "members" <*> o .:: "pos"
    "call" -> RhsCall <$> o .:: "fn" <*> o .:: "args" <*> o .:: "pos"
    _ -> unknownCtor "RawRhs" tag

-- | Where a right-hand side begins.
rawRhsPos :: RawRhs -> Pos
rawRhsPos = \case
  RhsAsk a -> askPos a
  RhsPanel _ p -> p
  RhsCall _ _ p -> p

-- ---------------------------------------------------------------------------
-- Sources
-- ---------------------------------------------------------------------------

-- | What a binding may bind: a clause-position source, or a bounded revision.
--
-- @SrcRevising subject carrier bound reviewName reviewAnn review amend pos@,
-- in Lean's argument order.
data RawSource
  = SrcRhs !RawRhs
  | SrcRevising
      !Text
      -- ^ subject
      !Text
      -- ^ carrier
      !Integer
      -- ^ bound: how many amendments at most
      !Text
      -- ^ reviewName
      !(Maybe Code)
      -- ^ reviewAnn
      !RawRhs
      -- ^ review
      !RawRhs
      -- ^ amend
      !Pos
  deriving (Eq, Show)

instance ToJSON RawSource where
  toJSON = \case
    SrcRhs r -> ctorObj "rhs" ["r" .= r]
    SrcRevising subject carrier bound reviewName reviewAnn review amend pos ->
      ctorObj
        "revising"
        [ "subject" .= subject,
          "carrier" .= carrier,
          "bound" .= bound,
          "reviewName" .= reviewName,
          "reviewAnn" .= reviewAnn,
          "review" .= review,
          "amend" .= amend,
          "pos" .= pos
        ]

instance FromJSON RawSource where
  parseJSON = withCtor "RawSource" $ \tag o -> case tag of
    "rhs" -> SrcRhs <$> o .:: "r"
    "revising" ->
      SrcRevising
        <$> o .:: "subject"
        <*> o .:: "carrier"
        <*> natField "RawSource.revising" o "bound"
        <*> o .:: "reviewName"
        <*> o .:: "reviewAnn"
        <*> o .:: "review"
        <*> o .:: "amend"
        <*> o .:: "pos"
    _ -> unknownCtor "RawSource" tag

-- | Where a source begins.
rawSourcePos :: RawSource -> Pos
rawSourcePos = \case
  SrcRhs r -> rawRhsPos r
  SrcRevising _ _ _ _ _ _ _ p -> p

-- ---------------------------------------------------------------------------
-- Blocks
-- ---------------------------------------------------------------------------

-- | An unchecked block: statements, of which the branchings are terminal —
-- each arm /is/ the rest of the workflow — and a statement-position ask is the
-- act, which may be followed.
--
-- Lean names this @RawBlock@ and abbreviates @Raw@ to it. Here the data type
-- is 'Raw' and 'RawBlock' is the synonym; the two names are one type either
-- way.
data Raw
  = RawEmpty !Pos
  | -- | @RawBind x ann src rest pos@
    RawBind !Text !(Maybe Code) !RawSource !Raw !Pos
  | -- | @RawAct a rest pos@
    RawAct !RawAsk !Raw !Pos
  | -- | @RawIfFlag x yes no pos@
    RawIfFlag !Text !Raw !Raw !Pos
  | -- | @RawCaseVerdict x approved objected noAnswer pos@
    RawCaseVerdict !Text !Raw !Raw !Raw !Pos
  | -- | @RawCaseResult x settledName settled unsettled pos@
    RawCaseResult !Text !Text !Raw !Raw !Pos
  | -- | @RawKnownHere names rest pos@
    RawKnownHere ![Text] !Raw !Pos
  | -- | @RawCallStmt fn args rest pos@
    RawCallStmt !Text ![RawArg] !Raw !Pos
  deriving (Eq, Show)

-- | Lean's spelling of 'Raw'. Both names denote this one type.
type RawBlock = Raw

instance ToJSON Raw where
  toJSON = \case
    RawEmpty pos -> ctorObj "empty" ["pos" .= pos]
    RawBind x ann src rest pos ->
      ctorObj
        "bind"
        ["x" .= x, "ann" .= ann, "src" .= src, "rest" .= rest, "pos" .= pos]
    RawAct a rest pos ->
      ctorObj "act" ["a" .= a, "rest" .= rest, "pos" .= pos]
    RawIfFlag x yes no pos ->
      ctorObj "ifFlag" ["x" .= x, "yes" .= yes, "no" .= no, "pos" .= pos]
    RawCaseVerdict x approved objected noAnswer pos ->
      ctorObj
        "caseVerdict"
        [ "x" .= x,
          "approved" .= approved,
          "objected" .= objected,
          "noAnswer" .= noAnswer,
          "pos" .= pos
        ]
    RawCaseResult x settledName settled unsettled pos ->
      ctorObj
        "caseResult"
        [ "x" .= x,
          "settledName" .= settledName,
          "settled" .= settled,
          "unsettled" .= unsettled,
          "pos" .= pos
        ]
    RawKnownHere names rest pos ->
      ctorObj "knownHere" ["names" .= names, "rest" .= rest, "pos" .= pos]
    RawCallStmt f as rest pos ->
      ctorObj
        "callStmt"
        ["fn" .= f, "args" .= as, "rest" .= rest, "pos" .= pos]

instance FromJSON Raw where
  parseJSON = withCtor "Raw" $ \tag o -> case tag of
    "empty" -> RawEmpty <$> o .:: "pos"
    "bind" ->
      RawBind
        <$> o .:: "x"
        <*> o .:: "ann"
        <*> o .:: "src"
        <*> o .:: "rest"
        <*> o .:: "pos"
    "act" -> RawAct <$> o .:: "a" <*> o .:: "rest" <*> o .:: "pos"
    "ifFlag" ->
      RawIfFlag <$> o .:: "x" <*> o .:: "yes" <*> o .:: "no" <*> o .:: "pos"
    "caseVerdict" ->
      RawCaseVerdict
        <$> o .:: "x"
        <*> o .:: "approved"
        <*> o .:: "objected"
        <*> o .:: "noAnswer"
        <*> o .:: "pos"
    "caseResult" ->
      RawCaseResult
        <$> o .:: "x"
        <*> o .:: "settledName"
        <*> o .:: "settled"
        <*> o .:: "unsettled"
        <*> o .:: "pos"
    "knownHere" ->
      RawKnownHere <$> o .:: "names" <*> o .:: "rest" <*> o .:: "pos"
    "callStmt" ->
      RawCallStmt
        <$> o .:: "fn"
        <*> o .:: "args"
        <*> o .:: "rest"
        <*> o .:: "pos"
    _ -> unknownCtor "Raw" tag

-- ---------------------------------------------------------------------------
-- Function bodies
-- ---------------------------------------------------------------------------

-- | One statement of a function body. A body's binding takes a 'RawRhs', not
-- a 'RawSource', so a bounded revision inside a function is unwritable by
-- type; the branchings are likewise absent.
--
-- Note that 'BodyAct' has no @rest@ — a body is a list, not a spine — and that
-- its JSON tags @"bind"@ and @"act"@ collide with 'Raw''s. Decode by expected
-- type.
data RawBodyStmt
  = -- | @BodyBind x ann rhs pos@
    BodyBind !Text !(Maybe Code) !RawRhs !Pos
  | -- | @BodyAct a pos@
    BodyAct !RawAsk !Pos
  | -- | @BodyCallS fn args pos@
    BodyCallS !Text ![RawArg] !Pos
  deriving (Eq, Show)

instance ToJSON RawBodyStmt where
  toJSON = \case
    BodyBind x ann rhs pos ->
      ctorObj "bind" ["x" .= x, "ann" .= ann, "rhs" .= rhs, "pos" .= pos]
    BodyAct a pos -> ctorObj "act" ["a" .= a, "pos" .= pos]
    BodyCallS f as pos ->
      ctorObj "callS" ["fn" .= f, "args" .= as, "pos" .= pos]

instance FromJSON RawBodyStmt where
  parseJSON = withCtor "RawBodyStmt" $ \tag o -> case tag of
    "bind" ->
      BodyBind <$> o .:: "x" <*> o .:: "ann" <*> o .:: "rhs" <*> o .:: "pos"
    "act" -> BodyAct <$> o .:: "a" <*> o .:: "pos"
    "callS" -> BodyCallS <$> o .:: "fn" <*> o .:: "args" <*> o .:: "pos"
    _ -> unknownCtor "RawBodyStmt" tag

-- ---------------------------------------------------------------------------
-- Functions and programs
-- ---------------------------------------------------------------------------

-- | @(String × Code)@ is a Lean @Prod@, which encodes as a two-element array:
-- @["p", "text"]@.
paramToJSON :: (Text, Code) -> Value
paramToJSON (p, c) = toJSON [toJSON p, toJSON c]

paramParseJSON :: Value -> Parser (Text, Code)
paramParseJSON = withArray "RawFn.params" $ \arr -> case V.toList arr of
  [p, c] -> (,) <$> (parseJSON p <?> Key "0") <*> (parseJSON c <?> Key "1")
  xs ->
    fail $
      "RawFn.params: expected a two-element [name, code] array, but found "
        ++ show (length xs)
        ++ " elements"

-- | One function, as written. A structure: no tag, just its seven fields, in
-- Lean's declaration order.
data RawFn = RawFn
  { fnName :: !Text,
    fnParams :: ![(Text, Code)],
    fnResult :: !Code,
    fnBody :: ![RawBodyStmt],
    -- | @answer x@ for a value function; 'Nothing' for @-> receipt@.
    fnAnswer :: !(Maybe Text),
    fnAnswerPos :: !Pos,
    fnPos :: !Pos
  }
  deriving (Eq, Show)

instance ToJSON RawFn where
  toJSON f =
    object
      [ "name" .= fnName f,
        "params" .= map paramToJSON (fnParams f),
        "result" .= fnResult f,
        "body" .= fnBody f,
        "answer" .= fnAnswer f,
        "answerPos" .= fnAnswerPos f,
        "pos" .= fnPos f
      ]

instance FromJSON RawFn where
  parseJSON = withObject "RawFn" $ \o ->
    RawFn
      <$> o .:: "name"
      <*> (traverse paramParseJSON =<< (o .:: "params") <?> Key "params")
      <*> o .:: "result"
      <*> o .:: "body"
      <*> o .:: "answer"
      <*> o .:: "answerPos"
      <*> o .:: "pos"

-- | A whole program after the import walk: every function in scope, in
-- stratified order, and one block.
data RawProgram = RawProgram
  { progFns :: ![RawFn],
    progMain :: !Raw
  }
  deriving (Eq, Show)

instance ToJSON RawProgram where
  toJSON p = object ["fns" .= progFns p, "main" .= progMain p]

instance FromJSON RawProgram where
  parseJSON = withObject "RawProgram" $ \o ->
    RawProgram <$> o .:: "fns" <*> o .:: "main"
