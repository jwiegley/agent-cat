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
-- second component of a @params@ pair — 'SomeCode' uses constructor names, so
-- the fourth built-in is spelled @"ack"@ and the structured family uses a
-- @"json"@ wire tag carrying its schema. Everywhere else, the acknowledgement
-- is spelled @"receipt"@; 'codeName' handles that diagnostic spelling.
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
    SomeCode (..),
    codeName,
    codeOfName,
    Chunk (..),
    Prompt,
    Addressee (..),

    -- * The term language
    RawTarget (..),
    Served (..),
    servedBy1,
    RawAsk (..),
    RawArg (..),
    TextMember (..),
    Decider (..),
    deciderName,
    deciderOfName,
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
    (.=),
  )
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (JSONPathElement (Key), Pair, Parser, (<?>))
import Data.Maybe (fromMaybe)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import qualified Data.Vector as V

-- The decider vocabulary is "Agentic.Text"'s, imported and re-exported rather
-- than redefined: its four algorithms are string-layer decisions, pinned by
-- string-layer vectors, and @Agentic.Text@ is self-contained by design and may
-- not import this module. Lean declares @Decider@ beside the @RawRhs@
-- constructor that carries it (@Agentic/Core/Dsl/Syntax.lean@) and defines
-- @Decider.run@ from @Agentic/Core/Text.lean@'s primitives; here the type and
-- its run travel together and the codec imports them, which is the same one
-- table with the import arrow the only way round it can go.
import Agentic.Schema (Code (..), SomeCode (..), codeName, codeOfName)
import Agentic.Schema.Json (codeFromJson, codeToJson)
import Agentic.Text (Decider (..), deciderName, deciderOfName)

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

maybeCodeToJson :: Maybe SomeCode -> Value
maybeCodeToJson = maybe Null codeToJson

parseMaybeCode :: Value -> Parser (Maybe SomeCode)
parseMaybeCode Null = pure Nothing
parseMaybeCode value = Just <$> codeFromJson value

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
-- Codes are defined in Agentic.Schema: promoted `Code` for type indices and
-- existential `SomeCode` for this first-order syntax.
-- ---------------------------------------------------------------------------

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
-- The authoring surface's empty-literal drop ('Agentic.WF.normalize') must not
-- be applied on either side of this codec: a corpus prompt may legitimately hold
-- two adjacent 'Lit' chunks, and re-encoding must reproduce it verbatim. (Lean
-- used to state that rule as @Dsl.Prompt.normalize@; obr @acat-o5o@ deleted the
-- statement, since nothing in Lean applied it, and left it where it runs.)
type Prompt = [Chunk]

-- ---------------------------------------------------------------------------
-- Addressees and targets
-- ---------------------------------------------------------------------------

-- | Who is asked.
data Addressee
  = AddrModel !Text
  | AddrTool !Text
  | AddrPerson !Text
  | -- | @AddrToolExec id cmd args@ — a tool whose answer the /runner/ obtains
    -- by running a program-authored command, so that a check can be an exit
    -- code rather than a model's claim about one (D5,
    -- @Agentic\/Core\/Question.lean:72@).
    --
    -- __The argv rides in the addressee__, and that is the decision the whole
    -- design turns on: @Q.Shape@ is the addressee, the scope and the draw, so a
    -- command in the addressee is in the question, in its
    -- 'Agentic.World.EventKey' and in its trace event for free — and two acts
    -- saying the same words to the same tool id with /different/ commands are
    -- two questions rather than one, which is what keeps a gate run twice from
    -- being answered from the memo table without running (@battery-219@,
    -- @battery-220@). @cmd@ is separate from @args@, so \"an argv naming no
    -- command\" is unrepresentable and no term-level guard is owed. Both are
    -- 'Text' and never a 'Prompt': there is no interpolation syntax at an argv,
    -- so there is no path from any answer to any command line, which is why no
    -- capability lattice is needed here.
    AddrToolExec !Text !Text ![Text]
  deriving (Eq, Show)

instance ToJSON Addressee where
  toJSON = \case
    AddrModel i -> ctorObj "model" ["id" .= i]
    AddrTool i -> ctorObj "tool" ["id" .= i]
    AddrPerson i -> ctorObj "person" ["id" .= i]
    AddrToolExec i cmd args ->
      ctorObj "toolExec" ["id" .= i, "cmd" .= cmd, "args" .= args]

instance FromJSON Addressee where
  parseJSON = withCtor "Addressee" $ \tag o -> case tag of
    "model" -> AddrModel <$> o .:: "id"
    "tool" -> AddrTool <$> o .:: "id"
    "person" -> AddrPerson <$> o .:: "id"
    "toolExec" -> AddrToolExec <$> o .:: "id" <*> o .:: "cmd" <*> o .:: "args"
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

