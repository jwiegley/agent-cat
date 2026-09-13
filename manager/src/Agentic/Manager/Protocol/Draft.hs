{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Frozen draft, readiness and capture representations, without storage authority.
module Agentic.Manager.Protocol.Draft
  ( CreateDraft (..), InputChange (..), InputDeclaration (..), SuppliedInput (..),
    InputError (..), Readiness (..), DraftView (..), CaptureReceipt (..),
    suppliedName, decodeDraftBody, inputNameValid
  ) where

import Agentic.Manager.Protocol.Command (CommandFailure (..), validId)
import Agentic.Manager.Protocol.Json (decodeStrictValue)
import Control.DeepSeq (NFData)
import Control.Monad (unless)
import Data.Aeson (FromJSON (parseJSON), ToJSON (toJSON), Value (..), object, withObject, (.:), (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Object, Parser, parseEither)
import qualified Data.ByteString as BS
import Data.Int (Int64)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

data CreateDraft = CreateDraft
  { createWorkflow :: !Text, createDescriptorRevision :: !Text,
    createProfile :: !Text, createProfileRevision :: !Text
  } deriving (Eq, Show, Generic, NFData)
instance FromJSON CreateDraft where
  parseJSON = withObject "create request" $ \o -> do
    closed ["workflowId","descriptorRevision","profileId","profileRevision"] o
    value <- CreateDraft <$> o .: "workflowId" <*> o .: "descriptorRevision" <*> o .: "profileId" <*> o .: "profileRevision"
    unless (all validId [createWorkflow value,createDescriptorRevision value,createProfile value,createProfileRevision value]) (fail "request identities")
    pure value

-- | Logical literals and opaque capture selectors remain distinct.
data SuppliedInput = LiteralValue !Text !Text | CapturedValue !Text !Text deriving (Eq, Show, Generic, NFData)
suppliedName :: SuppliedInput -> Text
suppliedName (LiteralValue name _) = name
suppliedName (CapturedValue name _) = name
instance ToJSON SuppliedInput where
  toJSON (LiteralValue name value) = object ["name" .= name,"source" .= ("literal" :: Text),"value" .= value]
  toJSON (CapturedValue name ident) = object ["name" .= name,"source" .= ("capture" :: Text),"captureId" .= ident]
instance FromJSON SuppliedInput where
  parseJSON = withObject "supplied input" $ \o -> do
    name <- o .: "name"
    unless (inputNameValid name) (fail "input name")
    source <- o .: "source"
    case source :: Text of
      "literal" -> do
        closed ["name","source","value"] o
        value <- o .: "value"
        unless (T.length value <= 2097152) (fail "literal bound")
        pure (LiteralValue name value)
      "capture" -> do
        closed ["name","source","captureId"] o
        ident <- o .: "captureId"
        unless (validId ident) (fail "capture identity")
        pure (CapturedValue name ident)
      _ -> fail "input representation"

data InputChange = SetBinding !SuppliedInput | RemoveBinding !Text deriving (Eq, Show, Generic, NFData)
instance FromJSON InputChange where
  parseJSON = withObject "input mutation" $ \o -> do
    operation <- o .: "operation"
    case operation :: Text of
      "set-input" -> closed ["operation","input"] o >> SetBinding <$> o .: "input"
      "remove-input" -> do
        closed ["operation","name"] o
        name <- o .: "name"
        unless (inputNameValid name) (fail "input name")
        pure (RemoveBinding name)
      _ -> fail "not an input mutation"

data InputDeclaration = InputDeclaration !Text !Text deriving (Eq, Show, Generic, NFData)
instance ToJSON InputDeclaration where
  toJSON (InputDeclaration name source) = object ["name" .= name,"source" .= source,"description" .= Null,
    "required" .= True,"schema" .= object ["type" .= ("string" :: Text)]]
instance FromJSON InputDeclaration where
  parseJSON = withObject "input declaration" $ \o -> do
    closed ["name","source","description","required","schema"] o
    name <- o .: "name"
    source <- o .: "source"
    description <- o .: "description"
    required <- o .: "required"
    schema <- o .: "schema"
    unless (inputNameValid name && source `elem` ["prompt","command-tail","stdin"] && description == Null
      && required && schema == object ["type" .= ("string" :: Text)]) (fail "input declaration")
    pure (InputDeclaration name source)

data InputError = InputError !Text !Text deriving (Eq, Show, Generic, NFData)
instance ToJSON InputError where toJSON (InputError name code) = object ["name" .= name,"code" .= code]
instance FromJSON InputError where
  parseJSON = withObject "input error" $ \o -> do
    closed ["name","code"] o
    name <- o .: "name"
    code <- o .: "code"
    unless (inputNameValid name && code `elem` ["unknown-input","invalid-input","capture-unavailable","size-limit"]) (fail "input error")
    pure (InputError name code)

data Readiness = Readiness ![InputDeclaration] ![SuppliedInput] ![Text] ![InputError] deriving (Eq, Show, Generic, NFData)
instance ToJSON Readiness where
  toJSON (Readiness declarations supplied missing errors) = object ["declarations" .= declarations,"supplied" .= supplied,"missing" .= missing,"errors" .= errors]
instance FromJSON Readiness where
  parseJSON = withObject "readiness" $ \o -> do
    closed ["declarations","supplied","missing","errors"] o
    declarations <- o .: "declarations"
    supplied <- o .: "supplied"
    missing <- o .: "missing"
    errors <- o .: "errors"
    let names = [name | InputDeclaration name _ <- declarations]
        present = map suppliedName supplied
    unless (all (<=256) [length names,length present,length missing,length errors]
      && Set.size (Set.fromList names) == length names && Set.size (Set.fromList present) == length present
      && all (`elem` names) present && missing == filter (`notElem` present) names) (fail "readiness names")
    pure (Readiness declarations supplied missing errors)

data DraftView = DraftView
  { draftId :: !Text, draftRevision :: !Text, draftWorkflow :: !Text, draftDescriptorRevision :: !Text,
    draftProfile :: !Text, draftProfileRevision :: !Text, draftPhase :: !Text, draftReadiness :: !Readiness,
    draftAdmission :: !Text, draftPosition :: !(Maybe Int), draftReasons :: ![Text],
    draftPreparation :: !(Maybe Text), draftRun :: !(Maybe Text), draftParent :: !(Maybe Text), draftLineage :: !(Maybe Text)
  } deriving (Eq, Show, Generic, NFData)
instance ToJSON DraftView where
  toJSON d = object ["version" .= (1::Int),"id" .= draftId d,"revision" .= draftRevision d,
    "workflowId" .= draftWorkflow d,"descriptorRevision" .= draftDescriptorRevision d,"profileId" .= draftProfile d,
    "profileRevision" .= draftProfileRevision d,"phase" .= draftPhase d,"readiness" .= draftReadiness d,
    "admission" .= object ["state" .= draftAdmission d,"position" .= draftPosition d,"reasons" .= draftReasons d],
    "preparationId" .= draftPreparation d,"runId" .= draftRun d,"parentRunId" .= draftParent d,"lineage" .= draftLineage d,
    "links" .= object ["self" .= ("/v1/requests/" <> draftId d)]]
instance FromJSON DraftView where
  parseJSON = withObject "request" $ \o -> do
    closed ["version","id","revision","workflowId","descriptorRevision","profileId","profileRevision","phase","readiness","admission","preparationId","runId","parentRunId","lineage","links"] o
    version <- o .: "version"
    unless (version == (1::Int)) (fail "request version")
    admission <- o .: "admission"
    closed ["state","position","reasons"] admission
    d <- DraftView <$> o .: "id" <*> o .: "revision" <*> o .: "workflowId" <*> o .: "descriptorRevision"
      <*> o .: "profileId" <*> o .: "profileRevision" <*> o .: "phase" <*> o .: "readiness"
      <*> admission .: "state" <*> admission .: "position" <*> admission .: "reasons"
      <*> o .: "preparationId" <*> o .: "runId" <*> o .: "parentRunId" <*> o .: "lineage"
    unless (all validId [draftId d,draftRevision d,draftWorkflow d,draftDescriptorRevision d,draftProfile d,draftProfileRevision d]
      && all (maybe True validId) [draftPreparation d,draftRun d,draftParent d]
      && draftPhase d `elem` ["draft","queued","preparing","review","start-pending","associated","withdrawn","refused"]
      && draftAdmission d `elem` ["not-queued","waiting","reserved","released","refused"]
      && maybe True (\n -> n>=1 && n<=100) (draftPosition d)
      && length (draftReasons d)<=8 && Set.size(Set.fromList(draftReasons d))==length(draftReasons d)
      && all (`elem` ["missing-inputs","profile-busy","workspace-busy","target-busy","store-busy","capacity","quarantined","storage-quota"]) (draftReasons d)
      && maybe True (`elem` ["restart","resume","fork"]) (draftLineage d)) (fail "request fields")
    links <- o .: "links"
    unless (links == object ["self" .= ("/v1/requests/" <> draftId d)]) (fail "request links")
    pure d

data CaptureReceipt = CaptureReceipt
  { captureId :: !Text, captureRequest :: !Text, captureProfile :: !Text, captureBytes :: !Int64, captureDigest :: !Text
  } deriving (Eq, Show, Generic, NFData)
instance ToJSON CaptureReceipt where
  toJSON c = object ["version" .= (1::Int),"id" .= captureId c,"requestId" .= captureRequest c,"profileId" .= captureProfile c,
    "bytes" .= T.pack(show(captureBytes c)),"sha256" .= captureDigest c]
instance FromJSON CaptureReceipt where
  parseJSON = withObject "capture" $ \o -> do
    closed ["version","id","requestId","profileId","bytes","sha256"] o
    version <- o .: "version"
    number <- o .: "bytes"
    unless (T.length number<=8) (fail "capture byte bound")
    count <- case reads (T.unpack number) of [(n,"")] | (n::Int64)>=0 && n<=67108864 && number==T.pack(show n) -> pure n; _ -> fail "capture bytes"
    c <- CaptureReceipt <$> o .: "id" <*> o .: "requestId" <*> o .: "profileId" <*> pure count <*> o .: "sha256"
    unless (version==(1::Int) && all validId [captureId c,captureRequest c,captureProfile c] && T.length(captureDigest c)==64
      && T.all (`elem` ("0123456789abcdef"::String)) (captureDigest c)) (fail "capture fields")
    pure c

decodeDraftBody :: FromJSON a => BS.ByteString -> Either CommandFailure a
decodeDraftBody bytes
  | BS.length bytes > 2097152 = Left SizeLimit
  | otherwise = either (const(Left InvalidRequest)) Right (decodeStrictValue bytes >>= parseEither parseJSON)

inputNameValid :: Text -> Bool
inputNameValid name = not(T.null name) && T.length name<=1024 && not(T.any(=='\0') name)
closed :: [Text] -> Object -> Parser ()
closed names o = unless (length names==KM.size o && all ((`elem` names).Key.toText) (KM.keys o)) (fail "object fields")
