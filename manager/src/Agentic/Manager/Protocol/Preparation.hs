{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Bounded public review facts and exact approval requests, without execution authority.
module Agentic.Manager.Protocol.Preparation
  ( ReviewInput (..), Review (..), Preparation (..), ApprovalRequest (..),
    PublicPolicy, policyValue, projectPolicy, decodeApproval, validDigest, observationCodeNames ) where

import Agentic.Manager.Protocol.Command (CommandFailure (..), validId, validTimestamp)
import Agentic.Manager.Protocol.Json (decodeStrictValue)
import Control.DeepSeq (NFData)
import Control.Monad (unless, forM_, when)
import Data.Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString as BS
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

-- | The frozen allowlisted policy of one actual prepared response.
newtype PublicPolicy = PublicPolicy Value
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)
policyValue :: PublicPolicy -> Value
policyValue (PublicPolicy value)=value
instance ToJSON PublicPolicy where toJSON=policyValue
instance FromJSON PublicPolicy where parseJSON value=validatePolicy value >> pure(PublicPolicy value)

-- | A captured input's original representation and exact native byte identity.
data ReviewInput = ReviewInput {reviewInputName:: !Text,reviewInputSource:: !Text,reviewInputBytes:: !Text,reviewInputSha256:: !Text}
  deriving (Eq,Show,Generic,NFData)
instance ToJSON ReviewInput where
  toJSON value=object["name" .= reviewInputName value,"source" .= reviewInputSource value,"bytes" .= reviewInputBytes value,"sha256" .= reviewInputSha256 value]
instance FromJSON ReviewInput where
  parseJSON=withObject "review input" $ \o->do
    closed ["name","source","bytes","sha256"] o
    value<-ReviewInput <$> o .: "name" <*> o .: "source" <*> o .: "bytes" <*> o .: "sha256"
    unless(bounded 1 1024(reviewInputName value) && reviewInputSource value `elem` ["literal","capture"] && decimal(reviewInputBytes value) && validDigest(reviewInputSha256 value))(fail "review input")
    pure value

-- | The exact bounded consent facts of one native preparation.
data Review = Review
  { reviewProgramHash:: !Text,reviewPerson:: !Text,reviewPolicy:: !PublicPolicy,
    reviewWorkflow:: !Text,reviewProfile:: !Text,reviewWorkspaceLabel:: !Text,reviewTargetLabel:: !Text,
    reviewInputs:: ![ReviewInput],reviewPlan:: !Text,reviewRunFacts:: ![Text],reviewPins:: ![Text],
    reviewWarnings:: ![Text],reviewResultCode:: !Value }
  deriving (Eq,Show,Generic,NFData)
instance ToJSON Review where
  toJSON r=object["programHash" .= reviewProgramHash r,"personAnswering" .= reviewPerson r,"policy" .= reviewPolicy r,
    "workflowId" .= reviewWorkflow r,"profileId" .= reviewProfile r,"workspaceLabel" .= reviewWorkspaceLabel r,"targetLabel" .= reviewTargetLabel r,
    "inputs" .= reviewInputs r,"plan" .= reviewPlan r,"runFacts" .= reviewRunFacts r,"pins" .= reviewPins r,"warnings" .= reviewWarnings r,"resultCode" .= reviewResultCode r]
instance FromJSON Review where
  parseJSON=withObject "review" $ \o->do
    closed ["programHash","personAnswering","policy","workflowId","profileId","workspaceLabel","targetLabel","inputs","plan","runFacts","pins","warnings","resultCode"] o
    r<-Review <$> o .: "programHash" <*> o .: "personAnswering" <*> o .: "policy" <*> o .: "workflowId" <*> o .: "profileId" <*> o .: "workspaceLabel" <*> o .: "targetLabel" <*> o .: "inputs" <*> o .: "plan" <*> o .: "runFacts" <*> o .: "pins" <*> o .: "warnings" <*> o .: "resultCode"
    unless(validDigest(reviewProgramHash r) && reviewPerson r `elem` ["engine","local-control"] && all validId[reviewWorkflow r,reviewProfile r]
      && all(bounded 0 4096)[reviewWorkspaceLabel r,reviewTargetLabel r] && bounded 0 524288(reviewPlan r)
      && length(reviewInputs r)<=256 && all (\xs->length xs<=256 && all(bounded 0 4096)xs)[reviewRunFacts r,reviewPins r,reviewWarnings r])(fail "review bounds")
    unless(validObservationCode(reviewResultCode r))(fail "observation code")
    pure r

-- | One versioned public preparation, not a restored live worker or approval permit.
data Preparation = Preparation
  { preparationId:: !Text,preparationRevision:: !Text,preparationRequest:: !Text,preparationRequestRevision:: !Text,
    preparationProfile:: !Text,preparationProfileRevision:: !Text,preparationDescriptorRevision:: !Text,
    preparationState:: !Text,preparationExpiresAt:: !Text,preparationDigest:: !Text,
    preparationGeneration:: !Text,preparationReview:: !Review,preparationReason:: !(Maybe Text) }
  deriving (Eq,Show,Generic,NFData)