-- | The models that may answer a pinned question: the one the author named,
-- and the ones the runner may fall back to, in the order they are tried (D6,
-- @Agentic\/Core\/Dsl\/Syntax.lean:189@).
--
-- A structure and not a @[Text]@, so that \"pinned but empty\" is
-- unrepresentable and no new guard is owed; and a /payload/ of the existing
-- 'Maybe', so that @\"model\": null@ still reads as unpinned. A structure
-- encodes as a bare object of its fields with no tag.
--
-- __The alternates are dropped at elaboration__ — @Check.askShape@ takes
-- @primary@ alone — and that is the formal statement that fail-over is not part
-- of a program's meaning: two asks differing only in their alternates elaborate
-- to the same plan, ask the same question and bill the same.
data Served = Served
  { srvPrimary :: !Text,
    srvAlternates :: ![Text]
  }
  deriving (Eq, Show)

instance ToJSON Served where
  toJSON (Served p as) = object ["primary" .= p, "alternates" .= as]

instance FromJSON Served where
  parseJSON = withObject "Served" $ \o ->
    Served <$> o .:: "primary" <*> o .:: "alternates"

-- | The one-model chain: @served by "s"@ with no spare, which is what every
-- frozen entry carries and what 'Agentic.Builder.askModelServed' builds.
servedBy1 :: Text -> Served
servedBy1 m = Served m []

