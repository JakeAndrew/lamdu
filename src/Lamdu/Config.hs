{-# OPTIONS -O0 #-}
{-# LANGUAGE NoImplicitPrelude, TemplateHaskell #-}
module Lamdu.Config
    ( Export(..), Pane(..), Hole(..)
    , Eval(..)
    , LiteralText(..)
    , Config(..)
    , HasConfig(..)
    , delKeys
    ) where

import qualified Control.Lens as Lens
import           Data.Aeson.TH (deriveJSON)
import           Data.Aeson.Types (defaultOptions)
import           GUI.Momentu.MetaKey (MetaKey)
import qualified GUI.Momentu.Zoom as Zoom
import qualified Lamdu.GUI.VersionControl.Config as VersionControl

import           Lamdu.Prelude

data Export = Export
    { exportPath :: FilePath
    , exportKeys :: [MetaKey]
    , exportFancyKeys :: [MetaKey]
    , exportAllKeys :: [MetaKey]
    , importKeys :: [MetaKey]
    } deriving (Eq, Show)
deriveJSON defaultOptions ''Export

data Pane = Pane
    { paneCloseKeys :: [MetaKey]
    , paneMoveDownKeys :: [MetaKey]
    , paneMoveUpKeys :: [MetaKey]
    , newDefinitionKeys :: [MetaKey]
    , newDefinitionButtonPressKeys :: [MetaKey]
    } deriving (Eq, Show)
deriveJSON defaultOptions ''Pane

data Hole = Hole
    { holePickAndMoveToNextHoleKeys :: [MetaKey]
    , holeJumpToNextKeys :: [MetaKey]
    , holeJumpToPrevKeys :: [MetaKey]
    , holeResultCount :: Int
    , holePickResultKeys :: [MetaKey]
    , holeUnwrapKeys :: [MetaKey]
    , holeOpenKeys :: [MetaKey]
    , holeCloseKeys :: [MetaKey]
    } deriving (Eq, Show)
deriveJSON defaultOptions ''Hole

data Eval = Eval
    { prevScopeKeys :: [MetaKey]
    , nextScopeKeys :: [MetaKey]
    } deriving (Eq, Show)
deriveJSON defaultOptions ''Eval

data LiteralText = LiteralText
    { literalTextStartEditingKeys :: [MetaKey]
    , literalTextStopEditingKeys :: [MetaKey]
    } deriving (Eq, Show)
deriveJSON defaultOptions ''LiteralText

data Config = Config
    { zoom :: Zoom.Config
    , export :: Export
    , pane :: Pane
    , versionControl :: VersionControl.Config
    , hole :: Hole
    , literalText :: LiteralText
    , eval :: Eval

    , maxExprDepth :: Int

    , helpKeys :: [MetaKey]
    , quitKeys :: [MetaKey]
    , changeThemeKeys :: [MetaKey]
    , nextInfoModeKeys :: [MetaKey]
    , previousCursorKeys :: [MetaKey]

    , addNextParamKeys :: [MetaKey]
    , paramOrderBeforeKeys :: [MetaKey]
    , paramOrderAfterKeys :: [MetaKey]
    , jumpToDefinitionKeys :: [MetaKey]
    , delForwardKeys :: [MetaKey]
    , delBackwardKeys :: [MetaKey]
    , replaceParentKeys :: [MetaKey]
    , wrapKeys :: [MetaKey]

    , letAddItemKeys :: [MetaKey]

    , extractKeys :: [MetaKey]
    , inlineKeys :: [MetaKey]
    , moveLetInwardKeys:: [MetaKey]

    , enterSubexpressionKeys :: [MetaKey]
    , leaveSubexpressionKeys :: [MetaKey]

    , recordOpenKeys :: [MetaKey]
    , recordAddFieldKeys :: [MetaKey]

    , caseOpenKeys :: [MetaKey]
    , caseAddAltKeys :: [MetaKey]
    } deriving (Eq, Show)
deriveJSON defaultOptions ''Config

class HasConfig env where config :: Lens' env Config
instance HasConfig Config where config = id

delKeys :: (MonadReader env m, HasConfig env) => m [MetaKey]
delKeys = sequence [Lens.view config <&> delForwardKeys, Lens.view config <&> delBackwardKeys] <&> mconcat