instance ToJSON Preparation where
  toJSON p=object["version" .= (1::Int),"id" .= preparationId p,"revision" .= preparationRevision p,"requestId" .= preparationRequest p,
    "requestRevision" .= preparationRequestRevision p,"profileId" .= preparationProfile p,"profileRevision" .= preparationProfileRevision p,
    "descriptorRevision" .= preparationDescriptorRevision p,"state" .= preparationState p,"expiresAt" .= preparationExpiresAt p,
    "reviewDigest" .= preparationDigest p,"processGeneration" .= preparationGeneration p,"review" .= preparationReview p,"reason" .= preparationReason p]
instance FromJSON Preparation where
  parseJSON=withObject "preparation" $ \o->do
    closed ["version","id","revision","requestId","requestRevision","profileId","profileRevision","descriptorRevision","state","expiresAt","reviewDigest","processGeneration","review","reason"] o
    version<-o .: "version"
    unless(version==(1::Int))(fail "preparation version")
    p<-Preparation <$> o .: "id" <*> o .: "revision" <*> o .: "requestId" <*> o .: "requestRevision" <*> o .: "profileId" <*> o .: "profileRevision" <*> o .: "descriptorRevision" <*> o .: "state" <*> o .: "expiresAt" <*> o .: "reviewDigest" <*> o .: "processGeneration" <*> o .: "review" <*> o .: "reason"
    unless(all validId[preparationId p,preparationRevision p,preparationRequest p,preparationRequestRevision p,preparationProfile p,preparationProfileRevision p,preparationDescriptorRevision p,preparationGeneration p]
      && preparationState p `elem` ["live","consumed","invalidated"] && validTimestamp(preparationExpiresAt p) && validDigest(preparationDigest p)
      && maybe True (`elem` ["expired","input-changed","profile-changed","worker-lost","discarded","authority-changed","consumed"]) (preparationReason p))(fail "preparation fields")
    pure p

-- | Exact selectors submitted with one preparation's strong validator.
data ApprovalRequest = ApprovalRequest !Text !Text !Text !Text !Text deriving (Eq,Show,Generic,NFData)
instance FromJSON ApprovalRequest where
  parseJSON=withObject "approval" $ \o->do
    closed ["operation","reviewDigest","requestRevision","profileRevision","descriptorRevision","processGeneration"] o
    operation<-o .: "operation"
    unless(operation==("approve"::Text))(fail "approval operation")
    digest<-o .: "reviewDigest";request<-o .: "requestRevision";profile<-o .: "profileRevision";descriptor<-o .: "descriptorRevision";generation<-o .: "processGeneration"
    unless(validDigest digest && all validId[request,profile,descriptor,generation])(fail "approval selectors")
    pure(ApprovalRequest digest request profile descriptor generation)

decodeApproval :: BS.ByteString -> Either CommandFailure ApprovalRequest
decodeApproval bytes
  | BS.length bytes>2097152 = Left SizeLimit
  | otherwise = either(const(Left InvalidRequest))Right(decodeStrictValue bytes >>= parseEither parseJSON)

projectPolicy :: Value -> Either CommandFailure PublicPolicy
projectPolicy raw = either(const(Left InvalidInput))Right $ parseEither project raw
  where
    project = withObject "native policy" $ \o->do
      kind<-o .: "kind"
      let allowed=if kind==("scripted"::Text) then ["kind"] else policyKeys
          keep fields object'=KM.filterWithKey (\key _->Key.toText key `elem` fields) object'
          projected=keep allowed o
      routes<-case KM.lookup "realizations" projected of
        Just(Array values)->Just . toJSON <$> mapM (withObject "realization" (pure . Object . keep realizationKeys)) (foldr(:)[]values)
        value->pure value
      routeRows<-case KM.lookup "routes" projected of
        Just(Array values)->Just . toJSON <$> mapM (withObject "route" (pure . Object . keep ["name","backend"])) (foldr(:)[]values)
        value->pure value
      let realized=maybe projected (\rows->KM.insert "realizations" rows projected)routes
          value=Object(maybe realized (\rows->KM.insert "routes" rows realized)routeRows)
      parseJSON value

