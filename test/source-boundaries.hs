{-# LANGUAGE OverloadedStrings #-}

-- Import policy is checked with the compiler's header parser, not source regexes.
module Main (main) where

import Control.Monad (forM, forM_, unless)
import Data.Aeson (FromJSON (parseJSON), eitherDecodeStrict', withObject, (.:))
import qualified Data.ByteString as BS
import Data.List (find, isPrefixOf, nub, sort)
import Data.Maybe (fromMaybe, maybeToList)
import qualified Data.Set as Set
import qualified Distribution.PackageDescription as Cabal
import Distribution.PackageDescription.Configuration (flattenPackageDescription)
import Distribution.PackageDescription.Parsec (parseGenericPackageDescriptionMaybe)
import Distribution.Utils.Path (getSymbolicPath)
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
import System.FilePath (addTrailingPathSeparator, normalise, takeDirectory, takeExtension, (</>))

checks :: [(FilePath, [String])]
checks =
  map (\(layer, denied) -> (layer, "Agentic.Manager" : denied))
  [ ("dsl/src", ["Agentic.Plan", "Agentic.Cost", "Agentic.Runtime", "Agentic.Exec", "Agentic.Shell", "Agentic.Engine", "Agentic.Acp", "Agentic.AgentDeck", "Agentic.Cli", "Agentic.Route", "Agentic.RoutingConfig", "Agentic.RoutingDiscovery", "Agentic.RoutingInspect", "Agentic.RoutingSecrets", "Agentic.Tui"]),
    ("plan/src", ["Agentic.Cost", "Agentic.Runtime", "Agentic.Exec", "Agentic.Shell", "Agentic.Engine", "Agentic.Acp", "Agentic.AgentDeck", "Agentic.Cli", "Agentic.Route", "Agentic.RoutingConfig", "Agentic.RoutingDiscovery", "Agentic.RoutingInspect", "Agentic.RoutingSecrets", "Agentic.Workflow", "Agentic.Tui"]),
    ("cost/src", ["Agentic.Runtime", "Agentic.Exec", "Agentic.Shell", "Agentic.Engine", "Agentic.Acp", "Agentic.AgentDeck", "Agentic.Cli", "Agentic.Route", "Agentic.RoutingConfig", "Agentic.RoutingDiscovery", "Agentic.RoutingInspect", "Agentic.RoutingSecrets", "Agentic.Workflow", "Agentic.Tui"]),
    ("runtime/src", ["Agentic.DSL", "Agentic.Builder", "Agentic.WF", "Agentic.Workflow", "Agentic.Acp", "Agentic.AgentDeck", "Agentic.Cli", "Agentic.Route", "Agentic.RoutingConfig", "Agentic.RoutingDiscovery", "Agentic.RoutingInspect", "Agentic.RoutingSecrets", "Agentic.Tui"]),
    ("engine", ["Agentic.DSL", "Agentic.Builder", "Agentic.Plan", "Agentic.Cost", "Agentic.Runtime", "Agentic.Exec", "Agentic.Shell", "Agentic.Cli", "Agentic.Route", "Agentic.RoutingConfig", "Agentic.RoutingDiscovery", "Agentic.RoutingInspect", "Agentic.RoutingSecrets", "Agentic.Workflow", "Agentic.Tui"]),
    ("bisim/haskell/src", ["Agentic.Cost", "Agentic.Runtime", "Agentic.Exec", "Agentic.Shell", "Agentic.Engine", "Agentic.Acp", "Agentic.AgentDeck", "Agentic.Cli", "Agentic.Route", "Agentic.RoutingConfig", "Agentic.RoutingDiscovery", "Agentic.RoutingInspect", "Agentic.RoutingSecrets", "Agentic.Workflow", "Agentic.Tui"])
  ] <>
  [ ("manager", ["Agentic.Builder", "Agentic.Cli", "Agentic.Cost", "Agentic.DSL", "Agentic.Engine", "Agentic.Exec", "Agentic.Plan", "Agentic.Schema", "Agentic.Shell", "Agentic.Route", "Agentic.RoutingConfig", "Agentic.Workflow", "Agentic.WF", "Agentic.Acp", "Agentic.AgentDeck", "Agentic.Tui", "Agentic.Bisim", "Agentic.Runtime.Machine"])
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
  declaredRoots <- cabalSourceRoots
  let options = initParserOpts (foldl xopt_set flags [Extension.ImportQualifiedPost, Extension.PackageImports, Extension.ExplicitNamespaces, Extension.PatternSynonyms, Extension.MagicHash])
      layers = map fst checks <> ["tui/src"]
      directories = nub (layers <> ["cli/src", "cli/example", "workflow"] <> declaredRoots)
  paths <- nub . map normalise . concat <$> mapM sourceFiles directories
  sources <- forM paths $ \path -> do
    let directory = fromMaybe (takeDirectory path) (find (\layer -> addTrailingPathSeparator layer `isPrefixOf` path) layers)
    (name, imports) <- readFile path >>= parseHeader options path
    unless (directory /= "tui/src" || within "Agentic.Tui" name) (die (path <> ": terminal module is outside the Agentic.Tui namespace"))
    unless (not ("manager/src/" `isPrefixOf` path) || within "Agentic.Manager" name) (die (path <> ": manager module is outside the Agentic.Manager namespace"))
    unless (not (within "Agentic.Manager" name) || directory == "manager") (die (path <> ": manager namespace is outside the manager source root"))
    pure (directory, path, name, imports)
  let projectModules = Set.fromList [name | (_, _, name, _) <- sources]
      terminalModules = Set.fromList [name | ("tui/src", _, name, _) <- sources]
      violations layer caller imports = filter (forbidden projectModules terminalModules layer caller) imports
  bytes <- BS.readFile "test/fixtures/tui/import-boundaries.json"
  fixtures <- either die pure (eitherDecodeStrict' bytes :: Either String [Fixture])
  forM_ fixtures $ \(Fixture name layer source allowed) -> do
    (caller, imports) <- parseHeader options name source
    unless (null (violations layer caller imports) == allowed) (die ("import fixture failed: " <> name))
  -- Exercise every denied layer edge, including future submodules of that edge.
  let layerEdges = [(layer, target <> suffix) | (layer, targets) <- checks, target <- targets, suffix <- ["", ".Internal"]]
      terminalEdges = [("tui/src", name) | name <- Set.toAscList (projectModules `Set.difference` terminalModules), name `notElem` ["Agentic.Runtime", "Agentic.Manager.Client"]]
      edges = layerEdges <> terminalEdges
  forM_ edges $ \(layer, target) -> do
    (caller, imports) <- parseHeader options target ("module Negative where\nimport " <> target <> "\n")
    unless (target `elem` violations layer caller imports) (die ("forbidden edge fixture accepted: " <> layer <> " -> " <> target))
  let bad = [path <> ": " <> target | (layer, path, caller, imports) <- sources, target <- violations layer caller imports]
  unless (null bad) (die ("forbidden layer import(s):\n" <> unlines bad))
  putStrLn ("policy imports: compiler-parsed module boundaries verified; " <> show (length fixtures) <> " syntax/frontend fixtures and " <> show (length edges) <> " forbidden-edge fixtures passed")

cabalSourceRoots :: IO [FilePath]
cabalSourceRoots = do
  bytes <- BS.readFile "agentic.cabal"
  generic <- maybe (die "cannot parse agentic.cabal source roots") pure (parseGenericPackageDescriptionMaybe bytes)
  let package = flattenPackageDescription generic
      -- Include disabled branches and components, not only buildable BuildInfos.
      infos = map Cabal.libBuildInfo (maybeToList (Cabal.library package) <> Cabal.subLibraries package)
        <> map Cabal.buildInfo (Cabal.executables package)
        <> map Cabal.testBuildInfo (Cabal.testSuites package)
        <> map Cabal.benchmarkBuildInfo (Cabal.benchmarks package)
        <> map Cabal.foreignLibBuildInfo (Cabal.foreignLibs package)
      roots info = case Cabal.hsSourceDirs info of
        [] -> ["."]
        paths -> map getSymbolicPath paths
  pure (nub (map normalise (concatMap roots infos)))

forbidden :: Set.Set String -> Set.Set String -> FilePath -> String -> String -> Bool
forbidden projectModules terminalModules layer caller target
  | within "Agentic.Manager" caller && layer /= "manager" = True
  | layer == "tui/src" =
      projectImport
        && target `notElem` ["Agentic.Runtime", "Agentic.Manager.Client"]
        && not (target `Set.member` terminalModules)
  | layer == "manager", within "Agentic.Manager.Client" caller =
      (projectImport && not (any (`within` target) ["Agentic.Manager.Client", "Agentic.Manager.Protocol"]))
        || serverDependency
  | layer == "manager", within "Agentic.Manager.Protocol" caller =
      (projectImport && not (within "Agentic.Manager.Protocol" target)) || serverDependency
  | layer == "manager" =
      projectImport && target /= "Agentic.Runtime" && not (within "Agentic.Manager" target)
  | otherwise = any (`within` target) (maybe [] id (lookup layer checks))
  where
    projectImport = "Agentic." `isPrefixOf` target || target `Set.member` projectModules
    serverDependency = any (`within` target) ["Database.SQLite", "Database.SQLite3", "Network.Wai"]

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
