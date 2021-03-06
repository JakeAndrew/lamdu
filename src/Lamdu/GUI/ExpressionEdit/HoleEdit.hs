{-# LANGUAGE NoImplicitPrelude, OverloadedStrings, NamedFieldPuns #-}
module Lamdu.GUI.ExpressionEdit.HoleEdit
    ( make
    ) where

import qualified Control.Lens as Lens
import qualified Control.Monad.Reader as Reader
import           Control.Monad.Transaction (transaction)
import qualified Data.Store.Transaction as Transaction
import qualified GUI.Momentu.Align as Align
import qualified GUI.Momentu.Element as Element
import qualified GUI.Momentu.EventMap as E
import           GUI.Momentu.Glue ((/-/))
import qualified GUI.Momentu.Hover as Hover
import qualified GUI.Momentu.Responsive as Responsive
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.Menu as Menu
import qualified Lamdu.Config as Config
import qualified Lamdu.GUI.ExpressionEdit.EventMap as ExprEventMap
import qualified Lamdu.GUI.ExpressionEdit.HoleEdit.Argument as Wrapper
import           Lamdu.GUI.ExpressionEdit.HoleEdit.Info (HoleInfo(..))
import qualified Lamdu.GUI.ExpressionEdit.HoleEdit.SearchArea as SearchArea
import qualified Lamdu.GUI.ExpressionEdit.HoleEdit.State as HoleState
import           Lamdu.GUI.ExpressionEdit.HoleEdit.WidgetIds (WidgetIds(..))
import qualified Lamdu.GUI.ExpressionEdit.HoleEdit.WidgetIds as HoleWidgetIds
import           Lamdu.GUI.ExpressionGui (ExpressionGui)
import qualified Lamdu.GUI.ExpressionGui as ExpressionGui
import           Lamdu.GUI.ExpressionGui.Monad (ExprGuiM)
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import qualified Lamdu.GUI.ExpressionGui.Types as ExprGuiT
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.Sugar.Names.Types (Name(..))
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

makeWrapper ::
    Monad m =>
    Sugar.Payload m ExprGuiT.Payload -> HoleInfo m ->
    ExprGuiM m (Maybe (ExpressionGui m))
makeWrapper pl holeInfo =
    hiHole holeInfo ^? Sugar.holeKind . Sugar._WrapperHole
    & Lens._Just %%~
        \holeArg ->
        do
            (wrapper, holePicker) <-
                Wrapper.make (hiIds holeInfo) holeArg
                & ExprGuiM.listenResultPicker
            exprEventMap <- ExprEventMap.make pl holePicker
            E.weakerEvents exprEventMap wrapper & return

assignHoleCursor ::
    Monad m => WidgetIds -> ExprGuiM m a -> ExprGuiM m a
assignHoleCursor widgetIds =
    Widget.assignCursor hidHole hidOpen .
    Widget.assignCursor (WidgetIds.notDelegatingId hidHole) hidClosedSearchArea
    where
        WidgetIds{hidHole,hidOpen,hidClosedSearchArea} = widgetIds

makeHoleWithWrapper ::
    (Functor f, Monad m) =>
    ExpressionGui f -> (Menu.Placement -> ExpressionGui f) -> Sugar.Payload m ExprGuiT.Payload ->
    ExprGuiM m (ExpressionGui f)
makeHoleWithWrapper wrapperGui searchAreaGui pl =
    do
        unfocusedWrapperGui <-
            ExpressionGui.maybeAddAnnotationPl pl ?? wrapperGui
        isSelected <- Widget.isSubCursor ?? hidHole widgetIds
        hover <- Hover.hover
        let f layoutMode wrapper =
                case isSelected || Widget.isFocused (wrapper ^. Align.tValue) of
                True ->
                    wrapper & Align.tValue %~ Hover.hoverInPlaceOf options . Hover.anchor
                    where
                        options =
                            [ hoverWrapper /-/ (searchArea Menu.Below <&> hover)
                            , (searchArea Menu.Above <&> hover) /-/ hoverWrapper
                            ]
                            <&> (^. Align.tValue)
                        hoverWrapper = render wrapperGui & Align.tValue %~ Hover.anchor
                        searchArea p =
                            render (searchAreaGui p)
                            & hideIfInHole
                        render x = (x ^. Responsive.render) layoutMode
                False -> wrapper
        unfocusedWrapperGui
            & Responsive.render . Lens.imapped %@~ f
            & pure
    where
        widgetIds = HoleWidgetIds.make (pl ^. Sugar.plEntityId)
        hideIfInHole x
            | ExprGuiT.isHoleResult pl =
                x
                & Element.setLayers .~ mempty
                & Element.size .~ 0
            | otherwise = x

make ::
    Monad m =>
    Sugar.Hole m (Sugar.Expression (Name m) m ()) (ExprGuiT.SugarExpr m) ->
    Sugar.Payload m ExprGuiT.Payload ->
    ExprGuiM m (ExpressionGui m)
make hole pl =
    do
        stateProp <-
            HoleState.assocStateRef (hole ^. Sugar.holeActions . Sugar.holeUUID)
            ^. Transaction.mkProperty & transaction

        let holeInfo = HoleInfo
                { hiEntityId = pl ^. Sugar.plEntityId
                , hiState = stateProp
                , hiInferredType = pl ^. Sugar.plAnnotation . Sugar.aInferredType
                , hiHole = hole
                , hiIds = widgetIds
                , hiNearestHoles = pl ^. Sugar.plData . ExprGuiT.plNearestHoles
                }

        searchAreaGui <- SearchArea.makeStdWrapped pl holeInfo
        mWrapperGui <- makeWrapper pl holeInfo

        delKeys <- Config.delKeys
        let deleteEventMap =
                hole ^. Sugar.holeActions . Sugar.holeMDelete
                & maybe mempty
                    ( Widget.keysEventMapMovesCursor delKeys
                        (E.Doc ["Edit", "Delete hole"])
                        . fmap WidgetIds.fromEntityId)

        case mWrapperGui of
            Just wrapperGui -> makeHoleWithWrapper wrapperGui searchAreaGui pl
            Nothing -> return (searchAreaGui Menu.AnyPlace)
            <&> E.weakerEvents deleteEventMap
    & assignHoleCursor widgetIds
    & Reader.local (Element.animIdPrefix .~ Widget.toAnimId (hidHole widgetIds))
    where
        widgetIds = HoleWidgetIds.make (pl ^. Sugar.plEntityId)
