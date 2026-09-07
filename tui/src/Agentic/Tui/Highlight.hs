{-# LANGUAGE OverloadedStrings #-}

-- | Pure, grammar-free classification for bounded terminal presentation.
module Agentic.Tui.Highlight
  ( LineStyle (..),
    classifyLine,
  )
where

import Data.Text (Text)
import qualified Data.Text as T

-- | Presentation class of one already-bounded public line.
data LineStyle
  = PlainLine
  | DiffHeaderLine
  | DiffAddedLine
  | DiffRemovedLine
  | DiffHunkLine
  | StatusLine
  | MarkdownHeadingLine
  | MarkdownQuoteLine
  | MarkdownFenceLine
  deriving (Eq, Ord, Show)

classifyLine :: Text -> LineStyle
classifyLine line
  | "diff --git " `T.isPrefixOf` normalized = DiffHeaderLine
  | "+++ " `T.isPrefixOf` normalized || "--- " `T.isPrefixOf` normalized = DiffHeaderLine
  | "@@ " `T.isPrefixOf` normalized = DiffHunkLine
  | "+" `T.isPrefixOf` normalized = DiffAddedLine
  | "-" `T.isPrefixOf` normalized = DiffRemovedLine
  | any (`T.isPrefixOf` normalized) statusPrefixes = StatusLine
  | markdownHeading normalized = MarkdownHeadingLine
  | "> " `T.isPrefixOf` normalized = MarkdownQuoteLine
  | "```" `T.isPrefixOf` normalized || "~~~" `T.isPrefixOf` normalized = MarkdownFenceLine
  | otherwise = PlainLine
  where
    normalized = T.stripStart line
    markdownHeading value =
      case T.span (== '#') value of
        (marks, rest) -> not (T.null marks) && T.length marks <= 6 && " " `T.isPrefixOf` rest
    statusPrefixes =
      [ "attempt ",
        "message: ",
        "tool ",
        "todo ",
        "usage: ",
        "reasoning summary: ",
        "steer ",
        "failure ",
        "control ",
        "dispatch ",
        "recovery "
      ]
