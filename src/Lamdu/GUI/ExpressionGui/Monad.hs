{-# LANGUAGE NoImplicitPrelude, GeneralizedNewtypeDeriving, TemplateHaskell, OverloadedStrings, MultiParamTypeClasses, FlexibleInstances, FlexibleContexts #-}
module Lamdu.GUI.ExpressionGui.Monad
    ( ExprGuiM
    , StoredEntityIds(..)
    , withLocalUnderline
    --
    , makeSubexpression
    , makeSubexpressionWith
    , advanceDepth, resetDepth
    --
    , readMinOpPrec
    , readCodeAnchors, mkPrejumpPosSaver
    --
    , readMScopeId, withLocalMScopeId
    , isExprSelected
    --
    , outerPrecedence
    , withLocalPrecedence
    --
    , HolePicker(..), withHolePicker
    , setResultPicker, listenResultPicker
    , run
    ) where

import qualified Control.Lens as Lens
import qualified Control.Monad.Reader as Reader
import           Control.Monad.Trans.FastRWS (RWST, runRWST)
import qualified Control.Monad.Trans.FastRWS as RWS
import           Control.Monad.Transaction (MonadTransaction(..))
import           Control.Monad.Writer (MonadWriter)
import qualified Control.Monad.Writer as Writer
import qualified Data.Char as Char
import           Data.CurAndPrev (CurAndPrev)
import           Data.Store.Transaction (Transaction)
import qualified Data.Text.Lens as TextLens
import           Data.Vector.Vector2 (Vector2)
import           GUI.Momentu.Align (WithTextPos)
import           GUI.Momentu.Animation.Id (AnimId)
import qualified GUI.Momentu.Element as Element
import qualified GUI.Momentu.EventMap as E
import qualified GUI.Momentu.Hover as Hover
import qualified GUI.Momentu.Responsive as Responsive
import qualified GUI.Momentu.Responsive.Expression as ResponsiveExpr
import           GUI.Momentu.View (View)
import qualified GUI.Momentu.Widget as Widget
import           GUI.Momentu.Widget.Id (toAnimId)
import qualified GUI.Momentu.Widgets.Menu as Menu
import qualified GUI.Momentu.Widgets.Spacer as Spacer
import qualified GUI.Momentu.Widgets.TextEdit as TextEdit
import qualified GUI.Momentu.Widgets.TextView as TextView
import           Lamdu.Config (Config)
import qualified Lamdu.Config as Config
import           Lamdu.Config.Theme (Theme, HasTheme)
import qualified Lamdu.Config.Theme as Theme
import qualified Lamdu.Data.Anchors as Anchors
import qualified Lamdu.Data.Ops as DataOps
import           Lamdu.Eval.Results (ScopeId, topLevelScopeId)
import           Lamdu.GUI.CodeEdit.Settings (Settings, HasSettings(..))
import           Lamdu.GUI.ExpressionGui.Types (ExpressionGui)
import qualified Lamdu.GUI.ExpressionGui.Types as ExprGuiT
import           Lamdu.Precedence (Precedence)
import qualified Lamdu.Precedence as Precedence
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.Style (Style, HasStyle(..))
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

type T = Transaction

data HolePicker m
    = NoHolePick
    | HolePick (T m Widget.EventResult)

instance Monoid (HolePicker m) where
    mempty = NoHolePick
    mappend NoHolePick x = x
    mappend x NoHolePick = x
    mappend _ _ = error "Two HolePick's told, are we inside 2 holes simultaneously?"

withHolePicker :: Monad m => HolePicker m -> E.EventMap (T m a) -> E.EventMap (T m a)
withHolePicker NoHolePick e = e
withHolePicker (HolePick action) e =
    e
    & E.emDocs . E.docStrs . Lens.reversed . Lens.element 0 %~ f
    <&> (action >>)
    where
        f x =
            x
            & TextLens._Text . Lens.element 0 %~ Char.toLower
            & ("Pick result and " <>)

newtype Output m = Output
    { oHolePicker :: HolePicker m
    } deriving (Monoid)

newtype StoredEntityIds = StoredEntityIds [Sugar.EntityId]
    deriving (Monoid)

data Askable m = Askable
    { _aCursor :: Widget.Id
    , _aTextEditStyle :: TextEdit.Style
    , _aStdSpacing :: Vector2 Double
    , _aAnimIdPrefix :: AnimId
    , _aSettings :: Settings
    , _aConfig :: Config
    , _aTheme :: Theme
    , _aMakeSubexpression :: ExprGuiT.SugarExpr m -> ExprGuiM m (ExpressionGui m)
    , _aCodeAnchors :: Anchors.CodeAnchors m
    , _aDepthLeft :: Int
    , _aMScopeId :: CurAndPrev (Maybe ScopeId)
    , _aOuterPrecedence :: Precedence
    , _aMinOpPrecedence :: Int
      -- ^ The minimum precedence that operators must have to be
      -- applicable inside leaf holes. This allows "text-like"
      -- appending of operators at the right parent level according to
      --
      -- precedence (e.g: in "x % 3 == 0 || ..." the hole for "3" does
      -- not allow operators, making the == apply at the parent expr)
    , _aStyle :: Style
    }
newtype ExprGuiM m a = ExprGuiM
    { _exprGuiM :: RWST (Askable m) (Output m) () (T m) a
    } deriving (Functor, Applicative, Monad,
                MonadReader (Askable m), MonadWriter (Output m))

Lens.makeLenses ''Askable
Lens.makeLenses ''ExprGuiM

instance Monad m => MonadTransaction m (ExprGuiM m) where transaction = ExprGuiM . lift

instance Widget.HasCursor (Askable m) where cursor = aCursor
instance TextView.HasStyle (Askable m) where style = aTextEditStyle . TextView.style
instance TextEdit.HasStyle (Askable m) where style = aTextEditStyle
instance Spacer.HasStdSpacing (Askable m) where stdSpacing = aStdSpacing
instance Element.HasAnimIdPrefix (Askable m) where animIdPrefix = aAnimIdPrefix
instance Config.HasConfig (Askable m) where config = aConfig
instance HasTheme (Askable m) where theme = aTheme
instance ResponsiveExpr.HasStyle (Askable m) where style = aTheme . ResponsiveExpr.style
instance Menu.HasStyle (Askable m) where style = aTheme . Menu.style
instance Hover.HasStyle (Askable m) where style = aTheme . Hover.style
instance HasStyle (Askable m) where style = aStyle
instance HasSettings (Askable m) where settings = aSettings

withLocalUnderline ::
    (MonadReader env m, TextView.HasStyle env) => TextView.Underline -> m a -> m a
withLocalUnderline underline = Reader.local (TextView.underline ?~ underline)

readMinOpPrec :: Monad m => ExprGuiM m Int
readMinOpPrec = Lens.view aMinOpPrecedence

readCodeAnchors :: Monad m => ExprGuiM m (Anchors.CodeAnchors m)
readCodeAnchors = Lens.view aCodeAnchors

mkPrejumpPosSaver :: Monad m => ExprGuiM m (T m ())
mkPrejumpPosSaver =
    DataOps.savePreJumpPosition <$> readCodeAnchors <*> Lens.view Widget.cursor

makeSubexpression ::
    Monad m =>
    ExprGuiT.SugarExpr m -> ExprGuiM m (ExpressionGui m)
makeSubexpression = makeSubexpressionWith 0 (const (Precedence.make 0))

makeSubexpressionWith ::
    Monad m =>
    Int -> (Precedence -> Precedence) -> ExprGuiT.SugarExpr m -> ExprGuiM m (ExpressionGui m)
makeSubexpressionWith minOpPrec onPrecedence expr =
    do
        maker <- Lens.view aMakeSubexpression & ExprGuiM
        maker expr & withLocalPrecedence minOpPrec onPrecedence
    & advanceDepth (return . Responsive.fromTextView) animId
    where
        animId = toAnimId $ WidgetIds.fromExprPayload $ expr ^. Sugar.rPayload

resetDepth :: Int -> ExprGuiM m r -> ExprGuiM m r
resetDepth depth = exprGuiM %~ RWS.local (aDepthLeft .~ depth)

advanceDepth ::
    Monad m => (WithTextPos View -> ExprGuiM m r) ->
    AnimId -> ExprGuiM m r -> ExprGuiM m r
advanceDepth f animId action =
    do
        depth <- Lens.view aDepthLeft
        if depth <= 0
            then mkErrorWidget >>= f
            else action & exprGuiM %~ RWS.local (aDepthLeft -~ 1)
    where
        mkErrorWidget = TextView.make ?? "..." ?? animId

run ::
    ( MonadTransaction m n, MonadReader env n
    , Widget.HasCursor env, Spacer.HasStdSpacing env
    , Config.HasConfig env, HasTheme env
    , HasSettings env, HasStyle env
    ) =>
    (ExprGuiT.SugarExpr m -> ExprGuiM m (ExpressionGui m)) ->
    Anchors.CodeAnchors m ->
    ExprGuiM m a ->
    n a
run makeSubexpr theCodeAnchors (ExprGuiM action) =
    do
        theSettings <- Lens.view settings
        theStyle <- Lens.view style
        theCursor <- Lens.view Widget.cursor
        theTextEditStyle <- Lens.view TextEdit.style
        theStdSpacing <- Lens.view Spacer.stdSpacing
        theConfig <- Lens.view Config.config
        theTheme <- Lens.view Theme.theme
        runRWST action
            Askable
            { _aCursor = theCursor
            , _aTextEditStyle = theTextEditStyle
            , _aStdSpacing = theStdSpacing
            , _aAnimIdPrefix = ["outermost"]
            , _aConfig = theConfig
            , _aTheme = theTheme
            , _aSettings = theSettings
            , _aMakeSubexpression = makeSubexpr
            , _aCodeAnchors = theCodeAnchors
            , _aDepthLeft = Config.maxExprDepth theConfig
            , _aMScopeId = Just topLevelScopeId & pure
            , _aOuterPrecedence = Precedence.make 0
            , _aMinOpPrecedence = 0
            , _aStyle = theStyle
            }
            ()
            <&> (\(x, (), _output) -> x)
            & transaction

-- Used vars:

listener :: Monad m => (Output m -> b) -> ExprGuiM m a -> ExprGuiM m (a, b)
listener f =
    exprGuiM %~ RWS.listen
    & Lens.mapped . Lens.mapped . _2 %~ f

listenResultPicker :: Monad m => ExprGuiM m a -> ExprGuiM m (a, HolePicker m)
listenResultPicker = listener oHolePicker

setResultPicker :: Monad m => T m Widget.EventResult -> ExprGuiM m ()
setResultPicker picker =
    Writer.tell mempty { oHolePicker = HolePick picker }

readMScopeId :: Monad m => ExprGuiM m (CurAndPrev (Maybe ScopeId))
readMScopeId = Lens.view aMScopeId

withLocalMScopeId :: CurAndPrev (Maybe ScopeId) -> ExprGuiM m a -> ExprGuiM m a
withLocalMScopeId mScopeId = exprGuiM %~ RWS.local (aMScopeId .~ mScopeId)

isExprSelected ::
    (MonadReader env m, Widget.HasCursor env) =>
    Sugar.Payload f a -> m Bool
isExprSelected pl = Widget.isSubCursor ?? WidgetIds.fromExprPayload pl

outerPrecedence :: Monad m => ExprGuiM m Precedence
outerPrecedence = Lens.view aOuterPrecedence

withLocalPrecedence :: Int -> (Precedence -> Precedence) -> ExprGuiM m a -> ExprGuiM m a
withLocalPrecedence minOpPrec f =
    exprGuiM %~
    RWS.local
    ( (aOuterPrecedence %~ f)
    . (aMinOpPrecedence .~ minOpPrec)
    )