policyKeys,realizationKeys :: [Text]
policyKeys=["kind","default","coverage","routes","pollMs","timeoutMs","verbose","realizations","routingVersion","persona","personaSource","policyDigest"]
realizationKeys=["profile","axis","rung","backend","router","provider","model","thinking","maxOutput","executionFingerprint","modelAlias","engine"]
validatePolicy :: Value -> Parser ()
validatePolicy=withObject "public policy" $ \o->do
  kind<-o .: "kind"
  case kind::Text of
    "scripted"->closed["kind"]o
    "routed"->do
      closed policyKeys o
      unless(KM.member "default" o /= KM.member "coverage" o)(fail "policy coverage")
      case KM.lookup "default" o of Just value->label value;Nothing->do coverage<-o .: "coverage";unless(coverage==("full"::Text))(fail "coverage")
      routes<-o .: "routes"::Parser[Value]
      unless(length routes<=64)(fail "routes bound")
      forM_ routes $ withObject "route" $ \route->closed["name","backend"]route >> (route .: "name" >>= label) >> (route .: "backend" >>= label)
      forM_ ["pollMs","timeoutMs"] $ \key->o .: key >>= nullablePositive
      _<-o .: "verbose"::Parser Bool
      values<-o .: "realizations"::Parser[Value]
      unless(length values<=256)(fail "realizations bound")
      mapM_ realization values
      let present=filter (`KM.member` o)["routingVersion","persona","personaSource","policyDigest"]
      unless(null present || length present==4)(fail "persona completeness")
      when(not(null present)) $ do
        version<-o .: "routingVersion";unless(version==(2::Int))(fail "routing version")
        o .: "persona" >>= label
        source<-o .: "personaSource";unless(source `elem` (["command-line","environment","project","user-default"]::[Text]))(fail "persona source")
        digest<-o .: "policyDigest";unless(validDigest digest)(fail "policy digest")
    _->fail "policy kind"
  where
    realization=withObject "realization" $ \o->do
      closed realizationKeys o
      forM_ ["profile","axis","backend","router","provider","model"] $ \key->o .: key >>= label
      rung<-o .: "rung"::Parser Integer;unless(rung>=0 && rung<=2147483647)(fail "rung")
      thinking<-o .: "thinking";unless(thinking `elem` (["off","minimal","low","medium","high","xhigh","max"]::[Text]))(fail "thinking")
      o .: "maxOutput" >>= nullablePositive
      forM_ ["modelAlias","engine"] $ \key->maybe(pure()) label(KM.lookup key o)
      forM_ (KM.lookup "executionFingerprint" o) $ withText "fingerprint" $ \digest->unless(validDigest digest)(fail "fingerprint")
    label=withText "policy label" $ \value->unless(bounded 0 1024 value)(fail "policy label bound")
    nullablePositive Null=pure()
    nullablePositive (Number number)=case (floatingOrInteger number :: Either Double Integer) of Right value | (value::Integer)>0 && value<=2147483647->pure();_->fail "positive integer"
    nullablePositive _=fail "nullable integer"

-- The frozen observation dialect contains primitive codes or semantic schema data.
validObservationCode :: Value -> Bool
validObservationCode (String code)=code `elem` ["text","verdict","flag","receipt"]
validObservationCode (Object fields)=case KM.toList fields of
  [("json",Object value)] -> case KM.toList value of [("schema",schema)]->semantic 0 schema;_->False
  _->False
validObservationCode _=False

semantic :: Int -> Value -> Bool
semantic depth _ | depth>64=False
semantic _ (String value)=value `elem` ["null","boolean","integer","number","string","object"]
semantic depth value@(Object fields)=case KM.toList fields of
  [("array",Object body)]->case KM.toList body of [("items",items)]->semantic(depth+2)items;_->False
  [("property",_)]->objectSchema depth [] value
  _->False
semantic _ _=False

objectSchema :: Int -> [Text] -> Value -> Bool
objectSchema depth _ _ | depth>64=False
objectSchema _ _ (String "object")=True
objectSchema depth seen (Object fields)=case KM.toList fields of
  [("property",Object body)] | length(KM.keys body)==3 -> case (KM.lookup "name" body,KM.lookup "schema" body,KM.lookup "rest" body) of
    (Just(String name),Just schema,Just rest)->bounded 0 1024 name && name `notElem` seen && semantic(depth+2)schema && objectSchema(depth+2)(name:seen)rest
    _->False
  _->False
objectSchema _ _ _=False

observationCodeNames :: Value -> [Text]
observationCodeNames (Object values)=concat[case (key,value) of ("name",String name)->[name];_->observationCodeNames value|(key,value)<-KM.toList values]
observationCodeNames _=[]

closed :: [Text] -> Object -> Parser ()
closed allowed fields=unless(all (`elem` allowed)(map Key.toText(KM.keys fields)))(fail "unknown fields")
bounded :: Int -> Int -> Text -> Bool
bounded lower upper value=T.length value>=lower && T.length value<=upper
validDigest :: Text -> Bool
validDigest value=T.length value==64 && T.all(\c->c>='0' && c<='9' || c>='a' && c<='f')value
decimal :: Text -> Bool
decimal value=case reads(T.unpack value) of [(number,"")]->(number::Integer)>=0 && number<=18446744073709551615 && T.pack(show number)==value;_->False