-- | One question as written. Kind and execution intent are occurrence properties,
-- not Raw fields; Builder lowers source form into annotated Plan.
data RawAsk = RawAsk
  { -- | The @served by "s"@ override, if any — with its alternates.
    askModel :: !(Maybe Served),
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

-- | One member of a text panel: the name its block is fenced under, and the
-- question that fills it (@Agentic\/Core\/Dsl\/Syntax.lean:237@).
--
-- A named structure and not a @(Text, RawAsk)@ pair, because a pair's derived
-- codec puts a two-element array on the wire and __the corpus is read by
-- humans__: a member is @{\"name\": …, \"ask\": …}@. The label comes first
-- because it is how the source reads.
data TextMember = TextMember
  { tmName :: !Text,
    tmAsk :: !RawAsk
  }
  deriving (Eq, Show)

instance ToJSON TextMember where
  toJSON (TextMember n a) = object ["name" .= n, "ask" .= a]

instance FromJSON TextMember where
  parseJSON = withObject "TextMember" $ \o ->
    TextMember <$> o .:: "name" <*> o .:: "ask"

-- | A clause-position source: one question, a panel of them, a text panel, a
-- decision about text already in hand, or a call of a function.
data RawRhs
  = RhsAsk !RawAsk
  | RhsPanel ![RawAsk] !Pos
  | -- | @panel as text [ name: ask, … ]@ (D2): several questions, each
    -- member's answer fenced under its own name and the blocks concatenated in
    -- member order. The label is explicit and is /not/ the addressee id: two
    -- members of one spread routinely share an addressee, and a document whose
    -- names change when an operator repoints a lens is naming the wrong thing.
    RhsPanelText ![TextMember] !Pos
  | -- | @decide d x [w₁, …]@ (D7): a pure classification of the text bound to
    -- @x@, answering @flag@. It asks nothing, and its needles are __literal
    -- program text__ — never a 'Prompt' — because a needle a model could author
    -- is a test a model chooses, which is not a decider.
    RhsDecide !Decider !Text ![Text] !Pos
  | RhsCall !Text ![RawArg] !Pos
  deriving (Eq, Show)

instance ToJSON RawRhs where
  toJSON = \case
    RhsAsk a -> ctorObj "ask" ["a" .= a]
    RhsPanel ms pos -> ctorObj "panel" ["members" .= ms, "pos" .= pos]
    RhsPanelText ms pos -> ctorObj "panelText" ["members" .= ms, "pos" .= pos]
    RhsDecide d x ws pos ->
      ctorObj
        "decide"
        [ "decider" .= deciderName d,
          "subject" .= x,
          "needles" .= ws,
          "pos" .= pos
        ]
    RhsCall f as pos -> ctorObj "call" ["fn" .= f, "args" .= as, "pos" .= pos]

instance FromJSON RawRhs where
  parseJSON = withCtor "RawRhs" $ \tag o -> case tag of
    "ask" -> RhsAsk <$> o .:: "a"
    "panel" -> RhsPanel <$> o .:: "members" <*> o .:: "pos"
    "panelText" -> RhsPanelText <$> o .:: "members" <*> o .:: "pos"
    "decide" ->
      RhsDecide
        <$> (deciderField =<< o .:: "decider")
        <*> o .:: "subject"
        <*> o .:: "needles"
        <*> o .:: "pos"
    "call" -> RhsCall <$> o .:: "fn" <*> o .:: "args" <*> o .:: "pos"
    _ -> unknownCtor "RawRhs" tag
    where
      deciderField t = case deciderOfName t of
        Just d -> pure d
        Nothing ->
          fail $
            "RawRhs.decide: unknown decider "
              ++ show t
              -- Not a [wft|...|]: Agentic.WF imports Agentic.Builder, which imports this module — the quoter is unreachable from here.
              ++ "; the vocabulary is closed at lastNonEmptyLineIs, \
                 \containsLine, anyLineStartsWith, anyPathMatches"

-- | Where a right-hand side begins.
rawRhsPos :: RawRhs -> Pos
rawRhsPos = \case
  RhsAsk a -> askPos a
  RhsPanel _ p -> p
  RhsPanelText _ p -> p
  RhsDecide _ _ _ p -> p
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
      !(Maybe SomeCode)
      -- ^ reviewAnn
      !RawRhs
      -- ^ review
      !RawRhs
      -- ^ amend
      !Pos
  | -- | @revising on s as c, at most n amendments { … }@ (D4): the same loop,
    -- whose fork reads the review's verdict three ways — approval settles, an
    -- objection amends, a refusal abandons.
    --
    -- The payload is identical to 'SrcRevising'\'s and only the constructor
    -- differs, deliberately: __the difference is in how the loop reads its
    -- verdict, which is a property of the loop and not of its clauses__. Its
    -- consuming form is 'RawCaseEnding', never 'RawCaseResult'.
    SrcRevisingOn
      !Text
      !Text
      !Integer
      !Text
      !(Maybe SomeCode)
      !RawRhs
      !RawRhs
      !Pos
  deriving (Eq, Show)

instance ToJSON RawSource where
  toJSON = \case
    SrcRhs r -> ctorObj "rhs" ["r" .= r]
    SrcRevising subject carrier bound reviewName reviewAnn review amend pos ->
      ctorObj "revising" (loopFields subject carrier bound reviewName reviewAnn review amend pos)
    SrcRevisingOn subject carrier bound reviewName reviewAnn review amend pos ->
      ctorObj "revisingOn" (loopFields subject carrier bound reviewName reviewAnn review amend pos)
    where
      loopFields subject carrier bound reviewName reviewAnn review amend pos =
        [ "subject" .= subject,
          "carrier" .= carrier,
          "bound" .= bound,
          "reviewName" .= reviewName,
          "reviewAnn" .= maybeCodeToJson reviewAnn,
          "review" .= review,
          "amend" .= amend,
          "pos" .= pos
        ]

instance FromJSON RawSource where
  parseJSON = withCtor "RawSource" $ \tag o -> case tag of
    "rhs" -> SrcRhs <$> o .:: "r"
    "revising" -> loopOf SrcRevising "RawSource.revising" o
    "revisingOn" -> loopOf SrcRevisingOn "RawSource.revisingOn" o
    _ -> unknownCtor "RawSource" tag
    where
      loopOf ctor ty o =
        ctor
          <$> o .:: "subject"
          <*> o .:: "carrier"
          <*> natField ty o "bound"
          <*> o .:: "reviewName"
          <*> (parseMaybeCode =<< (o .:: "reviewAnn" :: Parser Value))
          <*> o .:: "review"
          <*> o .:: "amend"
          <*> o .:: "pos"

-- | Where a source begins.
rawSourcePos :: RawSource -> Pos
rawSourcePos = \case
  SrcRhs r -> rawRhsPos r
  SrcRevising _ _ _ _ _ _ _ p -> p
  SrcRevisingOn _ _ _ _ _ _ _ p -> p

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
    RawBind !Text !(Maybe SomeCode) !RawSource !Raw !Pos
  | -- | @RawAct a rest pos@
    RawAct !RawAsk !Raw !Pos
  | -- | @RawIfFlag x yes no pos@
    RawIfFlag !Text !Raw !Raw !Pos
  | -- | @RawCaseVerdict x approved objected noAnswer pos@
    RawCaseVerdict !Text !Raw !Raw !Raw !Pos
  | -- | @RawCaseResult x settledName unsettledName settled unsettled pos@ — the
    -- two outcomes of a bounded revision, the settled artefact bound as the
    -- first name and the last candidate, the one the final review objected to,
    -- bound as the second (D3).
    --
    -- __The two names may coincide__, because they bind in disjoint arms, and
    -- an authoring surface that builds both arms at the same depth will always
    -- make them coincide — which is what every frozen entry carries.
    RawCaseResult !Text !Text !Text !Raw !Raw !Pos
  | -- | @RawCaseEnding x settledName unsettledName abandonedName settled
    -- unsettled abandoned pos@ — the three outcomes of a three-way bounded
    -- revision, each binding the candidate in hand (D4). Legal only immediately
    -- after a 'SrcRevisingOn'.
    RawCaseEnding !Text !Text !Text !Text !Raw !Raw !Raw !Pos
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
        ["x" .= x, "ann" .= maybeCodeToJson ann, "src" .= src, "rest" .= rest, "pos" .= pos]
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
    RawCaseResult x settledName unsettledName settled unsettled pos ->
      ctorObj
        "caseResult"
        [ "x" .= x,
          "settledName" .= settledName,
          "unsettledName" .= unsettledName,
          "settled" .= settled,
          "unsettled" .= unsettled,
          "pos" .= pos
        ]
    RawCaseEnding x sname uname aname settled unsettled abandoned pos ->
      ctorObj
        "caseEnding"
        [ "x" .= x,
          "settledName" .= sname,
          "unsettledName" .= uname,
          "abandonedName" .= aname,
          "settled" .= settled,
          "unsettled" .= unsettled,
          "abandoned" .= abandoned,
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
        <*> (parseMaybeCode =<< (o .:: "ann" :: Parser Value))
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
    -- The decoder __demands__ @unsettledName@: a decoder that defaulted a
    -- missing one to @settledName@ would silently accept an incomplete 'Raw'
    -- after the single regeneration event, which is a hole in the conformance
    -- boundary. (@(.::)@ is liberal only where an @Option@ field accepts
    -- @null@; a 'Text' field's parser fails on it, naming itself.)
    "caseResult" ->
      RawCaseResult
        <$> o .:: "x"
        <*> o .:: "settledName"
        <*> o .:: "unsettledName"
        <*> o .:: "settled"
        <*> o .:: "unsettled"
        <*> o .:: "pos"
    "caseEnding" ->
      RawCaseEnding
        <$> o .:: "x"
        <*> o .:: "settledName"
        <*> o .:: "unsettledName"
        <*> o .:: "abandonedName"
        <*> o .:: "settled"
        <*> o .:: "unsettled"
        <*> o .:: "abandoned"
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
    BodyBind !Text !(Maybe SomeCode) !RawRhs !Pos
  | -- | @BodyAct a pos@
    BodyAct !RawAsk !Pos
  | -- | @BodyCallS fn args pos@
    BodyCallS !Text ![RawArg] !Pos
  deriving (Eq, Show)

instance ToJSON RawBodyStmt where
  toJSON = \case
    BodyBind x ann rhs pos ->
      ctorObj "bind" ["x" .= x, "ann" .= maybeCodeToJson ann, "rhs" .= rhs, "pos" .= pos]
    BodyAct a pos -> ctorObj "act" ["a" .= a, "pos" .= pos]
    BodyCallS f as pos ->
      ctorObj "callS" ["fn" .= f, "args" .= as, "pos" .= pos]

instance FromJSON RawBodyStmt where
  parseJSON = withCtor "RawBodyStmt" $ \tag o -> case tag of
    "bind" ->
      BodyBind <$> o .:: "x" <*> (parseMaybeCode =<< (o .:: "ann" :: Parser Value)) <*> o .:: "rhs" <*> o .:: "pos"
    "act" -> BodyAct <$> o .:: "a" <*> o .:: "pos"
    "callS" -> BodyCallS <$> o .:: "fn" <*> o .:: "args" <*> o .:: "pos"
    _ -> unknownCtor "RawBodyStmt" tag

-- ---------------------------------------------------------------------------
-- Functions and programs
-- ---------------------------------------------------------------------------

-- | @(String × Code)@ is a Lean @Prod@, which encodes as a two-element array:
-- @["p", "text"]@.
paramToJSON :: (Text, SomeCode) -> Value
paramToJSON (p, c) = toJSON [toJSON p, codeToJson c]

paramParseJSON :: Value -> Parser (Text, SomeCode)
paramParseJSON = withArray "RawFn.params" $ \arr -> case V.toList arr of
  [p, c] -> (,) <$> (parseJSON p <?> Key "0") <*> (codeFromJson c <?> Key "1")
  xs ->
    fail $
      "RawFn.params: expected a two-element [name, code] array, but found "
        ++ show (length xs)
        ++ " elements"

-- | One function, as written. A structure: no tag, just its seven fields, in
-- Lean's declaration order.
data RawFn = RawFn
  { fnName :: !Text,
    fnParams :: ![(Text, SomeCode)],
    fnResult :: !SomeCode,
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
        "result" .= codeToJson (fnResult f),
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
      <*> (codeFromJson =<< (o .:: "result" :: Parser Value))
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
