{-# LANGUAGE OverloadedStrings #-}

-- Import policy is checked with the compiler's header parser, not source regexes.
module Main (main) where

import Control.Monad (forM, forM_, unless)
import Data.Aeson (FromJSON (parseJSON), eitherDecodeStrict', withObject, (.:))
import qualified Data.ByteString as BS
import Data.List (isPrefixOf, sort)
import qualified Data.Set as Set
import GHC (getSessionDynFlags, moduleNameString, runGhc, unLoc)
import GHC.Data.StringBuffer (stringToStringBuffer)
import GHC.Driver.Config.Parser (initParserOpts)
import GHC.Driver.Session (xopt_set)
import qualified GHC.LanguageExtensions.Type as Extension
import GHC.Parser.Header (getImports)
import GHC.Parser.Lexer (ParserOpts)
import System.Directory (doesDirectoryExist, listDirectory)
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath (takeExtension, (</>))

checks :: [(FilePath, [String])]
checks =
  [ ("dsl/src", ["Agentic.Plan", "Agentic.Cost", "Agentic.Runtime", "Agentic.Exec", "Agentic.Shell", "Agentic.Engine", "Agentic.Acp", "Agentic.AgentDeck", "Agentic.Cli", "Agentic.Route", "Agentic.RoutingConfig", "Agentic.RoutingDiscovery", "Agentic.RoutingInspect", "Agentic.RoutingSecrets", "Agentic.Tui"]),
    ("plan/src", ["Agentic.Cost", "Agentic.Runtime", "Agentic.Exec", "Agentic.Shell", "Agentic.Engine", "Agentic.Acp", "Agentic.AgentDeck", "Agentic.Cli", "Agentic.Route", "Agentic.RoutingConfig", "Agentic.RoutingDiscovery", "Agentic.RoutingInspect", "Agentic.RoutingSecrets", "Agentic.Workflow", "Agentic.Tui"]),
    ("cost/src", ["Agentic.Runtime", "Agentic.Exec", "Agentic.Shell", "Agentic.Engine", "Agentic.Acp", "Agentic.AgentDeck", "Agentic.Cli", "Agentic.Route", "Agentic.RoutingConfig", "Agentic.RoutingDiscovery", "Agentic.RoutingInspect", "Agentic.RoutingSecrets", "Agentic.Workflow", "Agentic.Tui"]),
    ("runtime/src", ["Agentic.DSL", "Agentic.Builder", "Agentic.WF", "Agentic.Workflow", "Agentic.Acp", "Agentic.AgentDeck", "Agentic.Cli", "Agentic.Route", "Agentic.RoutingConfig", "Agentic.RoutingDiscovery", "Agentic.RoutingInspect", "Agentic.RoutingSecrets", "Agentic.Tui"]),
    ("engine", ["Agentic.DSL", "Agentic.Builder", "Agentic.Plan", "Agentic.Cost", "Agentic.Runtime", "Agentic.Exec", "Agentic.Shell", "Agentic.Cli", "Agentic.Route", "Agentic.RoutingConfig", "Agentic.RoutingDiscovery", "Agentic.RoutingInspect", "Agentic.RoutingSecrets", "Agentic.Workflow", "Agentic.Tui"]),
    ("bisim/haskell/src", ["Agentic.Cost", "Agentic.Runtime", "Agentic.Exec", "Agentic.Shell", "Agentic.Engine", "Agentic.Acp", "Agentic.AgentDeck", "Agentic.Cli", "Agentic.Route", "Agentic.RoutingConfig", "Agentic.RoutingDiscovery", "Agentic.RoutingInspect", "Agentic.RoutingSecrets", "Agentic.Workflow", "Agentic.Tui"])
  ]

data Fixture = Fixture String FilePath String Bool

instance FromJSON Fixture where
  parseJSON = withObject "import boundary fixture" $ \o ->
    Fixture <$> o .: "name" <*> o .: "layer" <*> o .: "source" <*> o .: "allowed"

main :: IO ()
main = do
  arguments <- getArgs
  libdir <- case arguments of
    [path] -> pure path
    _ -> die "usage: source-boundaries.hs GHC_LIBDIR"
  flags <- runGhc (Just libdir) getSessionDynFlags
  let options = initParserOpts (foldl xopt_set flags [Extension.ImportQualifiedPost, Extension.PackageImports, Extension.ExplicitNamespaces, Extension.PatternSynonyms, Extension.MagicHash])
      directories = map fst checks <> ["tui/src", "cli/src", "cli/example", "workflow"]
  sources <- fmap concat $ forM directories $ \directory -> do
    paths <- sourceFiles directory
    forM paths $ \path -> do
      (name, imports) <- readFile path >>= parseHeader options path
      unless (directory /= "tui/src" || within "Agentic.Tui" name) (die (path <> ": terminal module is outside the Agentic.Tui namespace"))
      pure (directory, path, name, imports)
  let projectModules = Set.fromList [name | (_, _, name, _) <- sources]
      terminalModules = Set.fromList [name | ("tui/src", _, name, _) <- sources]
      violations layer imports = filter (forbidden projectModules terminalModules layer) imports
  bytes <- BS.readFile "test/fixtures/tui/import-boundaries.json"
  fixtures <- either die pure (eitherDecodeStrict' bytes :: Either String [Fixture])
  forM_ fixtures $ \(Fixture name layer source allowed) -> do
    (_, imports) <- parseHeader options name source
    unless (null (violations layer imports) == allowed) (die ("import fixture failed: " <> name))
  -- Exercise every denied layer edge, including future submodules of that edge.
  let layerEdges = [(layer, target <> suffix) | (layer, targets) <- checks, target <- targets, suffix <- ["", ".Internal"]]
      terminalEdges = [("tui/src", name) | name <- Set.toAscList (projectModules `Set.difference` terminalModules), name /= "Agentic.Runtime"]
      edges = layerEdges <> terminalEdges
  forM_ edges $ \(layer, target) -> do
    (_, imports) <- parseHeader options target ("module Negative where\nimport " <> target <> "\n")
    unless (target `elem` violations layer imports) (die ("forbidden edge fixture accepted: " <> layer <> " -> " <> target))
  let bad = [path <> ": " <> target | (layer, path, _, imports) <- sources, target <- violations layer imports]
  unless (null bad) (die ("forbidden layer import(s):\n" <> unlines bad))
  putStrLn ("policy imports: compiler-parsed module boundaries verified; " <> show (length fixtures) <> " syntax/TUI fixtures and " <> show (length edges) <> " forbidden-edge fixtures passed")

forbidden :: Set.Set String -> Set.Set String -> FilePath -> String -> Bool
forbidden projectModules terminalModules layer target
  | layer == "tui/src" =
      ("Agentic." `isPrefixOf` target || target `Set.member` projectModules)
        && target /= "Agentic.Runtime"
        && not (target `Set.member` terminalModules)
  | otherwise = any (`within` target) (maybe [] id (lookup layer checks))

within :: String -> String -> Bool
within parent target = target == parent || (parent <> ".") `isPrefixOf` target

parseHeader :: ParserOpts -> FilePath -> String -> IO (String, [String])
parseHeader options path source = do
  parsed <- getImports options False (stringToStringBuffer source) path path
  case parsed of
    Left _ -> die (path <> ": cannot parse module header for boundary verification")
    Right (sourceImports, ordinaryImports, _, name) ->
      pure (moduleNameString (unLoc name), map (moduleNameString . unLoc . snd) (sourceImports <> ordinaryImports))

sourceFiles :: FilePath -> IO [FilePath]
sourceFiles directory = do
  names <- sort <$> listDirectory directory
  fmap concat $ forM names $ \name -> do
    let path = directory </> name
    nested <- doesDirectoryExist path
    if nested then sourceFiles path else pure [path | takeExtension path == ".hs"]
