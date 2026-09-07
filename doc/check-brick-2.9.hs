{-# LANGUAGE OverloadedStrings #-}

-- Compile-only evidence that the proposed TUI primitives exist in agent-cat's
-- locked Brick 2.9 / Vty 6.4 / vty-unix 0.2.0.0 package set.
module Main where

import Brick
import Brick.BChan (BChan, newBChan, readBChan, writeBChan, writeBChanNonBlocking)
import qualified Brick.Forms as Forms
import qualified Brick.Widgets.Edit as Edit
import qualified Brick.Widgets.List as List
import Control.Monad (void)
import Data.Text (Text)
import qualified Data.Vector as Vector
import qualified Graphics.Vty as Vty
import Graphics.Vty.Platform.Unix (mkVty)

data Name = Output | Editor | Items | Cached deriving (Eq, Ord, Show)
data Event = Frame

app :: App () Event Name
app =
  App
    { appDraw = const [cached Cached (viewport Output Vertical (txt "probe"))],
      appChooseCursor = neverShowCursor,
      appHandleEvent = handle,
      appStartEvent = pure (),
      appAttrMap = const (attrMap Vty.defAttr [])
    }

handle :: BrickEvent Name Event -> EventM Name () ()
handle (AppEvent Frame) = continueWithoutRedraw
handle _ = do
  void getVtyHandle
  vScrollToEnd (viewportScroll Output)
  invalidateCache

editorProbe :: Edit.Editor Text Name
editorProbe = Edit.editorText Editor (Just 3) ""

listProbe :: List.List Name Text
listProbe = List.list Items Vector.empty 1

formProbe :: Forms.Form () Event Name
formProbe = Forms.newForm [] ()

mainProbe :: Vty.Vty -> IO Vty.Vty -> BChan Event -> IO ()
mainProbe initial build channel = void (customMain initial build (Just channel) app ())

apiProbe :: IO ()
apiProbe = do
  channel <- newBChan 2
  _ <- writeBChanNonBlocking channel Frame
  let _blockingWrite = writeBChan channel Frame
      _blockingRead = readBChan channel
      _unixBuilder = mkVty Vty.defaultConfig
      _picture = renderWidget Nothing [clickable Output (txt "wide")] (80, 24)
      _width = textWidth ("界" :: Text)
  pure ()

main :: IO ()
main = pure ()
