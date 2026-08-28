{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Agentic.World
-- Description : The world as data, the trace, the bills, and the oracle's JSON.
--
-- The port of bare-question meaning: fused `Plan.run`/`Plan.trace`, semantic
-- `Event`/`Trace`, and `billFresh`. The module also carries annotated pure
-- `ExecTrace`, operational memo counting, and v2/v3 JSON projections; these
-- representation observations erase to the semantic trace.
--
-- == What is not here
--
-- No @Dlg@: @Plan.trace ω p γ = Dlg.trace ω (denote p γ)@, and the composite's
-- clauses are exactly the @simp@ lemmas at @Denote.lean:131@–@:149@, so the
-- fused fold ('traceIn') /is/ the definition rather than a shortcut.
--
-- No semantic memo policy, @pin@, @worldOf@, or polymorphic prices. Runtime memo
-- counting consumes `ExecTrace`; it is not a second meaning.
-- monomorphic in the carrier. No 'Agentic.Raw.Pos' anywhere: a 'Q' has no
-- position, because positions are oracle-only, like @message@ and @excerpt@.
--
-- The enclosing observation record — @level@, @size@, @askNodes@, @codes@,
-- @costSummary@, @blockAsks@, @fnAsks@, @worlds@ (@Conformance.lean:252@
-- @observe@) — belongs to tier1, which assembles it from "Agentic.Plan"'s
-- folds, "Agentic.Guards"' ask counts and 'worldObservation'. That is why this
-- module depends on neither @Agentic.Guards@ nor @Agentic.Raw@'s program type.
module Agentic.World
  ( -- * The world, as data
    VLit (..),
    vLitToVerdict,
    TextSpec (..),
    VerdictSpec (..),
    FlagSpec (..),
    WorldSpec (..),
    defaultWorldSpec,
    World (..),
    toWorld,

    -- * The meaning
    Event (..),
    Trace,
    ExecEvent (..),
    ExecTrace,
    forgetExecEvent,
    trace,
    traceIn,
    execTrace,
    execTraceIn,
    runPlan,
    runIn,

    -- * The bills
    EventKey (..),
    eventKey,
    billFresh,
    billExecFresh,
    billMemo,
    billMemoLegacy,

    -- * The oracle's JSON
    verdictJson,
    answerJson,
    answerFromJson,
    questionJson,
    scopeJson,
    eventJson,
    eventJsonWithIntent,
    worldObservation,
    worldObservationWithIntent,
  )
where

import Agentic.Plan
  ( AnswerSource (AnswerAsked),
    El,
    Env (ECons, ENil),
    ExecEvent (ExecEvent),
    ExecTrace,
    Plan (PAsk, PAskC, PCase, PDyn, PRet),
    Q (..),
    Request (..),
    intentName,
    intentIsEffect,
    QScope (..),
    SCode (SAck, SFlag, SStructured, SText, SVerdict),
    VTag (VApprove, VDeclined, VObject),
    Verdict (Approve, Declined, Object),
    evalExpr,
    fromSCode,
    verdictObject,
    verdictTag,
    withRequestPrompt,
  )
import Agentic.Schema (defaultEl)
import Agentic.Schema.Conformance (SomeAnswer, decodeExact, encodeExact, lookupAnswer, uniqueAnswers)
import Agentic.Schema.Json (codeJson)
import Agentic.Raw
  ( Addressee (AddrModel, AddrPerson, AddrTool, AddrToolExec),
    Code,
    SomeCode,
    ctorObj,
    unknownCtor,
    withCtor,
    (.::),
  )
import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, withObject, (.:?), (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Pair, Parser)
import Data.List (find, nub)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V

-- ---------------------------------------------------------------------------
-- The world, specified as data (Conformance.lean:76-:116)
-- ---------------------------------------------------------------------------

-- | @Conformance.lean:76@ — a verdict, as a literal.
--
-- > inductive VLit where
-- >   | approve
-- >   | declined
-- >   | object (objections : List String)
data VLit
  = VLitApprove
  | VLitDeclined
  | VLitObject [Text]
  deriving (Eq, Show)

-- | @VLit.toVerdict@. Built through 'verdictObject', so the Lean invariant
-- @Verdict.object [] = Verdict.approve@ survives a @{"object":{"objections":[]}}@
-- written by hand.
vLitToVerdict :: VLit -> Verdict
vLitToVerdict = \case
  VLitApprove -> Approve
  VLitDeclined -> Declined
  VLitObject os -> verdictObject os

-- | @Conformance.lean:88@ — how the world answers @text@ questions.
--
-- 'TWrap' carries @pre@ then @post@, in Lean's argument order.
data TextSpec
  = -- | the answer is the prompt itself
    TEcho
  | -- | the prompt in brackets: the echo that makes splices visible
    TWrap !Text !Text
  | TConst !Text
  | -- | @"draw:" ++ toString q.draw@, which tells resamplings apart
    TByDraw
  | -- | first entry whose key is a prefix of the prompt wins; else the default
    TByPrefix [(Text, Text)] !Text
  deriving (Eq, Show)

-- | @Conformance.lean:102@ — how the world answers @verdict@ questions.
data VerdictSpec
  = VConst !VLit
  | VByPrefix [(Text, VLit)] !VLit
  deriving (Eq, Show)

-- | @Conformance.lean:108@ — how the world answers @flag@ questions.
data FlagSpec
  = FConst !Bool
  | -- | @q.prompt == s@, exact and unnormalized
    FPromptEq !Text
  | FByPrefix [(Text, Bool)] !Bool
  deriving (Eq, Show)

-- | @Conformance.lean@'s world DSL: three built-in answer policies plus optional
-- exact schema/value pairs. There is no @ack@ field: a receipt is @()@ and the
-- spec is never consulted for one.
data WorldSpec = WorldSpec
  { wsText :: !TextSpec,
    wsVerdict :: !VerdictSpec,
    wsFlag :: !FlagSpec,
    wsSchema :: ![SomeAnswer]
  }
  deriving (Eq, Show)

-- | Built-in fields keep their old defaults; exact schema answers default to
-- the empty table.
defaultWorldSpec :: WorldSpec
defaultWorldSpec = WorldSpec TEcho (VConst VLitApprove) (FConst True) []

-- ---------------------------------------------------------------------------
-- The world DSL's codec
-- ---------------------------------------------------------------------------

-- | Decode a Lean sum some of whose constructors are nullary.
--
-- A nullary constructor is /written/ as the bare string of its name
-- (@"echo"@), which is what Lean's derived @ToJson@ emits and what existing
-- corpus worlds contain; on input the one-key object form Lean's
-- @Json.getTag?@ also admits (@{"echo": {}}@) is accepted too. Every
-- non-nullary constructor of this DSL names all of its arguments, so every one
-- of them takes Lean's named-field object form,
-- @{"ctor": {"arg1": …, "argN": …}}@, without exception — including the
-- one-argument ones. There are no positional arrays anywhere in this
-- encoding.
sumJSON :: String -> [(Text, a)] -> (K.Key -> A.Object -> Parser a) -> Value -> Parser a
sumJSON ty nullaries ctors = \case
  A.String s -> case lookup s nullaries of
    Just a -> pure a
    Nothing -> fail $ ty ++ ": unknown constructor " ++ show s
  v -> flip (withCtor ty) v $ \tag o ->
    case lookup (K.toText tag) nullaries of
      Just a -> pure a
      Nothing -> ctors tag o

instance ToJSON VLit where
  toJSON = \case
    VLitApprove -> "approve"
    VLitDeclined -> "declined"
    VLitObject os -> ctorObj "object" ["objections" .= os]

instance FromJSON VLit where
  parseJSON = sumJSON "VLit" [("approve", VLitApprove), ("declined", VLitDeclined)] $
    \tag o -> case tag of
      "object" -> VLitObject <$> o .:: "objections"
      _ -> unknownCtor "VLit" tag

instance ToJSON TextSpec where
  toJSON = \case
    TEcho -> "echo"
    TByDraw -> "byDraw"
    TWrap pre post -> ctorObj "wrap" ["pre" .= pre, "post" .= post]
    TConst s -> ctorObj "const" ["s" .= s]
    TByPrefix table d -> ctorObj "byPrefix" ["table" .= table, "default" .= d]

instance FromJSON TextSpec where
  parseJSON = sumJSON "TextSpec" [("echo", TEcho), ("byDraw", TByDraw)] $
    \tag o -> case tag of
      "wrap" -> TWrap <$> o .:: "pre" <*> o .:: "post"
      "const" -> TConst <$> o .:: "s"
      "byPrefix" -> TByPrefix <$> o .:: "table" <*> o .:: "default"
      _ -> unknownCtor "TextSpec" tag

instance ToJSON VerdictSpec where
  toJSON = \case
    VConst v -> ctorObj "const" ["v" .= v]
    VByPrefix table d -> ctorObj "byPrefix" ["table" .= table, "default" .= d]

instance FromJSON VerdictSpec where
  parseJSON = sumJSON "VerdictSpec" [] $ \tag o -> case tag of
    "const" -> VConst <$> o .:: "v"
    "byPrefix" -> VByPrefix <$> o .:: "table" <*> o .:: "default"
    _ -> unknownCtor "VerdictSpec" tag

instance ToJSON FlagSpec where
  toJSON = \case
    FConst b -> ctorObj "const" ["b" .= b]
    FPromptEq s -> ctorObj "promptEq" ["s" .= s]
    FByPrefix table d -> ctorObj "byPrefix" ["table" .= table, "default" .= d]

instance FromJSON FlagSpec where
  parseJSON = sumJSON "FlagSpec" [] $ \tag o -> case tag of
    "const" -> FConst <$> o .:: "b"
    "promptEq" -> FPromptEq <$> o .:: "s"
    "byPrefix" -> FByPrefix <$> o .:: "table" <*> o .:: "default"
    _ -> unknownCtor "FlagSpec" tag

-- | Existing worlds retain their three fields; exact schema answers are added
-- only when present.
instance ToJSON WorldSpec where
  toJSON (WorldSpec text verdict flag schema) =
    object $
      ["text" .= text, "verdict" .= verdict, "flag" .= flag]
        ++ if null schema then [] else ["schema" .= schema]

-- | Liberal in: a missing field — and, for good measure, an explicit @null@ —
-- reads as the Lean structure's default for it ('defaultWorldSpec').
instance FromJSON WorldSpec where
  parseJSON = withObject "WorldSpec" $ \o -> do
    text <- fromMaybe (wsText defaultWorldSpec) <$> o .:? "text"
    verdict <- fromMaybe (wsVerdict defaultWorldSpec) <$> o .:? "verdict"
    flag <- fromMaybe (wsFlag defaultWorldSpec) <$> o .:? "flag"
    schema <- fromMaybe [] <$> o .:? "schema"
    if uniqueAnswers schema
      then pure (WorldSpec text verdict flag schema)
      else fail "WorldSpec.schema contains two answers for one schema"

-- ---------------------------------------------------------------------------
-- toWorld
-- ---------------------------------------------------------------------------

-- | Bare-question answer sheet, mirroring Lean K1.
newtype World = World
  { worldAnswer :: forall (c :: Code). SCode c -> Q c -> El c
  }

-- | @WorldSpec.toWorld@ (@Conformance.lean:121@), clause for clause.
--
-- Three details the corpus does not exercise but the Lean does fix:
-- 'TByPrefix'\/'VByPrefix'\/'FByPrefix' are __first match wins__ over the table
-- in order, testing the key as a /prefix/ of the prompt; 'FPromptEq' is exact
-- equality on the whole prompt with no normalization; and @ack@ is @()@ without
-- consulting the spec at all.
toWorld :: WorldSpec -> World
toWorld w = World answer
  where
    answer :: SCode c -> Q c -> El c
    answer SText q = textAnswer q
    answer SVerdict q = case wsVerdict w of
      VConst v -> vLitToVerdict v
      VByPrefix table d -> vLitToVerdict (byPrefix table d (qPrompt q))
    answer SFlag q = case wsFlag w of
      FConst b -> b
      FPromptEq s -> qPrompt q == s
      FByPrefix table d -> byPrefix table d (qPrompt q)
    answer SAck _ = ()
    answer code@(SStructured schema) _ =
      fromMaybe (defaultEl code) (lookupAnswer (wsSchema w) schema)

    textAnswer :: Q d -> Text
    textAnswer q = case wsText w of
      TEcho -> qPrompt q
      TWrap pre post -> pre <> qPrompt q <> post
      TConst s -> s
      TByDraw -> "draw:" <> T.pack (show (qDraw q))
      TByPrefix table d -> byPrefix table d (qPrompt q)

-- | @table.find? (fun e => e.1.isPrefixOf q.prompt)@, defaulting.
byPrefix :: [(Text, a)] -> a -> Text -> a
byPrefix table d s = maybe d snd (find (\e -> fst e `T.isPrefixOf` s) table)

-- ---------------------------------------------------------------------------
-- Event, Trace, and the fused fold
-- ---------------------------------------------------------------------------

-- | Bare semantic question and reply.
data Event where
  Event :: SCode c -> Q c -> El c -> Event

-- | @Agentic\/Core\/Dlg.lean:124@ — the transcript: the free monoid on 'Event'.
-- Concatenation is @++@ and the empty transcript is @[]@, which is what makes
-- 'billFresh' a monoid morphism out of it.
type Trace = [Event]

-- | @Plan.trace ω p Env.nil@ — what a closed plan consults, in order, in the
-- world @ω@. The one tier1 calls.
trace :: World -> Plan '[] a -> Trace
trace w = traceIn w ENil

-- | @Plan.trace@ in an arbitrary context: @Dlg.trace ω (denote p γ)@, fused.
--
-- > traceIn _ _ (PRet _)         = []
-- > traceIn w y (PAskC c q k)    = Event c q a : traceIn w (ECons a y) k
-- > traceIn w y (PAsk c s e k)   = Event c q a : traceIn w (ECons a y) k
-- > traceIn w y (PCase _ e arms) = traceIn w y (arms (e y))
-- > traceIn w y (PDyn _ e f)     = traceIn w y (f (e y))
--
-- Three things this fold has to get right, all of which the corpus catches:
--
-- * the answer is computed once and both recorded in the event /and/ pushed
--   onto the environment;
-- * an ask node's question is @s.withPrompt (e γ)@ — the prompt is evaluated in
--   the environment __before__ the answer is bound, so a splice reads what was
--   already answered and never what this question will answer;
-- * @case@ and @dyn@ record nothing. The branch taken is the whole of their
--   contribution (@Denote.lean:60@: the two share a meaning clause on purpose).
traceIn :: World -> Env g -> Plan g a -> Trace
traceIn _ _ (PRet _) = []
traceIn w y (PAskC c r k) =
  let q = reqQuestion r
      a = worldAnswer w c q
   in Event c q a : traceIn w (ECons a y) k
traceIn w y (PAsk c s e k) =
  let r = withRequestPrompt s (evalExpr e y)
      q = reqQuestion r
      a = worldAnswer w c q
   in Event c q a : traceIn w (ECons a y) k
traceIn w y (PCase _ e arms) = traceIn w y (arms (evalExpr e y))
traceIn w y (PDyn _ e f) = traceIn w y (f (evalExpr e y))

-- | Forget execution annotation and dispatched attribution.
forgetExecEvent :: ExecEvent -> Event
forgetExecEvent (ExecEvent c r _ a) = Event c (reqQuestion r) a

-- | Pure annotated trace. Every occurrence is freshly answered by its authored
-- question; runtime memo/failover sources are recorded by Agentic.Exec.
execTrace :: World -> Plan '[] a -> ExecTrace
execTrace w = execTraceIn w ENil

execTraceIn :: World -> Env g -> Plan g a -> ExecTrace
execTraceIn _ _ (PRet _) = []
execTraceIn w y (PAskC c r k) =
  let q = reqQuestion r
      a = worldAnswer w c q
   in ExecEvent c r (AnswerAsked q) a : execTraceIn w (ECons a y) k
execTraceIn w y (PAsk c s e k) =
  let r = withRequestPrompt s (evalExpr e y)
      q = reqQuestion r
      a = worldAnswer w c q
   in ExecEvent c r (AnswerAsked q) a : execTraceIn w (ECons a y) k
execTraceIn w y (PCase _ e arms) = execTraceIn w y (arms (evalExpr e y))
execTraceIn w y (PDyn _ e f) = execTraceIn w y (f (evalExpr e y))

-- | @Plan.run@ in the empty context — the answer rather than the transcript.
-- No part of the oracle's record, but free from the same fold and useful in a
-- tier1 assertion.
runPlan :: World -> Plan '[] a -> a
runPlan w = runIn w ENil

-- | @Plan.run ω p γ@ (@Denote.lean:114@), fused through @denote@ the same way
-- 'traceIn' is.
runIn :: World -> Env g -> Plan g a -> a
runIn _ y (PRet e) = evalExpr e y
runIn w y (PAskC c r k) =
  let a = worldAnswer w c (reqQuestion r)
   in runIn w (ECons a y) k
runIn w y (PAsk c s e k) =
  let r = withRequestPrompt s (evalExpr e y)
      a = worldAnswer w c (reqQuestion r)
   in runIn w (ECons a y) k
runIn w y (PCase _ e arms) = runIn w y (arms (evalExpr e y))
runIn w y (PDyn _ e f) = runIn w y (f (evalExpr e y))

-- ---------------------------------------------------------------------------
-- The bills
-- ---------------------------------------------------------------------------

-- | Bare semantic key: code plus every question field, answer forgotten.
data EventKey = EventKey
  { ekCode :: !SomeCode,
    ekAddressee :: !Addressee,
    ekScope :: !QScope,
    ekPrompt :: !Text,
    ekDraw :: !Integer
  }
  deriving (Eq, Show)

instance Ord EventKey where
  compare a b = compare (ordKey a) (ordKey b)
    where
      ordKey k =
        ( ekCode k,
          addresseeOrd (ekAddressee k),
          (scopeModelAxis (ekScope k), scopeModeAxis (ekScope k)),
          ekPrompt k,
          ekDraw k
        )
      addresseeOrd :: Addressee -> (Int, Text, Text, [Text])
      addresseeOrd = \case
        AddrModel i -> (0, i, T.empty, [])
        AddrTool i -> (1, i, T.empty, [])
        AddrPerson i -> (2, i, T.empty, [])
        AddrToolExec i cmd args -> (3, i, cmd, args)

questionKey :: SCode c -> Q c -> EventKey
questionKey c q =
  EventKey
    (fromSCode c)
    (qAddressee q)
    (qScope q)
    (qPrompt q)
    (qDraw q)

eventKey :: Event -> EventKey
eventKey (Event c q _) = questionKey c q

execEventKey :: ExecEvent -> EventKey
execEventKey (ExecEvent c r _ _) = questionKey c (reqQuestion r)

execEventIsEffect :: ExecEvent -> Bool
execEventIsEffect (ExecEvent _ r _ _) = intentIsEffect (reqIntent r)

-- | Semantic fresh bill: one unit per bare-question event.
billFresh :: Trace -> Integer
billFresh = fromIntegral . length

-- | Operational fresh bill: one unit per annotated Plan occurrence.
billExecFresh :: ExecTrace -> Integer
billExecFresh = fromIntegral . length

-- | Operational memo projection: reusable identity is bare Q, effects are kept
-- per occurrence, and retained events preserve their own authored annotation.
execMemoEvents :: ExecTrace -> ExecTrace
execMemoEvents [] = []
execMemoEvents (e : es)
  | execEventIsEffect e = e : execMemoEvents es
  | execEventKey e `elem` map execEventKey (filter (not . execEventIsEffect) es) =
      execMemoEvents es
  | otherwise = e : execMemoEvents es

billMemo :: ExecTrace -> Integer
billMemo = fromIntegral . length . execMemoEvents

-- | Frozen v2 projection over semantic trace: every bare question once.
billMemoLegacy :: Trace -> Integer
billMemoLegacy = fromIntegral . length . nub . map eventKey

-- ---------------------------------------------------------------------------
-- The oracle's JSON (Conformance.lean:155-:238)
-- ---------------------------------------------------------------------------

-- | @Conformance.lean:155@ — a verdict as data: its tag, and the objections
-- where the tag carries any.
--
-- @{"tag":"approve"}@ and @{"tag":"declined"}@ have __no__ @objections@ key;
-- only the @object@ case carries the array. The dispatch is 'verdictTag', so
-- the unit @Object []@ serializes as approval however it was built.
verdictJson :: Verdict -> Value
verdictJson v = case verdictTag v of
  VApprove -> object ["tag" .= ("approve" :: Text)]
  VDeclined -> object ["tag" .= ("declined" :: Text)]
  VObject -> object ["tag" .= ("object" :: Text), "objections" .= objectionsOf v]
  where
    objectionsOf :: Verdict -> [Text]
    objectionsOf (Object os) = os
    objectionsOf _ = []

-- | @Conformance.lean:166@ — an answer, at its code. A receipt is an explicit
-- JSON @null@, never an omitted key.
answerJson :: SCode c -> El c -> Value
answerJson SText s = A.String s
answerJson SVerdict v = verdictJson v
answerJson SFlag b = A.Bool b
answerJson SAck _ = A.Null
answerJson (SStructured schema) value = encodeExact schema value

answerFromJson :: SCode c -> Value -> Maybe (El c)
answerFromJson SText (A.String value) = Just value
answerFromJson SFlag (A.Bool value) = Just value
answerFromJson SAck A.Null = Just ()
answerFromJson SVerdict (A.Object value) = case KM.lookup "tag" value of
  Just (A.String "approve") -> Just Approve
  Just (A.String "declined") -> Just Declined
  Just (A.String "object") -> do
    A.Array objections <- KM.lookup "objections" value
    Object <$> traverse objectionText (V.toList objections)
  _ -> Nothing
  where
    objectionText (A.String text) = Just text
    objectionText _ = Nothing
answerFromJson (SStructured schema) value = decodeExact schema value
answerFromJson _ _ = Nothing

questionJson :: SCode c -> Q c -> Value
questionJson c q =
  object
    [ "code" .= codeJson (fromSCode c),
      "addressee" .= qAddressee q,
      "scope" .= scopeJson (qScope q),
      "prompt" .= qPrompt q,
      "draw" .= qDraw q
    ]

-- | @Conformance.lean:172@ — the two scope axes, __both keys always present__,
-- @null@ where the axis is silent. The second key is @mode@; nothing in this
-- language ever sets it, and it exists because the scope monoid has two axes.
scopeJson :: QScope -> Value
scopeJson s =
  object
    [ "model" .= maybe A.Null A.String (scopeModelAxis s),
      "mode" .= maybe A.Null A.String (scopeModeAxis s)
    ]

-- | @Conformance.lean:177@ — one event of the reply's @"trace"@ array.
--
-- Built-ins retain the old strings (`receipt`, never `ack`); a schema-indexed
-- code is an object carrying the schema that is part of question identity. The
-- prompt is the evaluated words, not the chunk list.

eventFields :: SCode c -> Q c -> El c -> [Pair]
eventFields c q a =
  [ "code" .= codeJson (fromSCode c),
    "addressee" .= qAddressee q,
    "scope" .= scopeJson (qScope q),
    "prompt" .= qPrompt q,
    "draw" .= qDraw q,
    "answer" .= answerJson c a
  ]

eventJson :: Event -> Value
eventJson (Event c q a) = object (eventFields c q a)

-- | Version-3 representation event. Question fields are authored; dispatch and
-- answer-source attribution remain execution metadata outside this wire version.
eventJsonWithIntent :: ExecEvent -> Value
eventJsonWithIntent (ExecEvent c r _ a) =
  object $
    ["code" .= codeJson (fromSCode c), "intent" .= intentName (reqIntent r)]
      ++ drop 1 (eventFields c (reqQuestion r) a)


-- | Frozen semantic v2 observation.
worldObservation :: Plan '[] () -> WorldSpec -> Value
worldObservation p w =
  let semantic = trace (toWorld w) p
   in object
        [ "world" .= w,
          "trace" .= map eventJson semantic,
          "billFresh" .= billFresh semantic,
          "billMemo" .= billMemoLegacy semantic
        ]

-- | Annotated representation v3 plus its bare semantic erasure.
worldObservationWithIntent :: Plan '[] () -> WorldSpec -> Value
worldObservationWithIntent p w =
  let world = toWorld w
      semantic = trace world p
      operational = execTrace world p
   in object
        [ "world" .= w,
          "trace" .= map eventJsonWithIntent operational,
          "semanticTrace" .= map eventJson semantic,
          "billFresh" .= billExecFresh operational,
          "billMemo" .= billMemo operational
        ]
