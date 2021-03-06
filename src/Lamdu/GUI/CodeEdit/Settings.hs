{-# LANGUAGE NoImplicitPrelude, TemplateHaskell, OverloadedStrings #-}
module Lamdu.GUI.CodeEdit.Settings
    ( Settings(..), sInfoMode, InfoMode(..), defaultInfoMode
    , HasSettings(..)
    , nextInfoMode
    , mkEventMap
    ) where

import qualified Control.Lens as Lens
import           Data.IORef
import qualified Data.Text as Text
import qualified GUI.Momentu.EventMap as EventMap
import qualified GUI.Momentu.Widget as Widget
import           Lamdu.Config (Config)
import qualified Lamdu.Config as Config

import           Lamdu.Prelude

data InfoMode = Evaluation | Types | None
    deriving (Eq, Ord, Show, Enum, Bounded)

defaultInfoMode :: InfoMode
defaultInfoMode = Evaluation

newtype Settings = Settings
    { _sInfoMode :: InfoMode
    }
Lens.makeLenses ''Settings

class HasSettings env where settings :: Lens' env Settings

cyclicSucc :: (Eq a, Enum a, Bounded a) => a -> a
cyclicSucc x
    | x == maxBound = minBound
    | otherwise = succ x

nextInfoMode :: InfoMode -> InfoMode
nextInfoMode = cyclicSucc

mkEventMap ::
    (Settings -> IO ()) -> Config -> IORef Settings ->
    IO (Widget.EventMap (IO Widget.EventResult))
mkEventMap onSettingsChange config settingsRef =
    do
        theSettings <- readIORef settingsRef
        let next = theSettings ^. sInfoMode & nextInfoMode
        let nextDoc =
                EventMap.Doc ["View", "Subtext", "Show " <> Text.pack (show next)]
        let nextSettings = theSettings & sInfoMode .~ next
        do
            writeIORef settingsRef nextSettings
            onSettingsChange nextSettings
            & Widget.keysEventMap (Config.nextInfoModeKeys config) nextDoc
            & return
